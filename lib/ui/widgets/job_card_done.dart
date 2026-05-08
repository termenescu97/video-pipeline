import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../database/database.dart';
import '../../database/tables.dart';
import '../../main.dart';
import '../../utils/format_utils.dart';
import '../theme/app_theme.dart';
import '../theme/insets.dart';
import '../theme/text_styles.dart';
import 'detail_tabs.dart';

/// Compact dimmed variant for completed/failed jobs (history).
///
/// 48 px tall. State dot communicates success vs failure; type glyph stays
/// monochrome (color reserved for state per FR-009). Only ⋯ overflow is
/// surfaced — primary actions (Retry, View Details) live in the menu.
/// When [isExpanded] is true, an inline [DetailTabs] panel renders below
/// with the Audit tab pre-selected (history-friendly default per T054).
class JobCardDone extends StatelessWidget {
  final Job job;
  final bool isExpanded;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;
  final VoidCallback? onRetry;

  const JobCardDone({
    super.key,
    required this.job,
    this.isExpanded = false,
    this.onTap,
    this.onDelete,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    // 017 (Codex round-2 P2 #3): wrap the row in a JobFile stream so a
    // completed job with verifyStatus=mismatch files can surface an
    // attention-state dot AND a Retry menu entry — without this, a job
    // whose ONLY failure mode was verify mismatch would land in
    // history with no recovery path (only failed jobs get Retry).
    //
    // 017B (Codex round-14 P2 #1): unverified rows (SHA-256 subsystem
    // failure, bytes might be fine) get the same treatment — without
    // it, an unverified-only job has no way to either re-attempt the
    // hash check or accept the warning, and a transferAndCompress
    // parent with such a job is stuck because the auto-chain is
    // suppressed but the warning can't be cleared.
    return StreamBuilder<List<JobFile>>(
      stream: jobFileDao.watchFilesForJob(job.id),
      builder: (context, snapshot) {
        final files = snapshot.data ?? const <JobFile>[];
        final mismatchedIds = files
            .where((f) => f.verifyStatus == VerifyStatus.mismatch)
            .map((f) => f.id)
            .toList();
        final unverifiedIds = files
            .where((f) => f.verifyStatus == VerifyStatus.unverified)
            .map((f) => f.id)
            .toList();
        return _buildCard(context, mismatchedIds, unverifiedIds);
      },
    );
  }

  Widget _buildCard(
      BuildContext context, List<int> mismatchedIds, List<int> unverifiedIds) {
    final hasMismatch = mismatchedIds.isNotEmpty;
    final hasUnverified = unverifiedIds.isNotEmpty;
    final scheme = Theme.of(context).colorScheme;
    final statusColors = Theme.of(context).extension<StatusColors>()!;
    final dotColor = (job.status == JobStatus.failed || hasMismatch)
        ? statusColors.dotAttention
        : (hasUnverified
            ? statusColors.dotWarning
            : statusColors.dotRecentDone);
    final src = p.basename(job.sourcePath.replaceAll(RegExp(r'[/\\]$'), ''));
    final dst =
        p.basename(job.destinationPath.replaceAll(RegExp(r'[/\\]$'), ''));
    final completedSuffix = job.completedAt != null
        ? ' · ${formatRelativeTime(job.completedAt!)}'
        : '';

    return GestureDetector(
      onSecondaryTapDown: (details) => _showContextMenu(
          context, details.globalPosition, mismatchedIds, unverifiedIds),
      child: Card(
        clipBehavior: Clip.antiAlias,
        // Use a slightly muted surface for the "dimmed" look.
        color: scheme.surfaceContainerLowest,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              onTap: onTap,
              child: Container(
                height: 48,
                decoration: BoxDecoration(
                  border: Border(
                    left: BorderSide(color: dotColor, width: 4),
                  ),
                ),
                padding: const EdgeInsets.symmetric(
                    horizontal: Insets.l, vertical: Insets.xs),
                child: Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                      color: dotColor, shape: BoxShape.circle),
                ),
                const SizedBox(width: Insets.s),
                Icon(_typeGlyph(job.type),
                    size: 16, color: scheme.onSurfaceVariant),
                const SizedBox(width: Insets.s),
                Expanded(
                  child: Tooltip(
                    message:
                        '${job.sourcePath} → ${job.destinationPath}',
                    child: Text(
                      '$src → $dst$completedSuffix',
                      style: AppTextStyles.caption
                          .copyWith(color: scheme.onSurfaceVariant),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                if (hasMismatch) ...[
                  Tooltip(
                    message: '${mismatchedIds.length} file(s) failed verify '
                        '— right-click to Retry',
                    child: Icon(Icons.error_outline,
                        size: 16, color: statusColors.error),
                  ),
                  const SizedBox(width: Insets.xs),
                ] else if (hasUnverified) ...[
                  Tooltip(
                    message: '${unverifiedIds.length} file(s) unverified '
                        '(hash subsystem failure) — right-click to Retry verify',
                    child: Icon(Icons.help_outline,
                        size: 16, color: statusColors.warning),
                  ),
                  const SizedBox(width: Insets.xs),
                ],
                Builder(
                  builder: (btnContext) => IconButton(
                    tooltip: 'More actions',
                    icon: const Icon(Icons.more_horiz, size: 18),
                    visualDensity: VisualDensity.compact,
                    onPressed: () {
                      final box = btnContext.findRenderObject() as RenderBox?;
                      final pos = box?.localToGlobal(Offset.zero) ??
                          Offset.zero;
                      _showContextMenu(
                          context, pos, mismatchedIds, unverifiedIds);
                    },
                  ),
                ),
              ],
            ),
              ),
            ),
            if (isExpanded)
              Container(
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(color: scheme.outlineVariant, width: 1),
                  ),
                ),
                height: 320,
                child: DetailTabs.forDone(job: job),
              ),
          ],
        ),
      ),
    );
  }

  void _showContextMenu(BuildContext context, Offset position,
      List<int> mismatchedIds, List<int> unverifiedIds) {
    final hasMismatch = mismatchedIds.isNotEmpty;
    final hasUnverified = unverifiedIds.isNotEmpty;
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
          position.dx, position.dy, position.dx, position.dy),
      items: [
        const PopupMenuItem(value: 'details', child: Text('View Details')),
        if (job.status == JobStatus.failed)
          const PopupMenuItem(value: 'retry', child: Text('Retry')),
        // 017 (Codex round-2 P2 #3): a completed job with verify-mismatch
        // files needs a recovery path even though JobStatus is completed.
        // Retries each mismatched file with forceDestDelete=true (Codex H2).
        if (hasMismatch)
          PopupMenuItem(
            value: 'retry-mismatched',
            child: Text('Retry ${mismatchedIds.length} mismatched file(s)'),
          ),
        // 017B (Codex round-12 P2): accept the mismatch path. Mirrors the
        // active-card banner's Skip button: operator explicitly retains
        // the on-disk bytes, audit trail preserved.
        if (hasMismatch)
          PopupMenuItem(
            value: 'accept-mismatched',
            child: Text(
                'Accept ${mismatchedIds.length} mismatch(es) (skip retry)'),
          ),
        // 017B (Codex round-14 P2 #1): unverified rows need their own
        // retry/accept paths. Retry re-runs hash verification only;
        // Accept marks the file as accepted-baseline so a
        // transferAndCompress parent can resume its compression chain
        // via maybeChainCompression below.
        if (hasUnverified)
          PopupMenuItem(
            value: 'retry-unverified',
            child: Text(
                'Retry verify on ${unverifiedIds.length} unverified file(s)'),
          ),
        if (hasUnverified)
          PopupMenuItem(
            value: 'accept-unverified',
            child: Text(
                'Accept ${unverifiedIds.length} unverified (compress as-is)'),
          ),
        const PopupMenuItem(value: 'delete', child: Text('Delete')),
      ],
    ).then((value) {
      if (!context.mounted) return;
      if (value == 'details') onTap?.call();
      if (value == 'retry') onRetry?.call();
      if (value == 'retry-mismatched') {
        _retryMismatchedFiles(context, mismatchedIds);
      }
      if (value == 'accept-mismatched') {
        _acceptMismatchedFiles(context, mismatchedIds);
      }
      if (value == 'retry-unverified') {
        _retryUnverifiedFiles(context, unverifiedIds);
      }
      if (value == 'accept-unverified') {
        _acceptUnverifiedFiles(context, unverifiedIds);
      }
      if (value == 'delete') onDelete?.call();
    });
  }

  /// 017B (Codex round-14 P2 #1): re-run hash verification on rows
  /// that previously hit a SHA-256 subsystem failure. Bytes on disk
  /// are believed correct; we just couldn't compute the hash. No
  /// forceDestDelete — the dest is kept and re-hashed.
  Future<void> _retryUnverifiedFiles(
      BuildContext context, List<int> ids) async {
    final messenger = ScaffoldMessenger.of(context);
    for (final id in ids) {
      await jobQueueService.retryFile(id, forceDestDelete: false);
    }
    await jobQueueService.startProcessing();
    messenger.showSnackBar(
      SnackBar(
          content: Text('Re-running SHA-256 verify on ${ids.length} file(s)')),
    );
  }

  /// 017B (Codex round-14 P2 #1+#2): operator accepts the unverified
  /// state — bytes on disk are kept; the file rows transition from
  /// `unverified` to `notVerified` (size-mode baseline) so the
  /// auto-chain gate stops blocking. After flipping the rows,
  /// maybeChainCompression checks whether THIS job is a
  /// transferAndCompress parent with no chained child yet AND no
  /// remaining warnings; if so, the chained compression job is
  /// created and the queue resumes.
  Future<void> _acceptUnverifiedFiles(
      BuildContext context, List<int> ids) async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Accept unverified files?'),
        content: Text(
          '${ids.length} file(s) on disk could not be hashed (SHA-256 '
          'subsystem failed). Accepting treats them as size-only '
          'verified — the bytes are kept; future verification will '
          'not re-run on this batch.\n\n'
          'Only proceed if you have already confirmed the bytes are '
          'the version you want to keep.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Accept unverified')),
        ],
      ),
    );
    if (confirmed != true) return;
    for (final id in ids) {
      await jobFileDao.acceptUnverified(id);
    }
    final chained = await jobQueueService.maybeChainCompression(job.id);
    messenger.showSnackBar(
      SnackBar(
        content: Text(chained
            ? '${ids.length} unverified accepted — compression chain resumed'
            : '${ids.length} unverified accepted'),
      ),
    );
  }

  /// 017B (Codex round-12 P2): operator accepts the mismatch from
  /// history. Same typed-confirmation gate as the active-card banner's
  /// Skip; verifyStatus flips from `mismatch` to `verified` so the
  /// attention chip clears, but the audit trail (sourceHash,
  /// destinationHash, errorMessage) is preserved.
  Future<void> _acceptMismatchedFiles(
      BuildContext context, List<int> ids) async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Accept SHA-256 mismatch?'),
        content: Text(
          '${ids.length} file(s) on disk differ from source — '
          'verification confirmed corruption. Accepting retains the '
          'corrupted bytes and clears the warning. The audit trail '
          'records this as an operator override.\n\n'
          'Only proceed if you have already confirmed the bytes on '
          'disk are the version you want to keep.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Accept mismatch')),
        ],
      ),
    );
    if (confirmed != true) return;
    for (final id in ids) {
      await jobFileDao.acceptMismatch(id);
    }
    // 017B (Codex round-14 P2 #2): if this is a transferAndCompress
    // parent whose auto-chain was suppressed, the operator's Accept
    // may have cleared the last blocker — try to resume the chain.
    final chained = await jobQueueService.maybeChainCompression(job.id);
    messenger.showSnackBar(
      SnackBar(
        content: Text(chained
            ? '${ids.length} mismatch(es) accepted — compression chain resumed'
            : '${ids.length} mismatch(es) accepted by operator '
                '— audit trail preserved'),
      ),
    );
  }

  Future<void> _retryMismatchedFiles(
      BuildContext context, List<int> ids) async {
    final messenger = ScaffoldMessenger.of(context);
    for (final id in ids) {
      await jobQueueService.retryFile(id, forceDestDelete: true);
    }
    await jobQueueService.startProcessing();
    messenger.showSnackBar(
      SnackBar(
        content:
            Text('Retrying ${ids.length} file(s) with forced dest delete'),
      ),
    );
  }

  static IconData _typeGlyph(JobType type) {
    switch (type) {
      case JobType.transfer:
        return Icons.file_copy_outlined;
      case JobType.compression:
        return Icons.compress;
      case JobType.transferAndCompress:
        return Icons.sync;
    }
  }
}
