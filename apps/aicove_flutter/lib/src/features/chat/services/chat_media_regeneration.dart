import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database_provider.dart';
import '../../../core/database/converters/database_converters.dart';
import '../../../core/services/android_keep_alive_manager.dart';
import '../../../core/models/message_block.dart';
import '../../plugins/image/drawing_preset_provider.dart';
import '../../plugins/image/image_plugin.dart';
import '../../plugins/tts/voice_preset_application.dart';
import '../application/chat_media_regeneration.dart';
import '../chat_providers.dart';
import 'chat_history_store.dart';

export '../application/chat_media_regeneration.dart';

final chatMediaRegenerationProvider =
    Provider<ChatMediaRegenerationPort>((ref) => ChatMediaRegeneration(
          store: ref.read(chatHistoryStoreProvider),
          isSending: (id) => ref.read(conversationSendingProvider(id)),
          generators: {
            RegeneratableMediaKind.image: ChatImageGenerationAdapter(ref),
            RegeneratableMediaKind.audio: ChatAudioGenerationAdapter(ref),
          },
        ));

class ChatImageGenerationAdapter implements ChatMediaGenerationPort {
  ChatImageGenerationAdapter(this.ref);
  final Ref ref;

  @override
  Future<GeneratedChatMedia> generate(String conversationId, String input,
      {ImageGenerationSnapshot? imageSnapshot}) async {
    final owner =
        await ref.read(conversationRepositoryProvider).getById(conversationId);
    if (owner == null) throw StateError('图片所属角色不存在');
    if (!ConversationConverter.fromDb(owner).allowsPlugin('image')) {
      throw StateError('请先开启此角色的绘图插件');
    }
    if (imageSnapshot == null) {
      throw StateError('这张图片未保存完整生成参数，无法按原参数重画');
    }
    final preset = await ref
        .read(drawingPresetCatalogProvider.notifier)
        .resolveForPersona(owner.personaPrompt);
    final catalog = await ref.read(drawingPresetCatalogProvider.future);
    final plugin = ImagePlugin(
        preset.config.copyWith(
          selectedProviderId: imageSnapshot.providerId,
          selectedModelId: imageSnapshot.modelId,
        ),
        ref,
        isRequestSnapshot: true);
    final InlineImageGenerationResult result;
    try {
      result = await plugin.regenerateImage(imageSnapshot, knownArtistPresets: [
        ...catalog.legacyConfig.artistPresets,
        for (final saved in catalog.presets) ...saved.config.artistPresets,
      ]);
    } on StateError {
      rethrow;
    } catch (_) {
      throw StateError('图片重新生成失败，原图已保留。请检查原渠道或稍后重试');
    }
    final path = result.localPath;
    if (!result.success || path == null || path.isEmpty) {
      throw StateError('图片重新生成失败，原图已保留。请检查绘图配置或稍后重试');
    }
    return GeneratedChatMedia.image(path,
        imageSnapshot: result.generationSnapshot);
  }
}

class ChatAudioGenerationAdapter implements ChatMediaGenerationPort {
  ChatAudioGenerationAdapter(this.ref);
  final Ref ref;

  @override
  Future<GeneratedChatMedia> generate(String conversationId, String input,
      {ImageGenerationSnapshot? imageSnapshot}) async {
    final request = await ref
        .read(voicePresetApplicationProvider)
        .forOwnerId(conversationId);
    if (request.ownerId != conversationId || request.service == null) {
      throw StateError(request.error == null
          ? '无法确定发声角色，原语音已保留'
          : '无法重新生成语音，请检查角色音色预设。原语音已保留');
    }
    final result = await request.run(() => request.service!.convert(input));
    if (!result.success || result.audioUrl.trim().isEmpty) {
      throw StateError('语音重新生成失败，原语音已保留');
    }
    // Providers may not return duration. Let the new audio controller measure it.
    return GeneratedChatMedia.audio(result.audioUrl);
  }
}

/// Shared orchestration for image and audio regeneration. Generators only create
/// new media; ownership, single-flight, lifecycle and persistence live here.
class ChatMediaRegeneration implements ChatMediaRegenerationPort {
  ChatMediaRegeneration({
    required this.store,
    required this.generators,
    required this.isSending,
  });

  final ChatHistoryStore store;
  final Map<RegeneratableMediaKind, ChatMediaGenerationPort> generators;
  final bool Function(String conversationId) isSending;
  final Set<(String, String, String)> _pending = {};

  @override
  Future<void> regenerate({
    required String conversationId,
    required String messageId,
    required String blockId,
  }) async {
    final key = (conversationId, messageId, blockId);
    if (!_pending.add(key)) throw StateError('此媒体正在重新生成，请稍候');
    AndroidGenerationKeepAliveLease? lease;
    try {
      if (isSending(conversationId)) throw StateError('当前会话正在生成，请结束后再试');
      final target = await store.loadMediaRegenerationTarget(
          conversationId: conversationId,
          messageId: messageId,
          blockId: blockId);
      final generator = generators[target.kind];
      if (generator == null) throw StateError('不支持重新生成此类媒体');
      lease = await AndroidKeepAliveManager.acquireGenerationLease();
      final result = await generator.generate(conversationId, target.input,
          imageSnapshot: target.block is ImageBlock
              ? (target.block as ImageBlock).generationSnapshot
              : null);
      if (isSending(conversationId)) {
        throw StateError('当前会话已开始新的生成，原媒体已保留，请稍后重试');
      }
      await store.replaceGeneratedMedia(
          conversationId: conversationId, target: target, result: result);
    } finally {
      _pending.remove(key);
      await lease?.release();
    }
  }
}
