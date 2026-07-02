import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_message_processor.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_multimodal_delivery_planner.dart';
import 'package:aicove_flutter/src/features/plugins/domain/plugin.dart';

void main() {
  const planner = ChatMultimodalDeliveryPlanner();

  Message pendingBuilder(String text) => Message.text(
        id: 'pending_$text',
        role: 'assistant',
        content: 'pending:$text',
        createdAt: DateTime(2026),
        status: 'sending',
      );

  Message? stickerBuilder(MultimodalSegment segment) => Message.text(
        id: 'sticker_${segment.content}',
        role: 'assistant',
        content: '[${segment.content}]',
        createdAt: DateTime(2026),
        status: 'sent',
      );

  group('ChatMultimodalDeliveryPlanner', () {
    test('非流式混排会先排文本，再排 TTS 占位与慢图任务', () {
      final steps = planner.planSequentialSteps(
        replyText: '文本a。<tts>语音段</tts>文本b。<image>slow landscape</image>文本c。',
        pluginEvents: <PluginEvent>[
          PluginEvent(
            pluginId: 'tts',
            type: 'tts_convert',
            data: {'text': '语音段', 'originalText': '语音段'},
            id: 'evt_tts',
          ),
          PluginEvent(
            pluginId: 'image',
            type: 'image_generate',
            data: {'prompt': 'slow landscape'},
            id: 'evt_image',
          ),
        ],
        canGenerateTts: true,
        allowTtsTextFallback: true,
        skipTextSegments: false,
        pendingTtsPlaceholderBuilder: pendingBuilder,
        stickerMessageBuilder: stickerBuilder,
      );

      expect(
        steps.map((step) => step.type).toList(growable: false),
        const <ChatSequentialMultimodalStepType>[
          ChatSequentialMultimodalStepType.text,
          ChatSequentialMultimodalStepType.pendingTts,
          ChatSequentialMultimodalStepType.text,
          ChatSequentialMultimodalStepType.deferredImage,
          ChatSequentialMultimodalStepType.text,
        ],
      );
      expect(steps[0].text, '文本a。');
      expect(steps[1].message?.displayText, 'pending:语音段');
      expect(steps[2].text, '文本b。');
      expect(steps[3].imagePrompt, 'slow landscape');
      expect(steps[4].text, '文本c。');
    });

    test('流式后补计划会把 TTS 和表情变成插入项，把图片留给独立慢任务', () {
      final plan = planner.planPostStreamSupplements(
        replyText:
            '文本a。<tts>语音段</tts>文本b。<image>slow landscape</image>[早安]文本c。',
        pluginEvents: <PluginEvent>[
          PluginEvent(
            pluginId: 'tts',
            type: 'tts_convert',
            data: {'text': '语音段', 'originalText': '语音段'},
            id: 'evt_tts',
          ),
          PluginEvent(
            pluginId: 'image',
            type: 'image_generate',
            data: {'prompt': 'slow landscape'},
            id: 'evt_image',
          ),
          PluginEvent(
            pluginId: 'sticker',
            type: 'sticker_convert',
            data: {'tag': '早安', 'assetPath': 'assets/sticker.png'},
            id: 'evt_sticker',
          ),
        ],
        canGenerateTts: true,
        includeTts: true,
        startOrder: 0,
        pendingTtsPlaceholderBuilder: pendingBuilder,
        stickerMessageBuilder: stickerBuilder,
      );

      expect(plan.pendingTtsMessages, hasLength(1));
      expect(plan.pendingTtsMessages.single.displayText, 'pending:语音段');
      expect(plan.imagePrompts, const <String>['slow landscape']);
      expect(plan.insertOps, hasLength(2));
      expect(plan.insertOps[0].textCharsBefore, 4);
      expect(plan.insertOps[0].message.displayText, 'pending:语音段');
      expect(plan.insertOps[1].textCharsBefore, 8);
      expect(plan.insertOps[1].message.displayText, '[早安]');
    });
  });
}
