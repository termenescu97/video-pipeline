import 'dart:async';

/// Single source of truth for queue-lifecycle events that the UI shell reacts
/// to in multiple places (StatusBar 5-minute green-dot timer, HomeScreen
/// completed-card celebration, future tray badge transitions, etc.).
///
/// Both StatusBar and HomeScreen subscribe to the same notifier so the
/// celebration card and the green dot clear on identical events.
class QueueStateNotifier {
  final _controller = StreamController<QueueStateEvent>.broadcast();
  final _operatorMessageController =
      StreamController<OperatorMessage>.broadcast();

  Stream<QueueStateEvent> get events => _controller.stream;

  /// 019 (Codex round-27b P2 #1): operator-visible one-shot messages
  /// (e.g. legacy-job-banner on first encounter of a v8 sentinel row).
  /// Rendered as SnackBar in the shell; carries severity so the shell
  /// can pick the right colour.
  Stream<OperatorMessage> get operatorMessages =>
      _operatorMessageController.stream;

  void notifyOperatorMessage(OperatorMessage message) {
    _operatorMessageController.add(message);
  }

  /// Emitted when the queue transitions from idle to running (a job started).
  void notifyQueueRunningStarted() {
    _controller.add(QueueStateEvent.runningStarted);
  }

  /// Emitted when the queue transitions from running to idle with everything
  /// completed successfully. Drives the green dot and the completion
  /// celebration card.
  void notifyQueueAllDone() {
    _controller.add(QueueStateEvent.allDone);
  }

  /// Emitted when the operator takes an action that should clear the
  /// "recent done" celebration (creates a job, starts the queue, dismisses
  /// the celebration explicitly).
  void notifyDismissedByUser() {
    _controller.add(QueueStateEvent.dismissedByUser);
  }

  void dispose() {
    _controller.close();
    _operatorMessageController.close();
  }
}

enum QueueStateEvent {
  runningStarted,
  allDone,
  dismissedByUser,
}

enum OperatorMessageSeverity {
  info,
  warning,
}

class OperatorMessage {
  const OperatorMessage({
    required this.text,
    required this.severity,
  });

  final String text;
  final OperatorMessageSeverity severity;
}
