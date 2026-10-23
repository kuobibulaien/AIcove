import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_message_processor.dart';
import 'package:aicove_flutter/src/features/plugins/domain/plugin.dart';
import 'package:aicove_flutter/src/features/plugins/domain/plugin_content.dart';

void main() {
  test('正文兜底去掉表情标签，保留成对标签内文与换行', () {
    expect(
      chatMessageProcessor.stripPluginTags(
        '前\n<sticker tag="收到"/>中<sticker tag="收到">收到啦</sticker>后',
      ),
      '前\n中收到啦后',
    );
    expect(chatMessageProcessor.stripPluginTags('<sticker tag="晚安"/>'), '');
    expect(
      chatMessageProcessor.stripPluginTags('<tts>晚安<sticker tag="晚安"/></tts>'),
      '晚安',
    );
  });

  test('未经插件清理的显示副本也不显示表情标签', () {
    final result = chatMessageProcessor.buildAssistantMessages(
      replyText: '晚安<sticker tag="晚安"/>',
      processedText: '晚安<sticker tag="晚安"/>',
      pluginEvents: const [],
    );
    expect(result.messages.single.displayText, '晚安');
  });

  test('表情转换后正文按原位拆分，只生成一个表情块', () {
    final result = chatMessageProcessor.buildAssistantMessages(
      replyText: '晚安<sticker tag="晚安"/>好梦',
      processedText: '晚安好梦',
      pluginEvents: [PluginEvent(
        pluginId: 'sticker', type: 'sticker_convert',
        data: const {'tag': '晚安', 'stickerId': 'night', 'assetPath': '/tmp/night.png'},
      )],
    );
    expect(result.messages, hasLength(3));
    expect(result.messages.first.displayText, '晚安');
    expect(result.messages[1].blocks!.single, isA<EmojiBlock>());
    expect(result.messages.last.displayText, '好梦');
  });

  test('draw_image 图片按占位符位置插回文本中间', () {
    final result = chatMessageProcessor.buildAssistantMessages(
      replyText: '先看这张<image></image>然后再看这张<image></image>结束',
      processedText: '先看这张<image></image>然后再看这张<image></image>结束',
      pluginEvents: const <PluginEvent>[],
      contents: const <PluginContent>[
        PluginImageContent('/tmp/image_1.png', caption: 'img1'),
        PluginImageContent('/tmp/image_2.png', caption: 'img2'),
      ],
    );

    expect(result.messages.length, 5);
    expect(result.messages[0].content, '先看这张');
    expect(result.messages[1].blocks?.whereType<ImageBlock>().single.localPath,
        '/tmp/image_1.png');
    expect(result.messages[2].content, '然后再看这张');
    expect(result.messages[3].blocks?.whereType<ImageBlock>().single.localPath,
        '/tmp/image_2.png');
    expect(result.messages[4].content, '结束');
  });

  test('没有占位符时，图片追加在文本后方', () {
    final result = chatMessageProcessor.buildAssistantMessages(
      replyText: '这是正文描述',
      processedText: '这是正文描述',
      pluginEvents: const <PluginEvent>[],
      contents: const <PluginContent>[
        PluginImageContent('/tmp/image_end.png'),
      ],
    );

    expect(result.messages.length, 2);
    expect(result.messages.first.content, '这是正文描述');
    expect(
        result.messages.last.blocks?.whereType<ImageBlock>().single.localPath,
        '/tmp/image_end.png');
  });

  test('图片数量多于占位符时，剩余图片顺序追加到末尾', () {
    final result = chatMessageProcessor.buildAssistantMessages(
      replyText: '开头<image></image>结尾',
      processedText: '开头<image></image>结尾',
      pluginEvents: const <PluginEvent>[],
      contents: const <PluginContent>[
        PluginImageContent('/tmp/image_a.png'),
        PluginImageContent('/tmp/image_b.png'),
      ],
    );

    expect(result.messages.length, 4);
    expect(result.messages[0].content, '开头');
    expect(result.messages[1].blocks?.whereType<ImageBlock>().single.localPath,
        '/tmp/image_a.png');
    expect(result.messages[2].content, '结尾');
    expect(result.messages[3].blocks?.whereType<ImageBlock>().single.localPath,
        '/tmp/image_b.png');
  });

  test('图片占位符旁只有标点时，不生成独立文本气泡', () {
    final result = chatMessageProcessor.buildAssistantMessages(
      replyText: '<image></image>。',
      processedText: '<image></image>。',
      pluginEvents: const <PluginEvent>[],
      contents: const <PluginContent>[
        PluginImageContent('/tmp/image_dot.png'),
      ],
    );

    expect(result.messages.length, 1);
    expect(
      result.messages.single.blocks?.whereType<ImageBlock>().single.localPath,
      '/tmp/image_dot.png',
    );
  });

  test('stripPluginTags 只移除标准 inline image 标签，不误删带属性的内容', () {
    expect(
      chatMessageProcessor.stripPluginTags('前文<image>prompt</image>后文'),
      '前文后文',
    );
    expect(
      chatMessageProcessor.stripPluginTags(
        '前文<image source="history">keep me</image>后文',
      ),
      '前文<image source="history">keep me</image>后文',
    );
  });
}
