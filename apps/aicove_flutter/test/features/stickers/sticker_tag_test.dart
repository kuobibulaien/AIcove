import 'package:aicove_flutter/src/features/plugins/plugin_content_tags.dart';
import 'package:aicove_flutter/src/features/plugins/tts/tts_parser.dart';
import 'package:aicove_flutter/src/features/stickers/sticker_tag.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('StickerTag 语义标签', () {
    test('自闭合表情标签从正文里整段删掉', () {
      expect(
        StickerTag.removeFrom(
          firstPartyContentTagScanner,
          '晚安呀~ <sticker tag="晚安"/>',
        ),
        '晚安呀~ ',
      );
    });

    test('成对写法只去掉外壳，正文保留', () {
      expect(
        StickerTag.removeFrom(
          firstPartyContentTagScanner,
          '好的<sticker tag="收到">收到啦</sticker>',
        ),
        '好的收到啦',
      );
    });

    test('嵌套表情标签与孤立闭标签不泄露，其他标签保持原样', () {
      expect(
        StickerTag.removeFrom(
          firstPartyContentTagScanner,
          '<tts voice="a">你好<sticker tag="开心"/></tts>'
          '<sticker tag="收到">好<sticker tag="开心"/></sticker></sticker>',
        ),
        '<tts voice="a">你好</tts>好',
      );
    });

    test('方括号不再是表情语法，原样保留', () {
      expect(
        StickerTag.removeFrom(firstPartyContentTagScanner, '晚安呀~ [晚安]'),
        '晚安呀~ [晚安]',
      );
    });
  });

  group('语音不念表情标签', () {
    test('语音正文和普通正文里的表情标签都不进入朗读文字', () {
      final result = TtsParser.parse(
        '<tts>你好<sticker tag="开心"/></tts>然后<sticker tag="晚安"/>再见',
      );

      expect(result.segments.single.text, '你好');
      expect(result.cleanText, '然后再见');
    });
  });
}
