import 'package:flutter/material.dart';

import '../../database/database.dart';
import '../../database/tables.dart';
import '../../main.dart';
import '../../utils/format_utils.dart';
import '../theme/app_theme.dart';

/// Header-action button that runs the SD card erase flow when eligible
/// (FR-018). Always visible for transfer-type jobs whose source is a
/// removable drive; disabled with clear textual reason ("Not complete"
/// / "Verifying…") until the underlying job has completed AND every
/// file is verified.
///
/// All existing safety gates (FR-019) carry over from v2.3.0:
///   - Serial-number identity capture before the dialog opens
///   - Typed drive-path confirmation field inside the dialog
///   - Size-only verification warning shown inline in the dialog
///   - Post-confirmation identity re-check (TOCTOU — drive may have been
///     swapped during the typing window)
class EraseDriveActionButton extends StatelessWidget {
  final Job job;

  const EraseDriveActionButton({super.key, required this.job});

  @override
  Widget build(BuildContext context) {
    // Erase is only meaningful for transfer-type jobs whose source is a
    // removable drive. Compression jobs read from a folder; nothing to erase.
    if (job.type == JobType.compression) return const SizedBox.shrink();

    return StreamBuilder<List<JobFile>>(
      stream: jobFileDao.watchFilesForJob(job.id),
      builder: (context, snapshot) {
        final files = snapshot.data ?? const <JobFile>[];
        final reason = eraseEligibilityReason(job, files);
        final enabled = reason == null;
        final scheme = Theme.of(context).colorScheme;
        final statusColors =
            Theme.of(context).extension<StatusColors>()!;

        return Tooltip(
          message: enabled
              ? 'Erase the source SD card'
              : _fullReason(reason, job),
          child: TextButton.icon(
            onPressed: enabled ? () => _runEraseFlow(context) : null,
            icon: Icon(
              Icons.delete_forever,
              size: 16,
              color: enabled ? statusColors.error : scheme.onSurfaceVariant,
            ),
            label: Text(
              enabled ? 'Erase SD' : reason,
              style: TextStyle(
                color: enabled ? statusColors.error : scheme.onSurfaceVariant,
                fontSize: 12,
              ),
              overflow: TextOverflow.ellipsis,
            ),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(
                  horizontal: 8, vertical: 4),
              minimumSize: const Size(0, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        );
      },
    );
  }

  Future<void> _runEraseFlow(BuildContext context) async {
    await eraseSourceDrive(context, job);
  }
}

/// Compact disabled label expanded for tooltips (since we shortened the
/// visible label to fit in a 377px right-pane header).
String _fullReason(String shortReason, Job job) {
  switch (shortReason) {
    case 'Not complete':
      return 'Job not yet complete';
    case 'Verifying…':
      return job.verificationMode == VerificationMode.sha256
          ? 'Waiting for SHA-256 verification'
          : 'Waiting for verification';
  }
  return shortReason;
}

/// Shared eligibility check for the erase flow (FR-018, FR-019).
///
/// Returns `null` if the job is safe to erase, or a short human-readable
/// reason otherwise. Both [EraseDriveActionButton] (per-job header) and
/// [JobCardCompleted] (sequential batch erase) MUST gate on this single
/// validator — Constitution Principle I requires the same trust signal
/// at every entry point.
///
/// Reasons returned are deliberately compact (≤ 12 chars) so they fit in
/// a narrow right-pane button label; expand via [_fullReason] for tooltips.
String? eraseEligibilityReason(Job job, List<JobFile> files) {
  if (job.status != JobStatus.completed) return 'Not complete';
  if (files.isEmpty) return 'Verifying…';
  if (files.any((f) => !f.verified)) return 'Verifying…';
  return null;
}

/// Standalone entry point for the erase flow — used both by the header
/// button and by the [Erase Cards] sequential CTA on the celebration
/// card (T061). Returns `true` on a successful erase, `false` if the
/// operator cancelled, the drive changed, or the erase command failed.
///
/// Reads `job.sourcePath` and `job.verificationMode` to drive identity
/// + warning content.
///
/// [silent]: when `true`, suppresses the per-erase result snackbars
/// ("erased successfully" / "drive changed" / "failed"). Used by the
/// [Erase Cards] batch flow on the celebration card so a 3-card run
/// produces ONE summary line instead of stacking 3 snackbars.
Future<bool> eraseSourceDrive(
  BuildContext context,
  Job job, {
  bool silent = false,
}) async {
  final drivePath = job.sourcePath;

  // Capture pre-dialog identity. Used to detect a card swap during the
  // confirmation window. Serial number is the strongest physical
  // identifier; label + totalBytes is the fallback when the card reader
  // doesn't expose serial.
  final preIdentity = await driveService.getDriveIdentity(drivePath);
  if (!context.mounted) return false;

  final identityDesc = preIdentity != null
      ? '${preIdentity.label} (${formatBytes(preIdentity.totalBytes)})'
      : drivePath;

  final sizeOnly = job.verificationMode == VerificationMode.size;
  final confirmed = await _showEraseConfirmDialog(
    context: context,
    identityDesc: identityDesc,
    drivePath: drivePath,
    sizeOnlyVerification: sizeOnly,
  );
  if (!confirmed) return false;
  if (!context.mounted) return false;

  // Re-verify identity AFTER the dialog returns. The card may have been
  // physically swapped during the confirmation window, or the drive
  // letter may have been reused for a different device.
  final postIdentity = await driveService.getDriveIdentity(drivePath);
  if (!driveIdentityMatches(preIdentity, postIdentity)) {
    if (!silent && context.mounted) {
      final statusColors = Theme.of(context).extension<StatusColors>()!;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            'Drive changed during confirmation — erase aborted for safety.',
          ),
          backgroundColor: statusColors.warning,
          duration: const Duration(seconds: 4),
        ),
      );
    }
    return false;
  }

  final success = await driveService.eraseDrive(drivePath);
  if (!context.mounted) return success;
  if (silent) return success;
  final statusColors = Theme.of(context).extension<StatusColors>()!;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(success
          ? 'SD card erased successfully'
          : 'Failed to erase SD card'),
      backgroundColor:
          success ? statusColors.success : statusColors.error,
    ),
  );
  return success;
}

/// Compare two `getDriveIdentity` results. Returns true if the same
/// physical device is still mounted at the drive letter.
///
/// Constitution Principle I — when EITHER side reports a serial number,
/// the serial MUST match exactly. A null-vs-string comparison fails
/// closed: if pre had a serial but post does not, that's a card swap
/// (possibly to one without WMI access) and we abort. Falling back to
/// label+size when only one side has a serial would let a same-labeled
/// imposter through.
///
/// Label + totalBytes is only used when NEITHER side has a serial — this
/// is the legacy USB / older reader path where WMI cannot resolve a
/// physical disk number.
///
/// Top-level (not private) so unit tests can exercise the swap matrix
/// without driving the full erase flow.
bool driveIdentityMatches(
  ({String label, int totalBytes, String? serialNumber})? a,
  ({String label, int totalBytes, String? serialNumber})? b,
) {
  if (a == null || b == null) return false;
  if (a.serialNumber != null || b.serialNumber != null) {
    return a.serialNumber == b.serialNumber;
  }
  return a.label == b.label && a.totalBytes == b.totalBytes;
}

/// Show the erase confirmation dialog. Requires the operator to type
/// the drive path to enable the Erase button. Surfaces a prominent
/// warning when the job was verified by file size only (not SHA-256).
Future<bool> _showEraseConfirmDialog({
  required BuildContext context,
  required String identityDesc,
  required String drivePath,
  required bool sizeOnlyVerification,
}) async {
  final controller = TextEditingController();
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialogState) {
        final typedMatches = controller.text.trim() == drivePath;
        final statusColors = Theme.of(ctx).extension<StatusColors>()!;
        return AlertDialog(
          title: const Text('Erase SD Card'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'This will permanently delete ALL files on:',
                  ),
                  const SizedBox(height: 8),
                  Text(identityDesc,
                      style:
                          const TextStyle(fontWeight: FontWeight.bold)),
                  Text('Path: $drivePath'),
                  const SizedBox(height: 12),
                  Text(
                    'This action cannot be undone.',
                    style: TextStyle(color: statusColors.error),
                  ),
                  if (sizeOnlyVerification) ...[
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: statusColors.warning
                            .withValues(alpha: 0.12),
                        border: Border.all(color: statusColors.warning),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.warning_amber,
                              color: statusColors.warning),
                          const SizedBox(width: 8),
                          const Expanded(
                            child: Text(
                              'Files were verified by size only, not content '
                              'hash. A corrupted file with the same byte size '
                              'as the source would have passed verification. '
                              'Proceed with caution.',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  Text(
                    'Type "$drivePath" to confirm:',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: controller,
                    autofocus: true,
                    decoration: InputDecoration(
                      border: const OutlineInputBorder(),
                      hintText: drivePath,
                    ),
                    onChanged: (_) => setDialogState(() {}),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: statusColors.error),
              onPressed: typedMatches
                  ? () => Navigator.pop(ctx, true)
                  : null,
              child: const Text('Erase'),
            ),
          ],
        );
      },
    ),
  );
  controller.dispose();
  return result ?? false;
}
