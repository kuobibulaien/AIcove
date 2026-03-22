import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aicove_flutter/src/features/plugins/tts/synthesis/minimax_tts_synthesis_adapter.dart';
import 'package:aicove_flutter/src/features/plugins/tts/synthesis/openai_compatible_tts_synthesis_adapter.dart';
import 'package:aicove_flutter/src/features/plugins/tts/synthesis/siliconflow_tts_synthesis_adapter.dart';
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

  group('SiliconFlowTtsSynthesisAdapter', () {
    const adapter = SiliconFlowTtsSynthesisAdapter();

    test('已带 /audio/speech 时保持路径并移除 query', () {
      final context = TtsSynthesisContext(
        config: TtsConfig(model: 'IndexTeam/IndexTTS-2'),
        text: 'hello',
        rawUrl: 'https://api.siliconflow.cn/v1/audio/speech?foo=bar',
        requestFormat: 'siliconflow_indextts',
        apiKey: 'sk-demo',
      );

      expect(adapter.supports(context), isTrue);
      expect(
        adapter.buildSpeechUri(context).toString(),
        'https://api.siliconflow.cn/v1/audio/speech',
      );
      expect(adapter.resolveTimeout(context), const Duration(seconds: 30));
      expect(adapter.buildHeaders(context), {
        'Content-Type': 'application/json',
        'X-Failover-Enabled': 'true',
        'Authorization': 'Bearer sk-demo',
      });
    });

    test('系统音色模式会拼接模型和音色 ID', () {
      final context = TtsSynthesisContext(
        config: TtsConfig(
          model: 'IndexTeam/IndexTTS-2',
          voice: 'alex',
          speed: 1.1,
        ),
        text: 'system voice',
        rawUrl: 'https://api.siliconflow.cn/v1',
        requestFormat: 'siliconflow_indextts',
      );

      expect(adapter.buildRequestBody(context), {
        'model': 'IndexTeam/IndexTTS-2',
        'input': 'system voice',
        'response_format': 'mp3',
        'speed': 1.1,
        'voice': 'IndexTeam/IndexTTS-2:alex',
      });
    });

    test('动态音色模式会构造 references', () {
      final context = TtsSynthesisContext(
        config: TtsConfig(
          model: 'IndexTeam/IndexTTS-2',
          promptAudioUrl: 'https://example.com/ref.mp3',
          promptText: '参考文本',
          voicePresets: const [],
          selectedVoicePresetId: '',
        ),
        text: 'dynamic voice',
        rawUrl: 'https://api.siliconflow.cn/v1',
        requestFormat: 'siliconflow_indextts',
      );

      expect(adapter.buildRequestBody(context), {
        'model': 'IndexTeam/IndexTTS-2',
        'input': 'dynamic voice',
        'response_format': 'mp3',
        'voice': '',
        'references': [
          {
            'audio': 'https://example.com/ref.mp3',
            'text': '参考文本',
          }
        ],
      });
    });

    test('预置 URI 优先于系统音色和动态音色', () {
      final context = TtsSynthesisContext(
        config: TtsConfig(
          model: 'IndexTeam/IndexTTS-2',
          voice: 'alex',
          promptAudioUrl: 'https://example.com/ref.mp3',
          promptText: '参考文本',
          voicePresets: [
            VoicePreset(
              id: 'preset-1',
              name: '上传音色',
              siliconFlowVoiceUri: 'speech:tenant:voice-id',
            ),
          ],
          selectedVoicePresetId: 'preset-1',
        ),
        text: 'preset voice',
        rawUrl: 'https://api.siliconflow.cn/v1',
        requestFormat: 'siliconflow_indextts',
      );

      expect(adapter.buildRequestBody(context), {
        'model': 'IndexTeam/IndexTTS-2',
        'input': 'preset voice',
        'response_format': 'mp3',
        'voice': 'speech:tenant:voice-id',
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
        requestFormat: 'openai_tts',
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
  });
}
