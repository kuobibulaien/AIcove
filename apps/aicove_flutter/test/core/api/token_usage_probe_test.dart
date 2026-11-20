import 'dart:convert';

import 'package:aicove_flutter/src/core/api/providers/token_usage.dart';
import 'package:aicove_flutter/src/features/observability/model_request_ledger.dart';
import 'package:aicove_flutter/src/features/observability/token_usage_ledger.dart';
import 'package:aicove_flutter/src/features/settings/data/remote/provider_probe_remote_data_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('probe captures upstream usage without opening a database', () async {
    final source = ProviderProbeRemoteDataSource(
      httpClient: MockClient((request) async {
        expect(jsonDecode(request.body)['messages'], [
          {'role': 'user', 'content': 'hi'},
        ]);
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': 'hello'},
              },
            ],
            'usage': {'prompt_tokens': 10, 'completion_tokens': 3},
          }),
          200,
        );
      }),
    );
    const scope = ModelRunScope(purpose: 'probe');
    final capture = TokenUsageCaptureScope(
      providerId: 'openai',
      modelFullId: 'openai:gpt-4o',
      scope: scope,
    );
    final result = await scope.run(
      () => capture.run(
        () => source.testModel(
          providerId: 'openai',
          apiKey: 'test',
          apiBaseUrl: 'https://test.invalid/v1',
          modelId: 'gpt-4o',
        ),
      ),
    );
    expect(result, 'hello');
    expect(capture.usage.inputTokens, 10);
    expect(capture.usage.outputTokens, 3);
    expect(capture.usage.isEstimated, false);
  });
  test('probe missing usage estimates consumed request', () async {
    final source = ProviderProbeRemoteDataSource(
      httpClient: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': 'hello'},
              },
            ],
          }),
          200,
        ),
      ),
    );
    final capture = TokenUsageCaptureScope(purpose: 'probe');
    await capture.run(
      () => source.testModel(
        providerId: 'openai',
        apiKey: 'test',
        apiBaseUrl: 'https://test.invalid/v1',
        modelId: 'gpt-4o',
      ),
    );
    expect(capture.usage.inputTokens, greaterThan(0));
    expect(capture.usage.outputTokens, greaterThan(0));
    expect(capture.usage.isEstimated, true);
  });
  test('failed probe records no usage', () async {
    final source = ProviderProbeRemoteDataSource(
      httpClient: MockClient((_) async => http.Response('error', 400)),
    );
    final capture = TokenUsageCaptureScope(purpose: 'probe');
    await expectLater(
      capture.run(
        () => source.testModel(
          providerId: 'openai',
          apiKey: 'test',
          apiBaseUrl: 'https://test.invalid/v1',
          modelId: 'gpt-4o',
        ),
      ),
      throwsException,
    );
    expect(capture.usage.isZero, true);
  });
  test('HTTP request ID deduplicates capture even without database', () async {
    final capture = TokenUsageCaptureScope(purpose: 'chat');
    await capture.run(() async {
      for (var i = 0; i < 2; i++) {
        await TokenUsageLedger.instance.recordHttpRound(
          requestId: 'same',
          providerId: 'openai',
          model: 'gpt-4o',
          usage: const TokenUsage(inputTokens: 10, outputTokens: 2),
        );
      }
    });
    expect(capture.usage.totalTokens, 12);
  });
}
