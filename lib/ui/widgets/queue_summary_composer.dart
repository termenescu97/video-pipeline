import '../../database/database.dart';
import '../../database/tables.dart';

/// Pure helper that composes the StatusBar / tray-tooltip queue summary text
/// for a given queue state. Used by both the StatusBar widget (T014) and the
/// tray tooltip mirror (T018) so the two never disagree.
class QueueSummaryComposer {
  /// Compose the summary line.
  ///
  /// Examples:
  ///   "RUNNING — 2 of 3, done by 18:14"
  ///   "Idle — 0 jobs queued"
  ///   "1 failed — review"
  ///   "Slack notifications disabled"
  ///   "All cards copied & verified"
  static String compose({
    required List<Job> jobs,
    required bool slackConfigured,
    required bool handbrakeInstalled,
    required bool recentlyDone,
    DateTime? completionEta,
  }) {
    final running = jobs.where((j) => j.status == JobStatus.inProgress).length;
    final queued = jobs.where((j) => j.status == JobStatus.queued).length;
    final failed = jobs.where((j) => j.status == JobStatus.failed).length;

    // Worst-condition-wins, mirroring the dot precedence (FR-003a).
    if (failed > 0) {
      return failed == 1 ? '1 failed — review' : '$failed failed — review';
    }
    if (running > 0) {
      final total = running + queued;
      final etaText = completionEta != null ? ', done by ${_formatTime(completionEta)}' : '';
      return 'RUNNING — $running of $total$etaText';
    }
    if (!slackConfigured) {
      return 'Slack notifications disabled';
    }
    if (!handbrakeInstalled) {
      return 'HandBrake missing — compression disabled';
    }
    if (recentlyDone) {
      return 'All cards copied & verified';
    }
    if (queued > 0) {
      return queued == 1 ? '1 job queued' : '$queued jobs queued';
    }
    return 'Idle — 0 jobs queued';
  }

  static String _formatTime(DateTime t) {
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }
}
