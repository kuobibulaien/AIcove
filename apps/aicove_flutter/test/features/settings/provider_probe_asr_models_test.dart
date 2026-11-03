import 'dart:convert';

import 'package:aicove_flutter/src/features/settings/data/remote/provider_probe_remote_data_source.dart';
import 'package:aicove_flutter/src/features/settings/data/support/ui_models_store_support.dart';
import 'package:aicove_flutter/src/features/voice_call/domain/asr_request_format.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('http channel with an ASR format lists only remote models', () async {
    final requested = <Uri>[];
    final source = ProviderProbeRemoteDataSource(
      httpClient: MockClient((request) async {
        requested.add(request.url);
        return http.Response(
          jsonEncode(<String, dynamic>{
            'data': <Map<String, String>>[
              {'id': 'gpt-5'},
              {'id': 'gpt-4o-transcribe'},
            ],
          }),
          200,
        );
      }),
    );

    final models = await source.previewProvider(
      providerId: 'openai__9',
      apiKey: 'k',
      apiBaseUrl: 'https://gateway.example.com/v1/openai',
      customConfig: <String, dynamic>{
        'requestFormat': 'openai',
        AsrRequestFormat.configKey: AsrRequestFormat.openai.value,
      },
    );

    expect(requested.single.path, '/v1/openai/models');
    expect(models, <String>['gpt-5', 'gpt-4o-transcribe']);
  });

  test('websocket ASR channel reports that it has no model list', () async {
    final source = ProviderProbeRemoteDataSource(
      httpClient: MockClient((_) async => fail('should not request')),
    );

    await expectLater(
      source.previewProvider(
        providerId: 'tencent_asr',
        apiKey: 'k',
        apiBaseUrl: 'wss://asr.cloud.tencent.com/asr/v2',
        customConfig: <String, dynamic>{
          AsrRequestFormat.configKey: AsrRequestFormat.tencent.value,
        },
      ),
      throwsA(isA<ProviderModelListUnsupported>()),
    );
  });

  test('a chat gateway listing transcribe models gets no ASR format', () {
    final data = normalizeUiModelsStoreData(<String, dynamic>{
      'providers': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'openai__9',
          'apiKeys': <String>['k'],
          'apiBaseUrl': 'https://gateway.example.com/v1/openai',
          'enabled': true,
          'models': <String>['gpt-5', 'gpt-4o-transcribe'],
          'visible_models': <String>['gpt-5'],
          'capabilities': <String>['chat'],
          'custom_config': <String, dynamic>{'requestFormat': 'openai'},
        },
      ],
    });
    final provider = (data['providers'] as List).single as Map;
    expect(
      (provider['custom_config'] as Map).containsKey(AsrRequestFormat.configKey),
      isFalse,
    );
  });
}
