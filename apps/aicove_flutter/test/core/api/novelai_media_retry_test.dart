import 'dart:async';
import 'dart:convert';

import 'package:aicove_flutter/src/core/api/agent_api.dart';
import 'package:aicove_flutter/src/core/api_logger.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'media_retry_test_client.dart';

void main() {
  Future<ImageGenerationResult> generate(
    AgentApiClient api, [
    String prompt = 'test',
  ]) => api.generateImage(
    provider: 'novelai',
    model: 'nai-diffusion-3',
    prompt: prompt,
    providerApiBase: 'https://local.test',
    providerApiKey: 'test',
  );
  setUp(ApiLogger.clear);

  test(
    'NovelAI 429 keeps the next request queued through retry backoff',
    () async {
      final calls = <String>[];
      final firstAttempt = Completer<void>();
      final retryEntered = Completer<void>();
      final releaseRetry = Completer<void>();
      final api = AgentApiClient(
        client: NoRedirectMockClient((request) async {
          final prompt = (jsonDecode(request.body) as Map)['input'] as String;
          calls.add(prompt);
          if (prompt == 'first' && calls.length == 1) {
            firstAttempt.complete();
            return http.Response('busy', 429);
          }
          if (prompt == 'first') {
            retryEntered.complete();
            await releaseRetry.future;
          }
          return http.Response('{"image":"AQ=="}', 200);
        }),
        timeout: const Duration(seconds: 3),
      );
      final first = generate(api, 'first');
      await firstAttempt.future;
      final second = generate(api, 'second');
      try {
        await Future<void>.delayed(Duration.zero);
        expect(calls, ['first']);
        await retryEntered.future;
        expect(calls, ['first', 'first']);
      } finally {
        releaseRetry.complete();
        await Future.wait([first, second]);
      }
      expect(calls, ['first', 'first', 'second']);
      expect((await generate(api, 'after')).images.single.single, 1);
    },
  );

  test('NovelAI timeout sends once and releases the slot', () async {
    var calls = 0;
    final entered = Completer<void>();
    final release = Completer<void>();
    final api = AgentApiClient(
      client: NoRedirectMockClient((_) async {
        if (++calls == 1) throw TimeoutException('original');
        if (calls == 2) {
          entered.complete();
          await release.future;
        }
        return http.Response('{"image":"AQ=="}', 200);
      }),
    );
    await expectLater(generate(api), throwsA(isA<TimeoutException>()));
    expect(calls, 1);
    final second = generate(api, 'second');
    await entered.future;
    final third = generate(api, 'third');
    try {
      await Future<void>.delayed(Duration.zero);
      expect(calls, 2);
    } finally {
      release.complete();
      await Future.wait([second, third]);
    }
    expect(calls, 3);
  });

  test(
    'NovelAI exhausted 429 preserves final message and a single API log',
    () async {
      var calls = 0;
      final api = AgentApiClient(
        client: NoRedirectMockClient(
          (_) async => http.Response('busy-${++calls}', 429),
        ),
      );
      await expectLater(
        generate(api),
        throwsA(
          predicate((e) => e.toString() == 'Exception: HTTP 429: busy-3'),
        ),
      );
      expect(calls, 3);
      final entries = ApiLogger.entries.value;
      expect(entries.length, 1);
      expect(entries.single.status, 429);
      expect(entries.single.responseBody, 'busy-3');
      expect(entries.single.eventType, 'image_generation');
      expect(entries.single.ok, isFalse);
      final raw = jsonDecode(entries.single.rawResponseBody!) as Map;
      expect(raw['phase'], 'read_body');
      expect(raw['statusCode'], 429);
    },
  );

  test('NovelAI success with invalid ZIP is never resubmitted', () async {
    var calls = 0;
    final api = AgentApiClient(
      client: NoRedirectMockClient((_) async {
        calls++;
        return http.Response.bytes(
          [80, 75, 3, 4],
          200,
          headers: {'content-type': 'application/zip'},
        );
      }),
    );
    await expectLater(generate(api), throwsA(anything));
    expect(calls, 1);
    expect(ApiLogger.entries.value.length, 1);
  });
}
