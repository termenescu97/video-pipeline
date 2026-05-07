import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../database/tables.dart';
import '../../main.dart';
import '../../services/drive_service.dart';
import '../../services/job_queue_service.dart';
import '../../utils/format_utils.dart';
import '../theme/app_theme.dart';
import '../theme/insets.dart';
import 'conflict_dialog.dart';

/// Review-first batch flow for "Copy All Cards" (FR-029, FR-030).
///
/// Layout (top to bottom):
///   1. Detected cards with per-card checkboxes (CARDS FIRST)
///   2. Destination picker with free-space sentence
///   3. Verification mode SegmentedButton
///   4. Plan summary line (total jobs, total bytes, validity verdict)
///   5. [Create N Jobs] button
///
/// Drive-snapshot policy: detected drives are captured when this dialog is
/// constructed (no live polling inside). Before creating jobs, each selected
/// drive is re-checked; if any disappeared, an inline error is shown and
/// the batch is aborted.
class CopyAllCardsDialog extends StatefulWidget {
  /// Snapshot of detected drives at the moment the dialog is opened.
  final List<DetectedDrive> initialDrives;

  /// Pre-fill destination (typically the last-used destination from
  /// settings).
  final String? initialDestination;

  const CopyAllCardsDialog({
    super.key,
    required this.initialDrives,
    this.initialDestination,
  });

  /// Convenience launcher. Returns true if jobs were created, false if the
  /// operator cancelled or no jobs were created.
  static Future<bool> show(BuildContext context) async {
    final drives = await driveService.getRemovableDrives();
    if (drives.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No removable drives detected')),
        );
      }
      return false;
    }
    final settings = await settingsDao.getSettings();
    final initialDest = (settings?.lastUsedDestination ?? '').isNotEmpty
        ? settings!.lastUsedDestination
        : null;
    if (!context.mounted) return false;
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => CopyAllCardsDialog(
        initialDrives: drives,
        initialDestination: initialDest,
      ),
    );
    return result == true;
  }

  @override
  State<CopyAllCardsDialog> createState() => _CopyAllCardsDialogState();
}

class _CopyAllCardsDialogState extends State<CopyAllCardsDialog> {
  late Set<String> _selectedDrivePaths;
  late String? _destination;
  VerificationMode _verificationMode = VerificationMode.size;
  int? _destinationFreeBytes;
  String? _vanishedDriveError;
  bool _creating = false;

  @override
  void initState() {
    super.initState();
    _selectedDrivePaths =
        widget.initialDrives.map((d) => d.path).toSet();
    _destination = widget.initialDestination;
    if (_destination != null) _refreshFreeSpace();
  }

  Future<void> _refreshFreeSpace() async {
    if (_destination == null) return;
    final free = await driveService.getDiskFreeSpace(_destination!);
    if (mounted) {
      setState(() => _destinationFreeBytes = free > 0 ? free : null);
    }
  }

  Future<void> _pickDestination() async {
    final picked = await FilePicker.platform.getDirectoryPath();
    if (picked == null) return;
    setState(() => _destination = picked);
    _refreshFreeSpace();
  }

  int get _selectedDriveCount => _selectedDrivePaths.length;

  int get _selectedUsedBytes => widget.initialDrives
      .where((d) => _selectedDrivePaths.contains(d.path))
      .fold<int>(0, (sum, d) => sum + d.usedBytes);

  bool get _canCreate =>
      !_creating &&
      _selectedDriveCount > 0 &&
      (_destination ?? '').isNotEmpty;

  Future<void> _create() async {
    if (!_canCreate) return;
    setState(() {
      _creating = true;
      _vanishedDriveError = null;
    });

    // Re-check drives are still present.
    final liveDrives = await driveService.getRemovableDrives();
    final livePaths = liveDrives.map((d) => d.path).toSet();
    final vanished = _selectedDrivePaths
        .where((p) => !livePaths.contains(p))
        .toList();
    if (vanished.isNotEmpty) {
      if (mounted) {
        setState(() {
          _creating = false;
          _vanishedDriveError =
              'Drive${vanished.length == 1 ? '' : 's'} no longer detected: '
              '${vanished.join(', ')}. Re-insert and try again.';
        });
      }
      return;
    }

    // Filter to the operator's selection (in original order so per-card
    // subfolders stay deterministic).
    final selectedDrives = widget.initialDrives
        .where((d) => _selectedDrivePaths.contains(d.path))
        .toList();

    var destination = _destination!;
    while (true) {
      ConflictResolution? lastChoice;
      final result = await jobQueueService.createBatchTransferJobs(
        selectedDrives,
        destination,
        verificationMode: _verificationMode,
        onConflict: (conflicts) async {
          if (!mounted) return ConflictResolution.cancel;
          final choice =
              await ConflictResolutionDialog.show(context, conflicts);
          lastChoice = choice ?? ConflictResolution.cancel;
          return lastChoice!;
        },
      );

      if (lastChoice == ConflictResolution.newFolder) {
        final newDest = await FilePicker.platform.getDirectoryPath();
        if (newDest == null) {
          if (mounted) setState(() => _creating = false);
          return;
        }
        destination = newDest;
        continue;
      }

      if (lastChoice == ConflictResolution.cancel) {
        if (mounted) setState(() => _creating = false);
        return;
      }

      if (result.created > 0) {
        await settingsDao.setFirstRunCompleted(true);
        await settingsDao.setLastUsedDestination(destination);
      }

      if (mounted) {
        Navigator.of(context).pop(result.created > 0);
        final String msg;
        if (result.created == 0 && result.conflicts.isNotEmpty) {
          msg = 'All files already exist at destination — no jobs created.';
        } else if (result.skipped > 0) {
          msg =
              'Created ${result.created} jobs, skipped ${result.skipped} empty cards';
        } else {
          msg = 'Created ${result.created} jobs';
        }
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(msg)));
      }
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final statusColors = Theme.of(context).extension<StatusColors>()!;
    final spaceShort = _destinationFreeBytes != null &&
        _selectedUsedBytes > _destinationFreeBytes!;

    return AlertDialog(
      title: const Text('Copy All Cards'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Cards FIRST.
              Text('Detected cards',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: Insets.s),
              if (widget.initialDrives.isEmpty)
                Text(
                  'No removable drives detected.',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                )
              else
                ...widget.initialDrives.map((drive) {
                  final selected = _selectedDrivePaths.contains(drive.path);
                  return CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: selected,
                    onChanged: (v) {
                      setState(() {
                        if (v == true) {
                          _selectedDrivePaths.add(drive.path);
                        } else {
                          _selectedDrivePaths.remove(drive.path);
                        }
                      });
                    },
                    title: Text(
                      '${drive.path}  ${drive.label}',
                      style: const TextStyle(fontSize: 14),
                    ),
                    subtitle: Text(
                      drive.displaySize,
                      style: TextStyle(
                          fontSize: 12, color: scheme.onSurfaceVariant),
                    ),
                  );
                }),

              const SizedBox(height: Insets.l),
              const Divider(),
              const SizedBox(height: Insets.s),

              // Destination.
              Text('Destination',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: Insets.s),
              Row(
                children: [
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: Insets.m, vertical: 14),
                      decoration: BoxDecoration(
                        border: Border.all(color: scheme.outline),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        _destination ?? 'No folder selected',
                        style: TextStyle(
                          color: _destination != null
                              ? null
                              : scheme.onSurfaceVariant,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  const SizedBox(width: Insets.s),
                  IconButton(
                    icon: const Icon(Icons.folder_open),
                    onPressed: _pickDestination,
                    tooltip: 'Browse',
                  ),
                ],
              ),
              if (_destinationFreeBytes != null)
                Padding(
                  padding: const EdgeInsets.only(top: Insets.xs),
                  child: Text(
                    spaceShort
                        ? "${formatBytes(_destinationFreeBytes!)} free — won't fit "
                            "(${formatBytes(_selectedUsedBytes)} to copy)"
                        : '${formatBytes(_destinationFreeBytes!)} free',
                    style: TextStyle(
                      fontSize: 12,
                      color: spaceShort
                          ? statusColors.error
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                ),

              const SizedBox(height: Insets.l),

              // Verification mode.
              Text('Verification',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: Insets.s),
              SegmentedButton<VerificationMode>(
                segments: const [
                  ButtonSegment(
                    value: VerificationMode.size,
                    label: Text('Quick (size)'),
                    icon: Icon(Icons.speed),
                  ),
                  ButtonSegment(
                    value: VerificationMode.sha256,
                    label: Text('Full (SHA-256)'),
                    icon: Icon(Icons.verified_user),
                  ),
                ],
                selected: {_verificationMode},
                onSelectionChanged: (s) =>
                    setState(() => _verificationMode = s.first),
              ),

              const SizedBox(height: Insets.l),
              const Divider(),

              // Plan summary line.
              Padding(
                padding: const EdgeInsets.only(top: Insets.s),
                child: Text(
                  _planSummaryText(spaceShort: spaceShort),
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: spaceShort
                        ? statusColors.error
                        : scheme.onSurface,
                  ),
                ),
              ),

              if (_vanishedDriveError != null)
                Padding(
                  padding: const EdgeInsets.only(top: Insets.s),
                  child: Container(
                    padding: const EdgeInsets.all(Insets.s),
                    decoration: BoxDecoration(
                      color: statusColors.error.withValues(alpha: 0.1),
                      border: Border.all(color: statusColors.error),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      _vanishedDriveError!,
                      style: TextStyle(
                          color: statusColors.error, fontSize: 13),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed:
              _creating ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _canCreate && !spaceShort ? _create : null,
          child: Text(_creating
              ? 'Creating…'
              : 'Create $_selectedDriveCount Job${_selectedDriveCount == 1 ? '' : 's'}'),
        ),
      ],
    );
  }

  String _planSummaryText({required bool spaceShort}) {
    if (_selectedDriveCount == 0) return 'Plan: no cards selected';
    final approxBytes = _selectedUsedBytes;
    final bytesText =
        approxBytes > 0 ? ' · ~${formatBytes(approxBytes)}' : '';
    final verdict = spaceShort ? "won't fit" : 'OK';
    return 'Plan: $_selectedDriveCount '
        'job${_selectedDriveCount == 1 ? '' : 's'}$bytesText · $verdict';
  }
}
