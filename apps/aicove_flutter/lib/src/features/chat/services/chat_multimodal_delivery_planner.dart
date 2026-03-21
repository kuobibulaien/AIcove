library;

import '../domain/message.dart';
import '../../plugins/domain/plugin.dart';
import 'chat_message_processor.dart';

typedef PendingTtsPlaceholderBuilder = Message Function(String ttsText);
typedef StickerMessageBuilder = Message? Function(MultimodalSegment segment);

enum ChatSequentialMultimodalStepType {
  text,
  sticker,
  pendingTts,
  deferredImage,
}

class ChatSequentialMultimodalStep {
  const ChatSequentialMultimodalStep.text(this.text)
      : type = ChatSequentialMultimodalStepType.text,
        message = null,
        imagePrompt = null;

  const ChatSequentialMultimodalStep.sticker(this.message)
      : type = ChatSequentialMultimodalStepType.sticker,
        text = null,
        imagePrompt = null;

  const ChatSequentialMultimodalStep.pendingTts(this.message)
      : type = ChatSequentialMultimodalStepType.pendingTts,
        text = null,
        imagePrompt = null;

  const ChatSequentialMultimodalStep.deferredImage(this.imagePrompt)
      : type = ChatSequentialMultimodalStepType.deferredImage,
        text = null,
        message = null;

  final ChatSequentialMultimodalStepType type;
  final String? text;
  final Message? message;
  final String? imagePrompt;
}

class ChatSupplementInsertOp {
  const ChatSupplementInsertOp({
    required this.textCharsBefore,
    required this.order,
    required this.message,
    this.forceAppendToTail = false,
  });

  final int textCharsBefore;
  final int order;
  final Message message;
  final bool forceAppendToTail;
}

class ChatStreamSupplementPlan {
  const ChatStreamSupplementPlan({
    this.insertOps = const <ChatSupplementInsertOp>[],
    this.pendingTtsMessages = const <Message>[],
    this.imagePrompts = const <String>[],
  });

  final List<ChatSupplementInsertOp> insertOps;
  final List<Message> pendingTtsMessages;
  final List<String> imagePrompts;
}

class ChatMultimodalDeliveryPlanner {
  const ChatMultimodalDeliveryPlanner();

  List<ChatSequentialMultimodalStep> planSequentialSteps({
    required String replyText,
    required List<PluginEvent> pluginEvents,
    required bool canGenerateTts,
    required bool allowTtsTextFallback,
    required bool skipTextSegments,
    required PendingTtsPlaceholderBuilder pendingTtsPlaceholderBuilder,
    required StickerMessageBuilder stickerMessageBuilder,
  }) {
    final steps = <ChatSequentialMultimodalStep>[];
    final segments =
        chatMessageProcessor.parseMultimodalSegments(replyText, pluginEvents);
    for (final segment in segments) {
      switch (segment.type) {
        case MultimodalSegmentType.text:
          if (skipTextSegments) continue;
          final text = segment.content.trim();
          if (text.isNotEmpty) {
            steps.add(ChatSequentialMultimodalStep.text(text));
          }
          break;
        case MultimodalSegmentType.sticker:
          final stickerMessage = stickerMessageBuilder(segment);
          if (stickerMessage != null) {
            steps.add(ChatSequentialMultimodalStep.sticker(stickerMessage));
          }
          break;
        case MultimodalSegmentType.tts:
          final ttsText = segment.content.trim();
          if (ttsText.isEmpty) continue;
          if (canGenerateTts) {
            steps.add(ChatSequentialMultimodalStep.pendingTts(
              pendingTtsPlaceholderBuilder(ttsText),
            ));
          } else if (allowTtsTextFallback && !skipTextSegments) {
            steps.add(ChatSequentialMultimodalStep.text(ttsText));
          }
          break;
        case MultimodalSegmentType.image:
          final imagePrompt = _resolveImagePrompt(segment);
          if (imagePrompt != null) {
            steps.add(ChatSequentialMultimodalStep.deferredImage(imagePrompt));
          }
          break;
      }
    }
    return steps;
  }

  ChatStreamSupplementPlan planPostStreamSupplements({
    required String replyText,
    required List<PluginEvent> pluginEvents,
    required bool canGenerateTts,
    required bool includeTts,
    required int startOrder,
    required PendingTtsPlaceholderBuilder pendingTtsPlaceholderBuilder,
    required StickerMessageBuilder stickerMessageBuilder,
  }) {
    final insertOps = <ChatSupplementInsertOp>[];
    final pendingTtsMessages = <Message>[];
    final imagePrompts = <String>[];
    final segments =
        chatMessageProcessor.parseMultimodalSegments(replyText, pluginEvents);
    var textChars = 0;

    for (final segment in segments) {
      switch (segment.type) {
        case MultimodalSegmentType.text:
          textChars += _normalizedTextLength(segment.content);
          break;
        case MultimodalSegmentType.sticker:
          final stickerMessage = stickerMessageBuilder(segment);
          if (stickerMessage != null) {
            insertOps.add(ChatSupplementInsertOp(
              textCharsBefore: textChars,
              order: startOrder + insertOps.length,
              message: stickerMessage,
            ));
          }
          break;
        case MultimodalSegmentType.tts:
          if (!includeTts || !canGenerateTts) break;
          final ttsText = segment.content.trim();
          if (ttsText.isEmpty) break;
          final pendingMessage = pendingTtsPlaceholderBuilder(ttsText);
          pendingTtsMessages.add(pendingMessage);
          insertOps.add(ChatSupplementInsertOp(
            textCharsBefore: textChars,
            order: startOrder + insertOps.length,
            message: pendingMessage,
          ));
          break;
        case MultimodalSegmentType.image:
          final imagePrompt = _resolveImagePrompt(segment);
          if (imagePrompt != null) {
            imagePrompts.add(imagePrompt);
          }
          break;
      }
    }

    return ChatStreamSupplementPlan(
      insertOps: insertOps,
      pendingTtsMessages: pendingTtsMessages,
      imagePrompts: imagePrompts,
    );
  }

  void sortInsertOps(List<ChatSupplementInsertOp> insertOps) {
    insertOps.sort((a, b) {
      final byChars = a.textCharsBefore.compareTo(b.textCharsBefore);
      if (byChars != 0) return byChars;
      return a.order.compareTo(b.order);
    });
  }

  String? _resolveImagePrompt(MultimodalSegment segment) {
    final imagePrompt = (segment.imageData?['prompt'] as String?)?.trim() ??
        segment.content.trim();
    if (imagePrompt.isEmpty) {
      return null;
    }
    return imagePrompt;
  }
}

int _normalizedTextLength(String text) =>
    text.replaceAll(RegExp(r'\s+'), '').length;
