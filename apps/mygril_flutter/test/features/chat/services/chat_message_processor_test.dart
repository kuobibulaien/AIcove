import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_message_processor.dart';
import 'package:aicove_flutter/src/features/plugins/domain/plugin.dart';
import 'package:aicove_flutter/src/features/plugins/domain/plugin_content.dart';

void main() {
  test('draw_image 图片按占位符位置插回文本中间', () {
    final result = chatMessageProcessor.buildAssistantMessages(
      replyText: '先看这张[图片]然后再看这张[image]结束',
      processedText: '先看这张[图片]然后再看这张[image]结束',
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
      replyText: '开头[图片]结尾',
      processedText: '开头[图片]结尾',
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
}
