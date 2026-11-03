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
      pluginEvents: [
        PluginEvent(
          pluginId: 'sticker',
          type: 'sticker_convert',
          data: const {
            'tag': '晚安',
            'stickerId': 'night',
            'assetPath': '/tmp/night.png',
          },
        ),
      ],
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
    expect(
      result.messages[1].blocks?.whereType<ImageBlock>().single.localPath,
      '/tmp/image_1.png',
    );
    expect(result.messages[2].content, '然后再看这张');
    expect(
      result.messages[3].blocks?.whereType<ImageBlock>().single.localPath,
      '/tmp/image_2.png',
    );
    expect(result.messages[4].content, '结束');
  });

  test('编号图片锚点不借用其他编号，未匹配图片末尾追加', () {
    const text = '开始<image>{"id": 2}</image>中间<image>{"id": 9}</image>结束';
    final result = chatMessageProcessor.buildAssistantMessages(
      replyText: text,
      processedText: text,
      pluginEvents: const <PluginEvent>[],
      contents: const <PluginContent>[
        PluginImageContent('/tmp/1.png', slotId: 1),
        PluginImageContent('/tmp/2.png', slotId: 2),
      ],
    );
    final images = result.messages
        .expand((message) => message.blocks ?? <MessageBlock>[])
        .whereType<ImageBlock>()
        .map((image) => image.localPath)
        .toList();
    expect(images, ['/tmp/2.png', '/tmp/1.png']);
    expect(result.messages.last.blocks!.single, isA<ImageBlock>());
    expect(result.messages[result.messages.length - 2].content, '结束');
  });

  test('多模态缺失编号不借用其他编号并将未使用图片追加末尾', () {
    const text =
        '前<image>{"id":"9"}</image>中'
        '<sticker tag="晚安"/><image>{"status":"ready","id":2}</image>尾';
    final result = chatMessageProcessor.buildAssistantMessages(
      replyText: text,
      processedText: text,
      pluginEvents: [
        PluginEvent(
          pluginId: 'sticker',
          type: 'sticker_convert',
          data: const {'tag': '晚安', 'assetPath': '/tmp/night.png'},
        ),
      ],
      contents: const [
        PluginImageContent('/tmp/1.png', slotId: 1),
        PluginImageContent('/tmp/2.png', slotId: 2),
      ],
    );
    expect(
      result.messages.map(
        (m) => m.blocks?.single is ImageBlock
            ? (m.blocks!.single as ImageBlock).localPath
            : m.blocks?.single is EmojiBlock
            ? 'sticker'
            : m.content,
      ),
      ['前', '中', 'sticker', '/tmp/2.png', '尾', '/tmp/1.png'],
    );
  });

  for (final eventFirst in [false, true]) {
    test('图片事件与工具锚点混排不重复且清除未匹配锚点 eventFirst=$eventFirst', () {
      const eventTag = '<image>{"id":1,"status":"pending"}</image>';
      const toolTag = '<image>{"id":"2"}</image>';
      final text =
          '前${eventFirst ? eventTag : toolTag}中'
          '<sticker tag="晚安"/><tts>语音</tts>'
          '${eventFirst ? toolTag : eventTag}后'
          '<image>{"id":9}</image><image>{"id":2}</image><image> </image>尾';
      final result = chatMessageProcessor.buildAssistantMessages(
        replyText: text,
        processedText: text,
        pluginEvents: [
          PluginEvent(
            pluginId: 'image',
            type: 'image_generate',
            data: const {'id': 1, 'tag': eventTag, 'prompt': 'event prompt'},
          ),
          PluginEvent(
            pluginId: 'sticker',
            type: 'sticker_convert',
            data: const {'tag': '晚安', 'assetPath': '/tmp/night.png'},
          ),
        ],
        contents: const [
          PluginImageContent('/tmp/tool.png', slotId: 2),
          PluginImageContent('/tmp/event.png', slotId: 1),
          PluginAudioContent('/tmp/voice.wav'),
        ],
      );
      expect(
        result.messages.map((m) {
          final block = m.blocks?.single;
          return switch (block) {
            ImageBlock() => block.localPath,
            EmojiBlock() => 'sticker',
            AudioBlock() => block.text,
            _ => m.content,
          };
        }),
        [
          '前',
          eventFirst ? '/tmp/event.png' : '/tmp/tool.png',
          '中',
          'sticker',
          '语音',
          eventFirst ? '/tmp/tool.png' : '/tmp/event.png',
          '后',
          '尾',
        ],
      );
    });
  }

  for (final eventTag in [
    '<image>{"id":1}</image>',
    '<image>event prompt</image>',
  ]) {
    test('无 tag 图片事件不消费其他编号锚点 $eventTag', () {
      final text = '前<image>{"id":"2"}</image>中$eventTag尾';
      final result = chatMessageProcessor.buildAssistantMessages(
        replyText: text,
        processedText: text,
        pluginEvents: [
          PluginEvent(
            pluginId: 'image',
            type: 'image_generate',
            data: const {'id': '1', 'prompt': 'event prompt'},
          ),
        ],
        contents: const [
          PluginImageContent('/tmp/event.png', slotId: 1),
          PluginImageContent('/tmp/tool.png', slotId: 2),
        ],
      );
      expect(
        result.messages.map(
          (m) => m.blocks?.single is ImageBlock
              ? (m.blocks!.single as ImageBlock).localPath
              : m.content,
        ),
        ['前', '/tmp/tool.png', '中', '/tmp/event.png', '尾'],
      );
    });
  }

  test('没有占位符时，图片追加在文本后方', () {
    final result = chatMessageProcessor.buildAssistantMessages(
      replyText: '这是正文描述',
      processedText: '这是正文描述',
      pluginEvents: const <PluginEvent>[],
      contents: const <PluginContent>[PluginImageContent('/tmp/image_end.png')],
    );

    expect(result.messages.length, 2);
    expect(result.messages.first.content, '这是正文描述');
    expect(
      result.messages.last.blocks?.whereType<ImageBlock>().single.localPath,
      '/tmp/image_end.png',
    );
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
    expect(
      result.messages[1].blocks?.whereType<ImageBlock>().single.localPath,
      '/tmp/image_a.png',
    );
    expect(result.messages[2].content, '结尾');
    expect(
      result.messages[3].blocks?.whereType<ImageBlock>().single.localPath,
      '/tmp/image_b.png',
    );
  });

  test('图片占位符旁只有标点时，不生成独立文本气泡', () {
    final result = chatMessageProcessor.buildAssistantMessages(
      replyText: '<image></image>。',
      processedText: '<image></image>。',
      pluginEvents: const <PluginEvent>[],
      contents: const <PluginContent>[PluginImageContent('/tmp/image_dot.png')],
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

  for (final multimodal in [false, true]) {
    test('编号锚点兼容字符串和状态并清除耗尽残留 multimodal=$multimodal', () {
      final text =
          '前<image> {"id":"9","status":"pending"} </image>'
          '中<image>{"id":2}</image>后<image> </image>'
          '<image>{"id":2,"status":"failed"}</image>尾'
          '${multimodal ? '<sticker tag="晚安"/><tts>语音</tts>' : ''}';
      final result = chatMessageProcessor.buildAssistantMessages(
        replyText: text,
        processedText: text,
        pluginEvents: [
          if (multimodal)
            PluginEvent(
              pluginId: 'sticker',
              type: 'sticker_convert',
              data: const {
                'tag': '晚安',
                'stickerId': 'night',
                'assetPath': '/tmp/night.png',
              },
            ),
        ],
        contents: const [
          PluginImageContent('/tmp/1.png', slotId: 1),
          PluginImageContent('/tmp/2.png', slotId: 2),
          PluginImageContent('/tmp/legacy.png'),
          PluginAudioContent('/tmp/speech.wav'),
        ],
      );
      final blocks = result.messages.expand(
        (m) => m.blocks ?? <MessageBlock>[],
      );
      expect(blocks.whereType<ImageBlock>().map((b) => b.localPath), [
        '/tmp/legacy.png',
        '/tmp/2.png',
        '/tmp/1.png',
      ]);
      final textMessages = result.messages.where((m) => m.content.isNotEmpty);
      expect(textMessages.map((m) => m.content).join(), '前中后尾');
      expect(
        result.messages.any((m) => m.content.contains('<image>')),
        isFalse,
      );
      if (multimodal) {
        expect(blocks.whereType<EmojiBlock>(), hasLength(1));
        expect(blocks.whereType<AudioBlock>().single.text, '语音');
      }
    });
  }

  test('stripPluginTags 清除带空白和状态的 JSON 图片标签', () {
    expect(
      chatMessageProcessor.stripPluginTags(
        '前<image> {"id":"2","status":"failed"} </image>后',
      ),
      '前后',
    );
  });
}
