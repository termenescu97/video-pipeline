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
class JobCardCompleted extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final statusColors = Theme.of(context).extension<StatusColors>()!;

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
                  onPressed: onDismiss,
                ),
              ],
            ),
            const SizedBox(height: Insets.s),
            Text(
              recentJobs.length == 1
                  ? '1 job completed without errors.'
                  : '${recentJobs.length} jobs completed without errors.',
              style: AppTextStyles.body
                  .copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: Insets.l),
            Row(
              children: [
                FilledButton.icon(
                  onPressed: () => _runSequentialErase(context),
                  icon: const Icon(Icons.delete_forever, size: 18),
                  label: const Text('Erase Cards'),
                  style: FilledButton.styleFrom(
                    backgroundColor: statusColors.error,
                  ),
                ),
                const SizedBox(width: Insets.s),
                OutlinedButton.icon(
                  onPressed: onNewJob,
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

  /// Sequential per-card erase (T061, FR-012, Constitution Principle I).
  ///
  /// For each unique source drive in [recentJobs] that's still detected,
  /// invoke the standard `eraseSourceDrive` flow (with full typed-
  /// confirmation dialog and identity re-check). The CTA never collapses
  /// multiple confirmations into one — each card requires its own typed
  /// confirmation. The operator can cancel any individual card mid-
  /// sequence; already-erased cards stay erased.
  Future<void> _runSequentialErase(BuildContext context) async {
    // Distinct source drives from the just-completed batch (preserves
    // creation order so per-card subfolders stay deterministic).
    final seen = <String>{};
    final batchDrives = <Job>[];
    for (final job in recentJobs) {
      if (job.type == JobType.compression) continue;
      if (seen.add(job.sourcePath)) batchDrives.add(job);
    }

    if (batchDrives.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No removable cards to erase.')),
      );
      return;
    }

    final liveDrives = await driveService.getRemovableDrives();
    if (!context.mounted) return;
    final livePaths = liveDrives.map((d) => d.path).toSet();

    var erased = 0;
    var skipped = 0;
    for (final job in batchDrives) {
      // Skip drives that are no longer present rather than aborting
      // the whole sequence — operator may have already pulled some.
      if (!livePaths.contains(job.sourcePath)) {
        skipped++;
        continue;
      }
      if (!context.mounted) return;
      // ONE typed-confirmation dialog per card (FR-012).
      final ok = await eraseSourceDrive(context, job);
      if (ok) erased++;
    }

    if (!context.mounted) return;
    final parts = <String>[];
    if (erased > 0) {
      parts.add('Erased $erased card${erased == 1 ? '' : 's'}');
    }
    if (skipped > 0) {
      parts.add(
          'skipped $skipped (not detected)');
    }
    if (parts.isEmpty) parts.add('No cards erased');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(parts.join(' · '))),
    );
  }
}
