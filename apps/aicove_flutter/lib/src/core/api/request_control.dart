import 'dart:async';
import 'dart:io';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart';
import 'package:http/http.dart' as http;

/// Request-local control shared by every provider transport, including
/// compaction requests. Zones preserve existing client/adapter signatures.
class RequestControl {
  static const _key = #aicoveRequestCancellation;
  static KernelCancellation? get cancellation =>
      Zone.current[_key] as KernelCancellation?;

  static Future<T> run<T>(
    KernelCancellation signal,
    Future<T> Function() body,
  ) {
    signal.throwIfCancelled();
    return runZoned(() => signal.bind(body()), zoneValues: {_key: signal});
  }

  static http.Request request(String method, Uri uri) {
    final signal = cancellation;
    signal?.throwIfCancelled();
    return http.AbortableRequest(
      method,
      uri,
      abortTrigger: signal?.whenCancelled,
    );
  }
}

class ModelHttpException implements Exception {
  const ModelHttpException(this.status, this.body, {this.retryAfter});
  final int status;
  final String body;
  final Duration? retryAfter;
  @override
  String toString() => 'HTTP $status: $body';

  static Duration? parseRetryAfter(String? value, {DateTime? now}) {
    if (value == null) return null;
    final seconds = int.tryParse(value);
    if (seconds != null) return Duration(seconds: seconds < 0 ? 0 : seconds);
    try {
      final delay = HttpDate.parse(value).difference(now ?? DateTime.now());
      return delay.isNegative ? Duration.zero : delay;
    } on FormatException {
      return null;
    }
  }
}

bool isTransientModelError(Object error) =>
    error is ModelHttpException &&
        (error.status == 429 || error.status >= 500 && error.status <= 599) ||
    error is TimeoutException ||
    error is SocketException ||
    error is http.ClientException && error is! http.RequestAbortedException;

/// Retries only the supplied model round; executed tools are outside this
/// closure. The delay and the in-flight request both remain cancellable.
Future<T> retryModelRound<T>({
  required Future<T> Function() send,
  required KernelCancellation cancellation,
  void Function(int attempt, Duration delay)? onRetry,
  Future<void> Function(Duration)? wait,
  int maxRetries = 3,
  Duration? attemptTimeout,
}) async {
  for (var attempt = 0; ; attempt++) {
    cancellation.throwIfCancelled();
    try {
      final attemptSignal = KernelCancellation();
      unawaited(cancellation.whenCancelled.then((_) => attemptSignal.cancel()));
      try {
        final pending = RequestControl.run(attemptSignal, send);
        return await (attemptTimeout == null
            ? pending
            : pending.timeout(attemptTimeout));
      } finally {
        // Also abort an attempt that timed out or failed after receiving only
        // partial output, before another request can start.
        attemptSignal.cancel();
      }
    } catch (error) {
      cancellation.throwIfCancelled();
      if (attempt >= maxRetries || !isTransientModelError(error)) rethrow;
      final exponential = Duration(milliseconds: 500 * (1 << attempt));
      final retryAfter = error is ModelHttpException ? error.retryAfter : null;
      final delay = retryAfter != null && retryAfter > exponential
          ? retryAfter
          : exponential;
      onRetry?.call(attempt + 1, delay);
      await cancellation.bind((wait ?? Future<void>.delayed)(delay));
    }
  }
}
