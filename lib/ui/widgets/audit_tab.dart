import 'package:flutter/material.dart';

import '../../database/database.dart';
import '../../database/extensions.dart';
import '../../main.dart';
import '../../utils/format_utils.dart';
import '../theme/app_theme.dart';
import '../theme/insets.dart';
import '../theme/text_styles.dart';

/// Audit tab inside DetailTabs (Phase F). Shows the full job timeline plus
/// verification mode, operator, total bytes, and hash trail summary.
///
/// Layout (top to bottom, single ListView for natural scrolling at narrow
/// widths):
///   1. Job summary (status, type, operator, verification, totals)
///   2. Timeline (created → started → completed; file count breakdown)
///   3. Hash trail — every verified file's source + destination hashes
///      in JetBrains Mono (rendered selectable for copy-paste)
class AuditTab extends StatelessWidget {
  final Job job;

  const AuditTab({super.key, required this.job});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return StreamBuilder<List<JobFile>>(
      stream: jobFileDao.watchFilesForJob(job.id),
      builder: (context, snapshot) {
        final files = snapshot.data ?? const <JobFile>[];
        final verifiedFiles =
            files.where((f) => f.verified && f.sourceHash != null).toList();
        return ListView(
          padding: const EdgeInsets.symmetric(
              horizontal: Insets.l, vertical: Insets.s),
          children: [
            _Section(
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
            ),
            const SizedBox(height: Insets.m),
            _Section(
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
            ),
            const SizedBox(height: Insets.m),
            _Section(
              title: 'Hash trail (${verifiedFiles.length})',
              child: verifiedFiles.isEmpty
                  ? Text(
                      'No SHA-256 hashes recorded for this job.',
                      style: AppTextStyles.caption
                          .copyWith(color: scheme.onSurfaceVariant),
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final f in verifiedFiles)
                          _HashEntry(file: f, scheme: scheme),
                      ],
                    ),
            ),
            const SizedBox(height: Insets.m),
          ],
        );
      },
    );
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

  static String _formatDate(DateTime t) {
    final y = t.year.toString();
    final mo = t.month.toString().padLeft(2, '0');
    final d = t.day.toString().padLeft(2, '0');
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '$y-$mo-$d $h:$m';
  }
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
    return Padding(
      padding: const EdgeInsets.only(top: Insets.s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(file.fileName, style: AppTextStyles.body),
          const SizedBox(height: 2),
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
