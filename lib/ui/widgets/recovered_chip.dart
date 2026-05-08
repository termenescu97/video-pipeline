import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/insets.dart';
import '../theme/text_styles.dart';

/// "Recovered after restart" chip rendered next to the title on
/// [JobCardQueued] and [JobCardNextUp] when the job was rescued from
/// in-progress by `JobDao.recoverStaleJobs` (T109, FR-051).
///
/// Reads from `jobDao.recoveredJobIds` (in-memory; resets on app
/// restart). The chip dismisses for that specific job when the
/// operator acts on it (resume / cancel / delete / retry handlers
/// call `JobDao.markRecoveryAcknowledged`).
class RecoveredChip extends StatelessWidget {
  const RecoveredChip({super.key});

  @override
  Widget build(BuildContext context) {
    final statusColors = Theme.of(context).extension<StatusColors>()!;
    return Tooltip(
      message: 'This job was rescued after a previous crash.\n'
          'Press Start when ready to resume.',
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: Insets.s, vertical: 1),
        decoration: BoxDecoration(
          color: statusColors.warning.withValues(alpha: 0.15),
          border: Border.all(color: statusColors.warning),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.history, size: 12, color: statusColors.warning),
            const SizedBox(width: Insets.xxs),
            Text(
              'Recovered',
              style: AppTextStyles.caption
                  .copyWith(color: statusColors.warning),
            ),
          ],
        ),
      ),
    );
  }
}
