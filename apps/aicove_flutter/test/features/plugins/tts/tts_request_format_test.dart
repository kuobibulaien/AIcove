import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/features/plugins/tts/tts_request_format.dart';

void main() {
  group('TtsRequestFormat.fromRaw', () {
    test('旧别名指向注册表格式，对话格式不算语音', () {
      expect(TtsRequestFormat.fromRaw('fishaudio'), TtsRequestFormat.fishAudio);
      expect(
        TtsRequestFormat.fromRaw('siliconflow_indextts'),
        TtsRequestFormat.openai,
      );
      expect(
        TtsRequestFormat.fromRaw('aliyun_qwen_tts'),
        TtsRequestFormat.aliyun,
      );
      expect(
        TtsRequestFormat.fromRaw('configurable_rest'),
        TtsRequestFormat.customRest,
      );
      expect(TtsRequestFormat.fromRaw('openai'), isNull);
      expect(TtsRequestFormat.fromRaw(null), isNull);
    });
  });

  group('TtsRequestFormat.normalizeStored', () {
    String? normalize(String? raw, String url, {bool tts = true}) =>
        TtsRequestFormat.normalizeStored(
          rawFormat: raw,
          apiBaseUrl: url,
          isTtsProvider: tts,
        );

    test('未写格式的语音渠道按地址补一次厂商格式', () {
      expect(
        normalize(null, 'https://dashscope.aliyuncs.com/compatible-mode/v1'),
        'aliyun',
      );
      expect(normalize('', 'https://api.fish.audio/v1'), 'fish_audio');
      expect(normalize('openai_tts', 'https://api.minimaxi.com/v1'), 'minimax');
      expect(normalize(null, 'https://api.openai.com/v1'), 'openai_tts');
    });

    test('硅基流动旧格式迁到 OpenAI TTS', () {
      expect(
        normalize('siliconflow_indextts', 'https://api.siliconflow.cn/v1'),
        'openai_tts',
      );
    });

    test('显式厂商格式保持，阿里云子格式保留', () {
      expect(normalize('fish_audio', 'https://proxy.example/v1'), 'fish_audio');
      expect(
        normalize('aliyun_cosyvoice', 'https://dashscope.aliyuncs.com'),
        'aliyun_cosyvoice',
      );
    });

    test('对话渠道不改', () {
      expect(normalize('openai', 'https://api.openai.com/v1'), isNull);
      expect(
        normalize(null, 'https://api.deepseek.com/v1', tts: false),
        isNull,
      );
    });
  });

  group('TtsRequestFormat.parseCustomRestTemplate', () {
    test('合法模板原样返回', () {
      final template = TtsRequestFormat.parseCustomRestTemplate(
        '{"path": "/speak", "headers": {"X-Key": "{apiKey}"}, '
        '"body": {"text": "{text}"}}',
      );
      expect(template['path'], '/speak');
      expect(template['body'], {'text': '{text}'});
    });

    test('非法 JSON 或缺 body 报中文错误', () {
      expect(
        () => TtsRequestFormat.parseCustomRestTemplate('{'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            '不是有效的 JSON',
          ),
        ),
      );
      expect(
        () => TtsRequestFormat.parseCustomRestTemplate('{"path": "/a"}'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            '缺少 body 对象',
          ),
        ),
      );
      expect(
        () => TtsRequestFormat.parseCustomRestTemplate('[]'),
        throwsFormatException,
      );
    });
  });
}
