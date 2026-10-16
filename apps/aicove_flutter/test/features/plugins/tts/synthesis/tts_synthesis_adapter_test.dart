import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aicove_flutter/src/features/plugins/tts/synthesis/configurable_tts_synthesis_adapter.dart';
import 'package:aicove_flutter/src/features/plugins/tts/synthesis/minimax_tts_synthesis_adapter.dart';
import 'package:aicove_flutter/src/features/plugins/tts/synthesis/openai_compatible_tts_synthesis_adapter.dart';
import 'package:aicove_flutter/src/features/plugins/tts/synthesis/tts_synthesis_adapter.dart';
import 'package:aicove_flutter/src/features/plugins/tts/tts_config.dart';
import 'package:aicove_flutter/src/features/plugins/tts/tts_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('OpenAiCompatibleTtsSynthesisAdapter', () {
    const adapter = OpenAiCompatibleTtsSynthesisAdapter();

    test('补全 /audio/speech 路径并保留 openai body 语义', () {
      final context = TtsSynthesisContext(
        config: TtsConfig(model: 'tts-1-hd', voice: 'nova', speed: 1.2),
        text: 'hello',
        rawUrl: 'https://api.openai.com/v1',
        apiKey: 'test-key',
      );

      expect(adapter.supports(context), isTrue);
      expect(
        adapter.buildSpeechUri(context).toString(),
        'https://api.openai.com/v1/audio/speech',
      );
      expect(adapter.resolveTimeout(context), const Duration(seconds: 30));
      expect(adapter.buildHeaders(context), {
        'Content-Type': 'application/json',
        'X-Failover-Enabled': 'true',
        'Authorization': 'Bearer test-key',
      });
      expect(adapter.buildRequestBody(context), {
        'model': 'tts-1-hd',
        'input': 'hello',
        'voice': 'nova',
        'speed': 1.2,
      });
    });
  });

  group('MinimaxTtsSynthesisAdapter', () {
    const adapter = MinimaxTtsSynthesisAdapter();

    test('支持 minimax requestFormat 别名', () {
      final minimaxContext = TtsSynthesisContext(
        config: TtsConfig(model: 'speech-2.8-hd', voice: 'male-qn-qingse'),
        text: 'hello',
        rawUrl: 'https://api.minimax.com/v1',
        requestFormat: 'minimax',
      );
      final minimaxTtsContext = TtsSynthesisContext(
        config: TtsConfig(model: 'speech-2.8-hd', voice: 'male-qn-qingse'),
        text: 'hello',
        rawUrl: 'https://api.minimax.com/v1',
        requestFormat: 'minimax_tts',
      );

      expect(adapter.supports(minimaxContext), isTrue);
      expect(adapter.supports(minimaxTtsContext), isTrue);
    });

    test('providerId=minimax 时即使 requestFormat=openai_tts 也命中', () {
      final context = TtsSynthesisContext(
        config: TtsConfig(model: 'speech-2.8-hd', voice: 'male-qn-qingse'),
        text: 'hello',
        rawUrl: 'https://api.minimaxi.com/v1',
        providerId: 'minimax',
        requestFormat: 'openai_tts',
      );

      expect(adapter.supports(context), isTrue);
    });

    test('官方协议路径会补全到 /v1/t2a_v2 并兼容国际站', () {
      final context = TtsSynthesisContext(
        config: TtsConfig(
          model: 'speech-2.8-hd',
          voice: 'male-qn-qingse',
          speed: 1.05,
        ),
        text: 'mini max',
        rawUrl: 'https://api.minimax.io',
        providerId: 'minimax',
        requestFormat: 'openai_tts',
        apiKey: 'minimax-key',
      );
      final backupContext = TtsSynthesisContext(
        config: TtsConfig(
          model: 'speech-2.8-hd',
          voice: 'male-qn-qingse',
        ),
        text: 'mini max',
        rawUrl: 'https://api-bj.minimaxi.com/v1/t2a_v2?foo=bar',
        providerId: 'minimax',
        requestFormat: 'openai_tts',
      );

      expect(
        adapter.buildSpeechUri(context).toString(),
        'https://api.minimax.io/v1/t2a_v2',
      );
      expect(
        adapter.buildSpeechUri(backupContext).toString(),
        'https://api-bj.minimaxi.com/v1/t2a_v2',
      );
      expect(adapter.resolveTimeout(context), const Duration(seconds: 60));
      expect(adapter.buildHeaders(context), {
        'Content-Type': 'application/json',
        'X-Failover-Enabled': 'true',
        'Authorization': 'Bearer minimax-key',
      });
      expect(adapter.buildRequestBody(context), {
        'model': 'speech-2.8-hd',
        'text': 'mini max',
        'stream': false,
        'voice_setting': {
          'voice_id': 'male-qn-qingse',
          'speed': 1.05,
          'vol': 1,
          'pitch': 0,
        },
        'audio_setting': {
          'sample_rate': 32000,
          'bitrate': 128000,
          'format': 'mp3',
          'channel': 1,
        },
        'subtitle_enable': false,
        'output_format': 'hex',
      });
    });

    test('手填 binding 会覆盖 config.voice', () {
      final context = TtsSynthesisContext(
        config: TtsConfig(
          selectedProviderId: 'provider_minimax',
          model: 'speech-2.8-hd',
          voice: 'fallback-voice',
          voicePresets: [
            VoicePreset(
              id: 'preset-binding',
              name: 'MiniMax 绑定',
              bindings: const [
                VoiceChannelBinding(
                  providerId: 'provider_minimax',
                  providerName: 'MiniMax 渠道',
                  adapterId: 'minimax',
                  modelId: 'speech-2.8-hd',
                  remoteVoiceId: 'custom-voice-id',
                  sourceKind: VoiceBindingSourceKind.manual,
                ),
              ],
            ),
          ],
          selectedVoicePresetId: 'preset-binding',
        ),
        text: 'hello',
        rawUrl: 'https://api.minimaxi.com/v1',
        providerId: 'minimax',
        requestFormat: 'openai_tts',
      );

      final body = adapter.buildRequestBody(context);
      expect(
        (body['voice_setting'] as Map<String, dynamic>)['voice_id'],
        'custom-voice-id',
      );
    });
  });

  group('TtsService synthesis routing', () {
    test('MiniMax URL 会走官方 t2a_v2 并解析 hex 音频', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requestReceived = Completer<void>();
      late String requestPath;
      late String authorization;
      late Map<String, dynamic> requestBody;

      unawaited(server.listen((request) async {
        requestPath = request.uri.path;
        authorization = request.headers.value('authorization') ?? '';
        final bodyText = await utf8.decoder.bind(request).join();
        requestBody = jsonDecode(bodyText) as Map<String, dynamic>;
        request.response.statusCode = 200;
        request.response.headers.contentType =
            ContentType('application', 'json', charset: 'utf-8');
        request.response.write(jsonEncode({
          'data': {
            'audio': '49443304',
            'status': 2,
          },
          'extra_info': {
            'audio_format': 'mp3',
          },
          'base_resp': {
            'status_code': 0,
            'status_msg': 'success',
          },
        }));
        await request.response.close();
        if (!requestReceived.isCompleted) {
          requestReceived.complete();
        }
      }).asFuture<void>());

      final service = TtsService(
        config: TtsConfig(
          model: 'speech-2.8-hd',
          voice: 'Wise_Woman',
          speed: 1.1,
        ),
        apiKey: 'test-key',
        requestUrl:
            'http://${server.address.address}:${server.port}/minimax/v1',
        requestFormat: 'minimax',
      );

      try {
        final result = await service.convert('mini max');
        await requestReceived.future;

        expect(requestPath, '/minimax/v1/t2a_v2');
        expect(authorization, 'Bearer test-key');
        expect(requestBody, {
          'model': 'speech-2.8-hd',
          'text': 'mini max',
          'stream': false,
          'voice_setting': {
            'voice_id': 'Wise_Woman',
            'speed': 1.1,
            'vol': 1,
            'pitch': 0,
          },
          'audio_setting': {
            'sample_rate': 32000,
            'bitrate': 128000,
            'format': 'mp3',
            'channel': 1,
          },
          'subtitle_enable': false,
          'output_format': 'hex',
        });
        expect(result.success, isTrue);
        expect(result.audioUrl, startsWith('data:audio/mpeg;base64,'));
      } finally {
        await server.close(force: true);
      }
    });

    test('Fish Audio URL 会走通用适配器 /v1/tts 并附带 model 请求头', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requestReceived = Completer<void>();
      late String requestPath;
      late String authorization;
      late String modelHeader;
      late Map<String, dynamic> requestBody;

      unawaited(server.listen((request) async {
        requestPath = request.uri.path;
        authorization = request.headers.value('authorization') ?? '';
        modelHeader = request.headers.value('model') ?? '';
        final bodyText = await utf8.decoder.bind(request).join();
        requestBody = jsonDecode(bodyText) as Map<String, dynamic>;
        request.response.statusCode = 200;
        request.response.headers.contentType = ContentType('audio', 'mpeg');
        request.response.add([0xFF, 0xFB, 0x90, 0x64]); // dummy mp3 bytes
        await request.response.close();
        if (!requestReceived.isCompleted) {
          requestReceived.complete();
        }
      }).asFuture<void>());

      final service = TtsService(
        config: TtsConfig(
          selectedProviderId: 'fish_audio',
          model: 's2.1-pro-free',
          voice: '6ce7ea8ada884bf3889fa7c7fb206691',
        ),
        apiKey: 'sk-fish-test',
        requestUrl:
            'http://${server.address.address}:${server.port}/v1',
        requestFormat: 'fish_audio',
      );

      try {
        final result = await service.convert('fish audio test');
        await requestReceived.future;

        expect(requestPath, '/v1/tts');
        expect(authorization, 'Bearer sk-fish-test');
        expect(modelHeader, 's2.1-pro-free');
        expect(requestBody, {
          'text': 'fish audio test',
          'reference_id': '6ce7ea8ada884bf3889fa7c7fb206691',
          'format': 'mp3',
        });
        expect(result.success, isTrue);
        expect(result.audioUrl, startsWith('data:audio/mpeg;base64,'));
      } finally {
        await server.close(force: true);
      }
    });

    test('自定义 REST 按渠道模板发请求，占位符全部替换', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requestReceived = Completer<void>();
      late String requestPath;
      late String apiKeyHeader;
      late Map<String, dynamic> requestBody;

      unawaited(server.listen((request) async {
        requestPath = request.uri.path;
        apiKeyHeader = request.headers.value('x-api-key') ?? '';
        requestBody =
            jsonDecode(await utf8.decoder.bind(request).join())
                as Map<String, dynamic>;
        request.response.headers.contentType = ContentType('audio', 'mpeg');
        request.response.add([0xFF, 0xFB, 0x90, 0x64]);
        await request.response.close();
        if (!requestReceived.isCompleted) requestReceived.complete();
      }).asFuture<void>());

      final service = TtsService(
        config: TtsConfig(model: 'my-voice-model', voice: 'v-001', speed: 1.2),
        apiKey: 'custom-key',
        requestUrl: 'http://${server.address.address}:${server.port}/api',
        requestFormat: 'custom_rest',
        customConfig: const <String, dynamic>{
          'tts_template': <String, dynamic>{
            'path': '/v2/speak',
            'headers': <String, dynamic>{'X-Api-Key': '{apiKey}'},
            'body': <String, dynamic>{
              'content': '{text}',
              'speaker': '{voice}',
              'engine': '{model}',
              'rate': '{speed}',
            },
          },
        },
      );

      try {
        final result = await service.convert('custom rest');
        await requestReceived.future;

        expect(requestPath, '/api/v2/speak');
        expect(apiKeyHeader, 'custom-key');
        expect(requestBody, {
          'content': 'custom rest',
          'speaker': 'v-001',
          'engine': 'my-voice-model',
          'rate': 1.2,
        });
        expect(result.success, isTrue);
      } finally {
        await server.close(force: true);
      }
    });
  });

  group('ConfigurableTtsSynthesisAdapter', () {
    const adapter = ConfigurableTtsSynthesisAdapter();

    test('Fish Audio 内置模板生成正确的 Header、路径与 Body 字段', () {
      final context = TtsSynthesisContext(
        config: TtsConfig(
          model: 's2.1-pro-free',
          voice: '6ce7ea8ada884bf3889fa7c7fb206691',
        ),
        text: '你好世界',
        rawUrl: 'https://api.fish.audio/v1',
        requestFormat: 'fish_audio',
        apiKey: 'sk-fish-demo',
      );

      expect(adapter.supports(context), isTrue);
      expect(
        adapter.buildSpeechUri(context).toString(),
        'https://api.fish.audio/v1/tts',
      );
      final headers = adapter.buildHeaders(context);
      expect(headers['Authorization'], 'Bearer sk-fish-demo');
      expect(headers['model'], 's2.1-pro-free');
      expect(adapter.buildRequestBody(context), {
        'text': '你好世界',
        'reference_id': '6ce7ea8ada884bf3889fa7c7fb206691',
        'format': 'mp3',
      });
    });

    test('自定义 tts_template 声明式配置正确生效', () {
      final context = TtsSynthesisContext(
        config: TtsConfig(
          model: 'custom-voice-model',
          voice: 'voice-123',
          speed: 1.25,
        ),
        text: '自定义文本',
        rawUrl: 'https://custom-tts.ai/api',
        requestFormat: 'custom_rest',
        apiKey: 'custom-token',
        customConfig: {
          'tts_template': {
            'path': '/v2/speech/generate',
            'headers': {
              'X-Custom-Auth': '{apiKey}',
              'X-Voice-Model': '{model}',
            },
            'body': {
              'prompt': '{text}',
              'speaker_id': '{voice}',
              'rate': '{speed}',
            },
          },
        },
      );

      expect(adapter.supports(context), isTrue);
      expect(
        adapter.buildSpeechUri(context).toString(),
        'https://custom-tts.ai/api/v2/speech/generate',
      );
      final headers = adapter.buildHeaders(context);
      expect(headers['X-Custom-Auth'], 'custom-token');
      expect(headers['X-Voice-Model'], 'custom-voice-model');
      expect(adapter.buildRequestBody(context), {
        'prompt': '自定义文本',
        'speaker_id': 'voice-123',
        'rate': 1.25,
      });
    });
  });
}
