import 'dart:async';

class KernelCancelledException implements Exception {
  const KernelCancelledException();

  @override
  String toString() => 'KernelCancelledException';
}

/// Cooperative cancellation for one run. Model ports listen to [whenCancelled]
/// to abort in-flight requests; the loop checks at stage boundaries.
class KernelCancellation {
  final Completer<void> _completer = Completer<void>();

  bool get isCancelled => _completer.isCompleted;

  Future<void> get whenCancelled => _completer.future;

  void cancel() {
    if (!_completer.isCompleted) _completer.complete();
  }

  void throwIfCancelled() {
    if (isCancelled) throw const KernelCancelledException();
  }

  /// Stops awaiting non-cooperative ports immediately. Late completions
  /// remain observed, but can never resume the cancelled run.
  Future<T> bind<T>(Future<T> operation) {
    throwIfCancelled();
    return Future.any([
      operation,
      whenCancelled.then<T>((_) => throw const KernelCancelledException()),
    ]);
  }
}
