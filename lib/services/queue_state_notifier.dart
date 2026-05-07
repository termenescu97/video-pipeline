import 'dart:async';

/// Single source of truth for queue-lifecycle events that the UI shell reacts
/// to in multiple places (StatusBar 5-minute green-dot timer, HomeScreen
/// completed-card celebration, future tray badge transitions, etc.).
///
/// Both StatusBar and HomeScreen subscribe to the same notifier so the
/// celebration card and the green dot clear on identical events.
class QueueStateNotifier {
  final _controller = StreamController<QueueStateEvent>.broadcast();

  Stream<QueueStateEvent> get events => _controller.stream;

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
  }
}

enum QueueStateEvent {
  runningStarted,
  allDone,
  dismissedByUser,
}
