import 'package:aicove_flutter/src/features/chat/services/chat_message_processor.dart';
import 'package:aicove_flutter/src/features/content_tags/domain/content_tag_scanner.dart';
import 'package:aicove_flutter/src/features/plugins/domain/plugin.dart';
import 'package:aicove_flutter/src/features/plugins/plugin_content_tags.dart';
import 'package:aicove_flutter/src/features/plugins/tts/tts_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('speech parsing and storage split agree on the same elements', () {
    const text = '前<TTS voice="a">一句</TTS>中<tts>二句</tts>后<tts>未闭合';
    final parsed = TtsParser.parse(text);
    expect(parsed.segments.map((s) => s.text), ['一句', '二句']);
    expect(parsed.cleanText, '前中后<tts>未闭合');

    final segments =
        chatMessageProcessor.parseMultimodalSegments(text, const []);
    expect(
      segments
          .where((s) => s.type == MultimodalSegmentType.tts)
          .map((s) => s.content),
      ['一句', '二句'],
    );
  });

  test('stripPluginTags keeps image context records and speech text', () {
    expect(
      chatMessageProcessor.stripPluginTags(
        '<image source="history">记录</image><image>prompt</image>',
      ),
      '<image source="history">记录</image>',
    );
    expect(chatMessageProcessor.stripPluginTags('<Tts>只有语音</Tts>'), '只有语音');
  });

  test('tags merely mentioned in thinking do not swallow the real ones', () {
    const reply = '<think_nya~>这轮要用<tts>标签说话，再用<image>发一张图。</think_nya~>\n'
        '她笑了。<tts>早上好呀</tts>\n<image>1girl, smile</image>\n结束。';
    expect(TtsParser.parse(reply).segments.map((s) => s.text), ['早上好呀']);

    final segments = chatMessageProcessor.parseMultimodalSegments(reply, [
      PluginEvent(
        pluginId: 'image',
        type: 'image_generate',
        data: const {'prompt': '1girl, smile'},
      ),
    ]);
    expect(
      segments.map((s) => '${s.type.name}:${s.content}').toList(),
      [
        'text:<think_nya~>这轮要用<tts>标签说话，再用<image>发一张图。</think_nya~>\n她笑了。',
        'tts:早上好呀',
        'image:1girl, smile',
        'text:结束。',
      ],
    );
  });

  test('a genuinely unfinished tail element still stays open while streaming',
      () {
    final segments = firstPartyContentTagScanner.scan('前文<tts>还在说');
    expect((segments.last as ContentTagElement).closed, isFalse);
  });
}
