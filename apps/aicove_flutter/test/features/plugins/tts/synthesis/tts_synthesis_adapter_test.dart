import 'package:aicove_flutter/src/features/plugins/tts/synthesis/openai_compatible_tts_synthesis_adapter.dart';
import 'package:aicove_flutter/src/features/plugins/tts/synthesis/siliconflow_tts_synthesis_adapter.dart';
import 'package:aicove_flutter/src/features/plugins/tts/synthesis/tts_synthesis_adapter.dart';
import 'package:aicove_flutter/src/features/plugins/tts/tts_config.dart';
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
}
