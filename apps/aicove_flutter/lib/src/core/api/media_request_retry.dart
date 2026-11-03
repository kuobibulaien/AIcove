import 'dart:async';
import 'dart:io';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart';
import 'package:http/http.dart' as http;

import '../app_logger.dart';
import 'request_control.dart';

enum MediaRetryPolicy {
  readOnly,
  submission,
  tts;

  int get maxRetries => switch (this) {
    readOnly => 3,
    submission => 2,
    tts => 1,
  };

  bool _retriesStatus(int status) => switch (this) {
    submission => status == 429,
    readOnly => const {408, 429, 500, 502, 503, 504}.contains(status),
    tts => const {429, 500, 502, 503, 504}.contains(status),
  };

  bool _retriesError(Object error) {
    if (this == submission || error is http.RequestAbortedException) {
      // IOClient cannot distinguish a pre-send failure from a lost response
      // (including failure after a redirect). Never replay a billable POST.
      return false;
    }
    if (this == readOnly &&
        (error is TimeoutException || error is HandshakeException)) {
      return true;
    }
    // Daily TTS deliberately accepts at most one duplicate synthesis/charge.
    return error is SocketException ||
        error is HttpException ||
        error is http.ClientException;
  }
}

/// Retries transport only: decoding, user-facing errors and final API logs
/// belong to the caller. [send] must construct a fresh request on every call.
/// All attempts, complete bodies and backoff share the caller's budget.
Future<http.Response> sendMediaRequestWithRetry({
  required Future<http.StreamedResponse> Function() send,
  required MediaRetryPolicy policy,
  required Duration Function() remaining,
  String? phase,
  Future<void> Function(Duration)? wait,
}) async {
  final cancellation = RequestControl.cancellation;
  for (var attempt = 0; ; attempt++) {
    cancellation?.throwIfCancelled();
    final budget = remaining();
    if (budget <= Duration.zero) {
      throw TimeoutException('Media request timed out');
    }

    http.Response? response;
    var isOriginalResponse = false;
    Object? failure;
    StackTrace? failureStack;
    final attemptSignal = KernelCancellation();
    if (cancellation != null) {
      unawaited(cancellation.whenCancelled.then((_) => attemptSignal.cancel()));
    }
    try {
      response = await RequestControl.run(attemptSignal, () async {
        final streamed = await send();
        attemptSignal.throwIfCancelled();
        // Response.fromStream drops final-URL metadata. Inspect the transport
        // response first: a redirected 429 does not reject the billable POST.
        // Unknown final URLs must never authorize replaying a submission.
        if (streamed case http.BaseResponseWithUrl(:final url)) {
          isOriginalResponse = url == streamed.request?.url;
        }
        return http.Response.fromStream(streamed);
      }).timeout(budget);
      cancellation?.throwIfCancelled();
      if (attempt >= policy.maxRetries ||
          (policy == MediaRetryPolicy.submission && !isOriginalResponse) ||
          !policy._retriesStatus(response.statusCode)) {
        return response;
      }
    } catch (error, stack) {
      cancellation?.throwIfCancelled();
      if (attempt >= policy.maxRetries || !policy._retriesError(error)) rethrow;
      failure = error;
      failureStack = stack;
    } finally {
      // Abort an expired attempt/body before a later attempt can start.
      attemptSignal.cancel();
    }

    final exponential = Duration(milliseconds: 500 * (1 << attempt));
    final retryAfter = ModelHttpException.parseRetryAfter(
      response?.headers['retry-after'],
    );
    final delay = retryAfter != null && retryAfter > exponential
        ? retryAfter
        : exponential;
    if (delay >= remaining()) {
      cancellation?.throwIfCancelled();
      if (failure != null) Error.throwWithStackTrace(failure, failureStack!);
      return response!;
    }
    AppLogger.warning(
      'MediaRequestRetry',
      'Retrying media request',
      metadata: {
        if (phase != null) 'phase': phase,
        'attempt': attempt + 1,
        'delayMs': delay.inMilliseconds,
        if (response != null) 'status': response.statusCode,
        if (failure != null) 'errorType': failure.runtimeType.toString(),
      },
    );
    final pending = (wait ?? Future<void>.delayed)(delay);
    await (cancellation == null ? pending : cancellation.bind(pending));
    cancellation?.throwIfCancelled();
    // A delayed timer may resume after the deadline. Preserve the last result
    // instead of replacing a provider error with a newly invented timeout.
    if (remaining() <= Duration.zero) {
      if (failure != null) Error.throwWithStackTrace(failure, failureStack!);
      return response!;
    }
  }
}
