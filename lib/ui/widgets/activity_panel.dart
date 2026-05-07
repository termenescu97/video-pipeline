import 'package:flutter/material.dart';

import '../../database/database.dart';
import '../../database/tables.dart';
import '../../main.dart';
import '../../utils/history_export.dart';
import '../theme/app_theme.dart';
import '../theme/insets.dart';
import '../theme/text_styles.dart';
import 'confirmation_dialog.dart';
import 'job_card_done.dart';

/// Right-column activity panel (FR-031, FR-032). Subscribes to
/// `jobDao.watchCompletedJobs()`, groups history by day, renders each
/// completed job as `JobCardDone`, and exposes a prominent "Export CSV"
/// button at the bottom.
///
/// Day-grouping headers (local time):
///   Today / Yesterday / This week (≤7 days) / Older
///
/// The CSV export is shared with the Ctrl+E shortcut (US11 T097) via
/// `lib/utils/history_export.dart`, so the button and the shortcut both
/// invoke the same flow.
class ActivityPanel extends StatelessWidget {
  final ValueChanged<int>? onJobSelected;

  const ActivityPanel({super.key, this.onJobSelected});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: scheme.outlineVariant, width: 1),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
                Insets.l, Insets.l, Insets.l, Insets.s),
            child: Text(
              'Activity',
              style: AppTextStyles.title
                  .copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: StreamBuilder<List<Job>>(
              stream: jobDao.watchCompletedJobs(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                final jobs = snapshot.data ?? const <Job>[];
                if (jobs.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(Insets.l),
                      child: Text(
                        'Completed jobs will appear here.',
                        style: AppTextStyles.body
                            .copyWith(color: scheme.onSurfaceVariant),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  );
                }
                return _GroupedHistoryList(
                  jobs: jobs,
                  onJobSelected: onJobSelected,
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(Insets.m),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                onPressed: () => exportHistoryToCsv(context),
                icon: const Icon(Icons.download, size: 18),
                label: const Text('Export CSV'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _GroupedHistoryList extends StatelessWidget {
  final List<Job> jobs;
  final ValueChanged<int>? onJobSelected;

  const _GroupedHistoryList(
      {required this.jobs, required this.onJobSelected});

  @override
  Widget build(BuildContext context) {
    final groups = _groupByDay(jobs);
    final entries = <_Entry>[];
    for (final label in _kGroupOrder) {
      final groupJobs = groups[label] ?? const [];
      if (groupJobs.isEmpty) continue;
      entries.add(_Entry.header(label));
      for (final j in groupJobs) {
        entries.add(_Entry.job(j));
      }
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: Insets.s),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        if (entry.isHeader) {
          return _GroupHeader(label: entry.label!);
        }
        final job = entry.job!;
        return JobCardDone(
          job: job,
          onTap: onJobSelected != null
              ? () => onJobSelected!(job.id)
              : null,
          onDelete: () => _confirmAndDelete(context, job),
          onRetry:
              job.status == JobStatus.failed ? () => _retry(job.id) : null,
        );
      },
    );
  }

  Future<void> _retry(int jobId) async {
    await jobDao.resetJobForRetry(jobId);
  }

  /// Constitution Principle I: deletion is destructive and MUST require
  /// explicit confirmation. Mirrors the legacy queue-delete path
  /// (`HomeScreen._deleteJob`) so both surfaces share the same safety gate.
  Future<void> _confirmAndDelete(BuildContext context, Job job) async {
    final statusColors = Theme.of(context).extension<StatusColors>()!;
    final confirmed = await ConfirmationDialog.show(
      context: context,
      title: 'Delete from history',
      message:
          'Permanently remove this job from history?\n\n${job.sourcePath} → ${job.destinationPath}',
      confirmLabel: 'Delete',
      confirmColor: statusColors.error,
    );
    if (confirmed) {
      await jobDao.deleteJob(job.id);
    }
  }

  static const _kGroupOrder = [
    'Today',
    'Yesterday',
    'This week',
    'Older',
  ];

  static Map<String, List<Job>> _groupByDay(List<Job> jobs) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final weekStart = today.subtract(const Duration(days: 7));

    final out = <String, List<Job>>{
      'Today': <Job>[],
      'Yesterday': <Job>[],
      'This week': <Job>[],
      'Older': <Job>[],
    };
    for (final job in jobs) {
      final completedAt = job.completedAt ?? job.startedAt ?? job.createdAt;
      final day = DateTime(
          completedAt.year, completedAt.month, completedAt.day);
      String bucket;
      if (day == today) {
        bucket = 'Today';
      } else if (day == yesterday) {
        bucket = 'Yesterday';
      } else if (day.isAfter(weekStart) ||
          day.isAtSameMomentAs(weekStart)) {
        bucket = 'This week';
      } else {
        bucket = 'Older';
      }
      out[bucket]!.add(job);
    }
    return out;
  }
}

class _GroupHeader extends StatelessWidget {
  final String label;
  const _GroupHeader({required this.label});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          Insets.s, Insets.m, Insets.s, Insets.xs),
      child: Text(
        label.toUpperCase(),
        style: AppTextStyles.caption.copyWith(
          color: scheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
          letterSpacing: 1,
        ),
      ),
    );
  }
}

class _Entry {
  final String? label;
  final Job? job;
  final bool isHeader;
  const _Entry._(this.label, this.job, this.isHeader);
  factory _Entry.header(String label) => _Entry._(label, null, true);
  factory _Entry.job(Job job) => _Entry._(null, job, false);
}
