import 'package:aicove_flutter/src/features/chat/services/chat_output_tag_reminder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('nothing to remind yields no reminder', () {
    expect(buildOutputTagReminder(), isEmpty);
    expect(buildOutputTagReminder(presetTags: const ['image', ' ']), isEmpty);
  });

  test('plugin tags carry usage, preset tags are only named', () {
    final text = buildOutputTagReminder(
      imageInline: true,
      tts: true,
      presetTags: const ['options', 'thinking', 'options'],
    );
    expect(text, startsWith('本轮回复可以用到的标签（只是提醒，格式和顺序以预设与插件的说明为准）：'));
    expect(text, contains('<image>英文提示词</image>'));
    expect(text, contains('<tts></tts>'));
    expect(text, contains('- 预设里提到的：<options>、<thinking>'));
  });

  test('stable route reminds the tool and placeholder instead', () {
    final text = buildOutputTagReminder(imageTool: true);
    expect(text, contains('draw_image'));
    expect(text, contains('<image></image>'));
    expect(text, isNot(contains('英文提示词')));
  });
}
