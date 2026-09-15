import '../../../core/models/block_status.dart';
import '../../../core/models/message_block.dart';
import '../domain/message.dart';

enum RegeneratableMediaKind {
  image('图片'),
  audio('语音');

  const RegeneratableMediaKind(this.label);
  final String label;
}

abstract interface class ChatMediaRegenerationPort {
  Future<void> regenerate({
    required String conversationId,
    required String messageId,
    required String blockId,
  });
}

abstract interface class ChatMediaGenerationPort {
  Future<GeneratedChatMedia> generate(String conversationId, String input,
      {ImageGenerationSnapshot? imageSnapshot});
}

/// A persisted media block and its raw-message revision, captured before generation.
class MediaRegenerationTarget {
  const MediaRegenerationTarget({
    required this.message,
    required this.block,
    required this.rawRevision,
  });

  final Message message;
  final MessageBlock block;
  final String rawRevision;

  RegeneratableMediaKind get kind => kindOf(block)!;
  String get input => inputOf(block)!;

  static RegeneratableMediaKind? kindOf(MessageBlock block) => switch (block) {
        ImageBlock() => RegeneratableMediaKind.image,
        AudioBlock() => RegeneratableMediaKind.audio,
        _ => null,
      };

  static String? inputOf(MessageBlock block) => switch (block) {
        ImageBlock() => block.prompt,
        AudioBlock() => block.text,
        _ => null,
      };

  static bool canRegenerate(Message message, MessageBlock block) =>
      message.role == 'assistant' &&
      message.status != 'sending' &&
      (block.status == BlockStatus.success ||
          block.status == BlockStatus.error) &&
      (inputOf(block)?.trim().isNotEmpty ?? false);

  static bool sameSource(MessageBlock left, MessageBlock right) =>
      switch ((left, right)) {
        (ImageBlock a, ImageBlock b) => a.localPath == b.localPath &&
            a.url == b.url &&
            a.base64 == b.base64 &&
            a.prompt == b.prompt,
        (AudioBlock a, AudioBlock b) => a.url == b.url && a.text == b.text,
        _ => false,
      };
}

/// Replacement metadata only; identities and source text stay with the target.
class GeneratedChatMedia {
  const GeneratedChatMedia.image(this.location, {this.imageSnapshot})
      : kind = RegeneratableMediaKind.image,
        durationSeconds = null;
  const GeneratedChatMedia.audio(this.location, {this.durationSeconds})
      : kind = RegeneratableMediaKind.audio,
        imageSnapshot = null;

  final RegeneratableMediaKind kind;
  final String location;
  final ImageGenerationSnapshot? imageSnapshot;
  final double? durationSeconds;

  MessageBlock replace(MessageBlock original) {
    if (MediaRegenerationTarget.kindOf(original) != kind ||
        location.trim().isEmpty ||
        (durationSeconds != null &&
            (!durationSeconds!.isFinite || durationSeconds! < 0))) {
      throw StateError('生成结果无效，原媒体已保留');
    }
    return switch (original) {
      ImageBlock() => ImageBlock(
          id: original.id,
          messageId: original.messageId,
          localPath: location,
          prompt: imageSnapshot?.prompt ?? original.prompt,
          generationSnapshot: imageSnapshot ?? original.generationSnapshot),
      AudioBlock() => AudioBlock(
          id: original.id,
          messageId: original.messageId,
          url: location,
          text: original.text,
          durationSeconds: durationSeconds),
      _ => throw StateError('不支持重新生成此类媒体'),
    };
  }
}
