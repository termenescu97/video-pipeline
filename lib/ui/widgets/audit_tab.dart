import 'package:flutter/material.dart';

import '../../database/database.dart';
import '../../database/extensions.dart';
import '../../utils/format_utils.dart';
import '../theme/app_theme.dart';
import '../theme/insets.dart';
import '../theme/text_styles.dart';

/// Audit tab inside DetailTabs (Phase F). Shows the full job timeline plus
/// verification mode, operator, total bytes, and hash trail.
///
/// Implemented as a single `ListView.builder` so the hash trail is
/// virtualized — at 200+ verified files this matters. Items:
///   index 0: Summary card
///   index 1: Timeline card
///   index 2: Hash-trail header card (count + empty-message if zero)
///   index 3..N: one card per verified file with its source / dest hashes
///
/// Files come from the parent's single subscription (Phase 7 fix-commit
/// refactor).
class AuditTab extends StatelessWidget {
  final Job job;
  final List<JobFile> files;

  const AuditTab({super.key, required this.job, required this.files});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final verifiedFiles =
        files.where((f) => f.verified && f.sourceHash != null).toList();

    // Static items (summary, timeline, hash-trail header) + virtualized
    // hash entries.
    const headerCount = 3;
    final itemCount = headerCount + verifiedFiles.length;

    return ListView.builder(
      padding: const EdgeInsets.symmetric(
          horizontal: Insets.l, vertical: Insets.s),
      itemCount: itemCount,
      itemBuilder: (context, index) {
        if (index == 0) {
          return _SummarySection(job: job);
        }
        if (index == 1) {
          return Padding(
            padding: const EdgeInsets.only(top: Insets.m),
            child: _TimelineSection(job: job),
          );
        }
        if (index == 2) {
          return Padding(
            padding: const EdgeInsets.only(top: Insets.m),
            child: _HashTrailHeader(count: verifiedFiles.length),
          );
        }
        final file = verifiedFiles[index - headerCount];
        return Padding(
          padding: const EdgeInsets.only(top: Insets.s),
          child: _HashEntry(file: file, scheme: scheme),
        );
      },
    );
  }
}

class _SummarySection extends StatelessWidget {
  final Job job;
  const _SummarySection({required this.job});

  @override
  Widget build(BuildContext context) {
    return _Section(
      title: 'Summary',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _kv('Type', job.type.label),
          _kv('Status', job.status.label),
          _kv('Verification', job.verificationMode.label),
          if ((job.operatorName ?? '').isNotEmpty)
            _kv('Operator', job.operatorName!),
          _kv('Total files', '${job.totalFiles}'),
          _kv('Completed files', '${job.completedFiles}'),
          if (job.totalBytes > 0)
            _kv('Total bytes', formatBytes(job.totalBytes)),
        ],
      ),
    );
  }
}

class _TimelineSection extends StatelessWidget {
  final Job job;
  const _TimelineSection({required this.job});

  @override
  Widget build(BuildContext context) {
    return _Section(
      title: 'Timeline',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _kv('Created', _formatDate(job.createdAt)),
          _kv(
              'Started',
              job.startedAt != null
                  ? _formatDate(job.startedAt!)
                  : '—'),
          _kv(
              'Completed',
              job.completedAt != null
                  ? _formatDate(job.completedAt!)
                  : '—'),
          if (job.startedAt != null && job.completedAt != null)
            _kv(
                'Duration',
                formatDuration(
                    job.completedAt!.difference(job.startedAt!))),
          if (job.errorMessage != null)
            Padding(
              padding: const EdgeInsets.only(top: Insets.s),
              child: Text(
                'Error: ${job.errorMessage}',
                style: TextStyle(
                  color: Theme.of(context)
                      .extension<StatusColors>()!
                      .error,
                  fontSize: 13,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _HashTrailHeader extends StatelessWidget {
  final int count;
  const _HashTrailHeader({required this.count});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _Section(
      title: 'Hash trail ($count)',
      child: count == 0
          ? Text(
              'No SHA-256 hashes recorded for this job.',
              style: AppTextStyles.caption
                  .copyWith(color: scheme.onSurfaceVariant),
            )
          : Text(
              '$count file${count == 1 ? '' : 's'} verified by SHA-256.',
              style: AppTextStyles.caption
                  .copyWith(color: scheme.onSurfaceVariant),
            ),
    );
  }
}

Widget _kv(String key, String value) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 120,
          child: Text(key, style: AppTextStyles.caption),
        ),
        Expanded(
          child: Text(value, style: AppTextStyles.body),
        ),
      ],
    ),
  );
}

String _formatDate(DateTime t) {
  final y = t.year.toString();
  final mo = t.month.toString().padLeft(2, '0');
  final d = t.day.toString().padLeft(2, '0');
  final h = t.hour.toString().padLeft(2, '0');
  final m = t.minute.toString().padLeft(2, '0');
  return '$y-$mo-$d $h:$m';
}

class _Section extends StatelessWidget {
  final String title;
  final Widget child;

  const _Section({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Insets.m),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title.toUpperCase(),
            style: AppTextStyles.caption.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: Insets.s),
          child,
        ],
      ),
    );
  }
}

class _HashEntry extends StatelessWidget {
  final JobFile file;
  final ColorScheme scheme;

  const _HashEntry({required this.file, required this.scheme});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Insets.s),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(file.fileName, style: AppTextStyles.body),
          const SizedBox(height: Insets.xxs),
          SelectableText(
            'src: ${file.sourceHash ?? '—'}',
            style: AppTextStyles.mono.copyWith(
                color: scheme.onSurfaceVariant, fontSize: 11),
          ),
          SelectableText(
            'dst: ${file.destinationHash ?? '—'}',
            style: AppTextStyles.mono.copyWith(
                color: scheme.onSurfaceVariant, fontSize: 11),
          ),
        ],
      ),
    );
  }
}
