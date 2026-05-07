import 'package:flutter/material.dart';

import '../../database/database.dart';
import '../../database/tables.dart';
import '../../main.dart';
import '../theme/app_theme.dart';
import '../theme/insets.dart';
import '../theme/text_styles.dart';
import 'erase_drive_action.dart';

/// Ephemeral celebration card shown in the active slot when the queue
/// transitions from running to all-done with no failures (FR-012).
///
/// Persists for the green-dot lifetime — 5 minutes or until the operator
/// takes any next action (creates a job, starts the queue, dismisses
/// explicitly). Same `QueueStateNotifier` events drive both this card's
/// lifecycle and StatusBar's green-dot timer (T060).
///
/// Two CTAs:
///   [Erase Cards]: launches a SEQUENTIAL per-card erase flow (T061).
///                  Each detected card fires the existing typed-confirmation
///                  dialog once. CTA NEVER bulk-erases multiple drives behind
///                  a single confirmation (Constitution Principle I, FR-012).
///   [New Job]: opens the create-job form for the next batch.
class JobCardCompleted extends StatefulWidget {
  /// Snapshot of the jobs that just completed in this batch — used to
  /// derive the unique source drive paths so the erase sequence visits
  /// each card exactly once.
  final List<Job> recentJobs;

  /// Tap handler for [New Job] — wires through the shell to open
  /// CreateJobScreen.
  final VoidCallback onNewJob;

  /// Tap handler for "Dismiss" — clears this celebration immediately
  /// so the operator can manually return to the idle state.
  final VoidCallback onDismiss;

  const JobCardCompleted({
    super.key,
    required this.recentJobs,
    required this.onNewJob,
    required this.onDismiss,
  });

  @override
  State<JobCardCompleted> createState() => _JobCardCompletedState();
}

class _JobCardCompletedState extends State<JobCardCompleted> {
  /// Re-entrancy guard: when an "Erase Cards" sequence is in flight, a
  /// second tap on the CTA must not start a parallel sequence
  /// (concurrent typed-confirm dialogs would race the same drive letter).
  bool _eraseRunning = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final statusColors = Theme.of(context).extension<StatusColors>()!;

    final transferJobs = widget.recentJobs
        .where((j) => j.type != JobType.compression)
        .length;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            left:
                BorderSide(color: statusColors.dotRecentDone, width: 4),
          ),
        ),
        padding: const EdgeInsets.all(Insets.l),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.check_circle,
                    color: statusColors.success, size: 24),
                const SizedBox(width: Insets.s),
                Expanded(
                  child: Text(
                    'All cards copied & verified',
                    style: AppTextStyles.title,
                  ),
                ),
                IconButton(
                  tooltip: 'Dismiss',
                  icon: Icon(Icons.close,
                      size: 20, color: scheme.onSurfaceVariant),
                  onPressed: widget.onDismiss,
                ),
              ],
            ),
            const SizedBox(height: Insets.s),
            Text(
              _summaryLine(widget.recentJobs.length, transferJobs),
              style: AppTextStyles.body
                  .copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: Insets.l),
            Row(
              children: [
                FilledButton.icon(
                  onPressed: (transferJobs == 0 || _eraseRunning)
                      ? null
                      : () => _runSequentialErase(context),
                  icon: _eraseRunning
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.delete_forever, size: 18),
                  label: Text(_eraseRunning ? 'Erasing…' : 'Erase Cards'),
                  style: FilledButton.styleFrom(
                    backgroundColor: statusColors.error,
                  ),
                ),
                const SizedBox(width: Insets.s),
                OutlinedButton.icon(
                  onPressed: widget.onNewJob,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('New Job'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Subtitle: total jobs completed + (if some are compression) clarifies
  /// how many are erase-eligible. Prevents the count mismatch Codex
  /// flagged where "3 jobs completed" suggested 3 cards but only 2 were
  /// removable-source transfer jobs.
  String _summaryLine(int total, int transferJobs) {
    if (total == 1) return '1 job completed without errors.';
    if (transferJobs == total) {
      return '$total jobs completed without errors.';
    }
    return '$total jobs completed without errors '
        '($transferJobs from removable cards).';
  }

  /// Sequential per-card erase (T061, FR-012, Constitution Principle I).
  ///
  /// For each unique source drive in [widget.recentJobs] that is BOTH
  ///   (a) erase-eligible per [eraseEligibilityReason] (job completed,
  ///       all files verified — same gate as the header button), AND
  ///   (b) currently mounted (re-checked just before each dialog so a
  ///       card pulled mid-sequence is skipped, not aborted)
  /// invoke the standard `eraseSourceDrive` flow with full typed-
  /// confirmation dialog and identity re-check. The CTA never collapses
  /// multiple confirmations into one — each card requires its own typed
  /// confirmation.
  Future<void> _runSequentialErase(BuildContext context) async {
    if (_eraseRunning) return; // re-entrancy guard
    setState(() => _eraseRunning = true);
    try {
      // Distinct source drives from the just-completed batch (preserves
      // creation order so per-card subfolders stay deterministic).
      final seen = <String>{};
      final batchDrives = <Job>[];
      for (final job in widget.recentJobs) {
        if (job.type == JobType.compression) continue;
        if (seen.add(job.sourcePath)) batchDrives.add(job);
      }

      if (batchDrives.isEmpty) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No removable cards to erase.')),
        );
        return;
      }

      // CRITICAL (Codex): apply the SAME eligibility gate the per-job
      // header button uses. Without this, a celebration could include
      // a job whose files were marked unverified by a late update —
      // and the batch flow would still try to erase it.
      final eligible = <Job>[];
      var ineligible = 0;
      for (final job in batchDrives) {
        final files = await jobFileDao.getFilesForJob(job.id);
        if (eraseEligibilityReason(job, files) == null) {
          eligible.add(job);
        } else {
          ineligible++;
        }
      }
      if (!context.mounted) return;

      if (eligible.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text(
                  'No cards are eligible to erase yet (verification pending).')),
        );
        return;
      }

      var erased = 0;
      var skippedMissing = 0;
      var cancelledOrFailed = 0;
      for (final job in eligible) {
        // Refresh live drives BEFORE EACH dialog (Codex WARN): a stale
        // snapshot from the start of the loop would let us prompt for
        // a card that the operator has already pulled.
        final liveDrives = await driveService.getRemovableDrives();
        if (!context.mounted) return;
        final livePaths = liveDrives.map((d) => d.path).toSet();
        if (!livePaths.contains(job.sourcePath)) {
          skippedMissing++;
          continue;
        }
        if (!context.mounted) return;
        // ONE typed-confirmation dialog per card (FR-012). Silent so
        // the batch summary below is the only post-action snackbar.
        final ok = await eraseSourceDrive(context, job, silent: true);
        if (ok) {
          erased++;
        } else {
          cancelledOrFailed++;
        }
      }

      if (!context.mounted) return;
      // Codex WARN: replace per-card snackbar pile-up (each erase showed
      // its own "Erased OK" / "Failed" banner — 3 cards = 3 stacked
      // snackbars) with one summary line.
      final parts = <String>[];
      parts.add('Erased $erased of ${eligible.length}');
      if (cancelledOrFailed > 0) parts.add('$cancelledOrFailed cancelled/failed');
      if (skippedMissing > 0) parts.add('$skippedMissing not detected');
      if (ineligible > 0) parts.add('$ineligible not yet verified');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(parts.join(' · '))),
      );
    } finally {
      if (mounted) setState(() => _eraseRunning = false);
    }
  }
}
