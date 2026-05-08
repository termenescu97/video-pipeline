import 'package:flutter/material.dart';

import '../../database/database.dart';
import '../../database/tables.dart';
import '../../main.dart';
import '../../utils/history_export.dart';
import '../theme/insets.dart';
import '../theme/text_styles.dart';
import 'confirmation_dialog.dart';
import 'job_card_done.dart';

/// 017B (FR-B06/B07/B08): cross-job history surface. Replaces the
/// previous right-column ActivityPanel as the home for completed +
/// failed history, but with three new affordances:
///
///   1. Search box filters by source path AND operator name (case-
///      insensitive substring) — Ctrl+H focuses the search box.
///   2. Status filter chips include the v8 verify-axis distinctions
///      (Verified / Unverified / Mismatch / Failed) as separate from
///      "All" — Codex round-1 M6 hard requirement: a job whose ONLY
///      failure was verify mismatch must be findable as Mismatch, not
///      hidden inside a generic Failed bucket.
///   3. CSV export entry stays here so the original Ctrl+E shortcut
///      still has a visible counterpart.
///
/// Streams `jobDao.watchCompletedJobs()` and applies the filter
/// pipeline in-memory; performance is fine for the operator's
/// expected scale (hundreds, not millions).
class HistorySurface extends StatefulWidget {
  const HistorySurface({super.key});

  @override
  State<HistorySurface> createState() => _HistorySurfaceState();
}

enum _HistoryFilter { all, verified, unverified, mismatch, failed }

class _HistorySurfaceState extends State<HistorySurface> {
  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  _HistoryFilter _filter = _HistoryFilter.all;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(() {
      if (_searchCtrl.text != _query) {
        setState(() => _query = _searchCtrl.text);
      }
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /// Streams the verify-tally per-job so the status-filter chips can
  /// distinguish verified / unverified / mismatch / failed without
  /// re-walking JobFile rows on every build. We compute counts once
  /// per snapshot.
  bool _matchesFilter(Job job, _JobVerifyTally? tally) {
    switch (_filter) {
      case _HistoryFilter.all:
        return true;
      case _HistoryFilter.failed:
        return job.status == JobStatus.failed;
      case _HistoryFilter.verified:
        // "Verified" means clean: completed AND no unverified/mismatch.
        return job.status == JobStatus.completed &&
            (tally?.unverified ?? 0) == 0 &&
            (tally?.mismatched ?? 0) == 0;
      case _HistoryFilter.unverified:
        return (tally?.unverified ?? 0) > 0;
      case _HistoryFilter.mismatch:
        return (tally?.mismatched ?? 0) > 0;
    }
  }

  bool _matchesQuery(Job job) {
    if (_query.isEmpty) return true;
    final q = _query.toLowerCase();
    return job.sourcePath.toLowerCase().contains(q) ||
        (job.operatorName ?? '').toLowerCase().contains(q);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
                Insets.l, Insets.m, Insets.s, Insets.xs),
            child: Row(
              children: [
                Text('History',
                    style: AppTextStyles.title
                        .copyWith(color: scheme.onSurfaceVariant)),
                const Spacer(),
                IconButton(
                  tooltip: 'Export CSV (Ctrl+E)',
                  icon: const Icon(Icons.download, size: 20),
                  onPressed: () => exportHistoryToCsv(context),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
                Insets.l, 0, Insets.l, Insets.s),
            child: TextField(
              controller: _searchCtrl,
              focusNode: _searchFocus,
              decoration: const InputDecoration(
                hintText: 'Search source path or operator…',
                prefixIcon: Icon(Icons.search, size: 18),
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
          ),
          // Status filter chips (single-row horizontal scroll, mirrors
          // FR-B05 from the FilesTab).
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(
                Insets.l, 0, Insets.l, Insets.s),
            child: Row(
              children: [
                _filterChip('All', _HistoryFilter.all),
                const SizedBox(width: Insets.xs),
                _filterChip('Verified', _HistoryFilter.verified),
                const SizedBox(width: Insets.xs),
                _filterChip('Unverified', _HistoryFilter.unverified),
                const SizedBox(width: Insets.xs),
                _filterChip('Mismatch', _HistoryFilter.mismatch),
                const SizedBox(width: Insets.xs),
                _filterChip('Failed', _HistoryFilter.failed),
              ],
            ),
          ),
          const Divider(height: 1),
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 80, maxHeight: 600),
            child: StreamBuilder<List<Job>>(
              stream: jobDao.watchCompletedJobs(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Padding(
                    padding: EdgeInsets.all(Insets.l),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                final allJobs = snapshot.data ?? const <Job>[];
                if (allJobs.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.all(Insets.l),
                    child: Text(
                      'Completed jobs will appear here.',
                      style: AppTextStyles.body
                          .copyWith(color: scheme.onSurfaceVariant),
                      textAlign: TextAlign.center,
                    ),
                  );
                }
                return _FilteredHistoryList(
                  jobs: allJobs,
                  matchesFilter: _matchesFilter,
                  matchesQuery: _matchesQuery,
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _filterChip(String label, _HistoryFilter value) {
    return FilterChip(
      label: Text(label, style: AppTextStyles.caption),
      selected: _filter == value,
      onSelected: (_) => setState(() => _filter = value),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }
}

/// Walks the per-job JobFile list once per snapshot to compute the
/// verify-tally needed by the status-filter chips. The list is small
/// for the operator's expected scale (a few hundred jobs); if this
/// becomes a bottleneck, swap the per-row stream for an aggregate DAO
/// query.
class _FilteredHistoryList extends StatelessWidget {
  final List<Job> jobs;
  final bool Function(Job, _JobVerifyTally?) matchesFilter;
  final bool Function(Job) matchesQuery;

  const _FilteredHistoryList({
    required this.jobs,
    required this.matchesFilter,
    required this.matchesQuery,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<JobFile>>(
      stream: jobFileDao.watchAllFiles(),
      builder: (context, snapshot) {
        final files = snapshot.data ?? const <JobFile>[];
        final tallies = _JobVerifyTally.fromFiles(files);
        final filtered = jobs.where((j) {
          if (!matchesQuery(j)) return false;
          return matchesFilter(j, tallies[j.id]);
        }).toList();
        if (filtered.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(Insets.l),
            child: Text(
              'No jobs match.',
              style: AppTextStyles.body.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          );
        }
        return ListView.builder(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(
              horizontal: Insets.s, vertical: Insets.s),
          itemCount: filtered.length,
          itemBuilder: (context, index) {
            final job = filtered[index];
            return JobCardDone(
              job: job,
              isExpanded: false,
              onTap: null,
              onRetry: job.status == JobStatus.failed
                  ? () => jobDao.resetJobForRetry(job.id)
                  : null,
              onDelete: () => _confirmAndDelete(context, job),
            );
          },
        );
      },
    );
  }

  Future<void> _confirmAndDelete(BuildContext context, Job job) async {
    final confirmed = await ConfirmationDialog.showDestructive(
      context: context,
      title: 'Delete from history',
      message:
          'Permanently remove this job from history?\n\n${job.sourcePath} → ${job.destinationPath}',
      confirmLabel: 'Delete',
    );
    if (confirmed) {
      await jobDao.deleteJob(job.id);
    }
  }
}

/// Per-job aggregate of verify-axis row counts. Used by the status
/// filter chips to determine whether a completed job belongs in the
/// Verified / Unverified / Mismatch buckets.
class _JobVerifyTally {
  final int unverified;
  final int mismatched;

  const _JobVerifyTally(
      {required this.unverified, required this.mismatched});

  static Map<int, _JobVerifyTally> fromFiles(List<JobFile> files) {
    final byJob = <int, List<JobFile>>{};
    for (final f in files) {
      byJob.putIfAbsent(f.jobId, () => <JobFile>[]).add(f);
    }
    return {
      for (final e in byJob.entries)
        e.key: _JobVerifyTally(
          unverified: e.value
              .where((f) => f.verifyStatus == VerifyStatus.unverified)
              .length,
          mismatched: e.value
              .where((f) => f.verifyStatus == VerifyStatus.mismatch)
              .length,
        ),
    };
  }
}
