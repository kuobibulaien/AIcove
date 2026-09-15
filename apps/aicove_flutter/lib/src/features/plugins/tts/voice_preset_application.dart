import 'dart:io';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../chat/conversation_providers.dart';
import '../../chat/domain/conversation.dart';
import '../../settings/app_settings.dart';
import '../plugin_providers.dart';
import 'providers/tts_voice_provider.dart';
import 'tts_config.dart';
import 'tts_provider_context.dart';
import 'tts_service.dart';
import 'tts_voice_catalog_service.dart';
import 'voice_preset_runtime.dart';
import 'voice_request.dart';

abstract interface class VoicePresetApplicationPort {
  Future<void> initialize();
  Future<VoiceRequest> forRole(Conversation owner);
  Future<VoiceRequest> forOwnerId(String ownerId);
  Future<VoiceRequest> preview(VoicePreset preset);
  Future<VoiceListResult> catalog(String providerId, String modelId);
  Future<VoicePreset> createRemote(VoicePreset preset);
  Future<String> importAudio(String sourcePath);
  Future<List<String>> references(String presetId);
  Future<void> save(VoicePreset preset);
  Future<void> remove(String presetId);
}

final voicePresetApplicationProvider = Provider<VoicePresetApplicationPort>(
  (ref) => VoicePresetApplication(ref),
);
final voicePresetReadyProvider = FutureProvider<void>(
  (ref) => ref.read(voicePresetApplicationProvider).initialize(),
);

class VoicePresetApplication implements VoicePresetApplicationPort {
  VoicePresetApplication(this.ref);
  final Ref ref;

  List<VoicePresetTarget> _targets(AppSettings settings) {
    final targets = <VoicePresetTarget>[];
    for (final provider in settings.providers) {
      if (!provider.enabled) continue;
      for (final model in {...provider.models, ...provider.visibleModels}) {
        final context = TtsProviderContext.resolveForSelection(
          config: TtsConfig(),
          settings: settings,
          providerId: provider.id,
          modelId: model,
        );
        targets.add(
          VoicePresetTarget(
            providerId: provider.id,
            modelId: model,
            providerName: provider.displayName ?? provider.id,
            adapterId: context.voiceProviderId ?? context.requestFormat,
            supportsReferenceAudio:
                context.requestFormat == 'siliconflow_indextts' ||
                context.requestFormat == 'aliyun_qwen_tts' ||
                context.requestFormat == 'aliyun_cosyvoice',
          ),
        );
      }
    }
    return targets;
  }

  @override
  Future<void> initialize() async {
    final settings = await ref.read(appSettingsProvider.future);
    await ref
        .read(ttsPluginConfigProvider.notifier)
        .migratePresets(_targets(settings));
  }

  @override
  Future<VoiceRequest> forOwnerId(String ownerId) async {
    if (ownerId.isEmpty) {
      return VoiceRequest(ownerId: ownerId, error: '无法确定发声角色');
    }
    final owner = await ref.read(conversationByIdProvider(ownerId).future);
    if (owner == null) return VoiceRequest(ownerId: ownerId, error: '发声角色不存在');
    return forRole(owner);
  }

  @override
  Future<VoiceRequest> forRole(Conversation owner) async {
    try {
      await initialize();
      final config = ref.read(ttsPluginConfigProvider);
      if (!config.enabled ||
          (owner.enabledPlugins != null &&
              !owner.enabledPlugins!.contains('tts'))) {
        return VoiceRequest(ownerId: owner.id, error: '此角色未启用语音插件');
      }
      return _prepare(
        owner.id,
        owner.voiceFile,
        config,
        await ref.read(appSettingsProvider.future),
        defaultId: config.defaultVoicePresetId,
      );
    } catch (e) {
      return VoiceRequest(ownerId: owner.id, error: e.toString());
    }
  }

  @override
  Future<VoiceRequest> preview(VoicePreset preset) async {
    await initialize();
    final config = ref
        .read(ttsPluginConfigProvider)
        .copyWith(enabled: true, voicePresets: [preset]);
    return _prepare(
      'preview:${preset.id}',
      preset.id,
      config,
      await ref.read(appSettingsProvider.future),
    );
  }

  VoiceRequest _prepare(
    String ownerId,
    String? presetId,
    TtsConfig config,
    AppSettings settings, {
    String? defaultId,
  }) {
    try {
      final snapshot = const VoicePresetRuntime().resolve(
        ownerId: ownerId,
        presetId: presetId,
        defaultPresetId: defaultId,
        config: config,
        targets: _targets(settings),
      );
      final context = TtsProviderContext.resolve(
        config: snapshot.config,
        settings: settings,
      );
      final provider = context.providerAuth;
      if (provider == null ||
          !context.hasApiKey ||
          provider.apiBaseUrl.trim().isEmpty) {
        throw StateError('此预设的供应商缺少 API 地址或密钥');
      }
      final material = snapshot.config.selectedVoicePreset!;
      if (material.synthesis?.voiceId?.isNotEmpty != true &&
          material.localAudioPath?.isNotEmpty == true &&
          context.requestFormat == 'aliyun_cosyvoice') {
        throw StateError('CosyVoice 需要公网音频链接或音色 ID，不能直接使用本地文件');
      }
      // Credential and URL snapshots stay in memory for this request only.
      return VoiceRequest(
        ownerId: ownerId,
        service: TtsService(
          config: snapshot.config,
          apiKey: context.apiKey,
          requestUrl: provider.apiBaseUrl,
          requestFormat: context.requestFormat,
          model: snapshot.target.modelId,
          customConfig: (jsonDecode(jsonEncode(provider.customConfig)) as Map)
              .cast<String, dynamic>(),
          onVoiceCreated: ownerId.startsWith('preview:')
              ? null
              : (updated) => ref
                    .read(ttsPluginConfigProvider.notifier)
                    .saveCreatedVoice(material, updated),
        ),
      );
    } catch (e) {
      return VoiceRequest(ownerId: ownerId, error: e.toString());
    }
  }

  Future<TtsProviderContext> _context(String providerId, String modelId) async {
    final context = TtsProviderContext.resolveForSelection(
      config: ref.read(ttsPluginConfigProvider),
      settings: await ref.read(appSettingsProvider.future),
      providerId: providerId,
      modelId: modelId,
    );
    if (context.providerAuth?.enabled != true ||
        context.selectedModelId == null) {
      throw StateError('此预设的渠道或模型不可用，请检查供应商配置');
    }
    return context;
  }

  @override
  Future<VoiceListResult> catalog(String providerId, String modelId) async =>
      TtsVoiceCatalogService.listVoices(await _context(providerId, modelId));

  @override
  Future<VoicePreset> createRemote(VoicePreset preset) async {
    final synthesis = preset.synthesis;
    if (synthesis == null) throw StateError('请先选择渠道和模型');
    final context = await _context(synthesis.providerId, synthesis.modelId);
    final path = preset.localAudioPath;
    final bytes = path == null || path.isEmpty
        ? null
        : await File(path).readAsBytes();
    final result = await TtsVoiceCatalogService.createVoice(
      context: context,
      request: VoiceCreateRequest(
        name: preset.name,
        audioBytes: bytes,
        fileName: path?.split('/').last,
        audioUrl: preset.promptAudioUrl,
        promptText: preset.promptText,
        targetModel: synthesis.modelId,
      ),
    );
    final binding = result.voice.bindings
        .where((b) => b.providerId == synthesis.providerId)
        .firstOrNull;
    if (binding == null) throw StateError('供应商没有返回音色 ID');
    return preset.copyWith(
      bindings: [binding],
      synthesis: VoiceSynthesisSettings(
        providerId: synthesis.providerId,
        modelId: synthesis.modelId,
        voiceId: binding.remoteVoiceId,
        speed: synthesis.speed,
        maxCharsPerChunk: synthesis.maxCharsPerChunk,
        voiceFrequency: synthesis.voiceFrequency,
        systemPromptTemplate: synthesis.systemPromptTemplate,
      ),
    );
  }

  @override
  Future<String> importAudio(String sourcePath) async {
    final source = File(sourcePath);
    if (!await source.exists()) throw StateError('音频文件不存在，请重新选择');
    if (await source.length() > 20 * 1024 * 1024) {
      throw StateError('请选择 20MB 以内的参考音频');
    }
    final extension = sourcePath.split('.').last.toLowerCase();
    if (!['wav', 'mp3', 'm4a', 'flac', 'ogg', 'aac'].contains(extension)) {
      throw StateError('请选择音频文件');
    }
    final dir = Directory(
      '${(await getApplicationDocumentsDirectory()).path}/voice_presets',
    );
    await dir.create(recursive: true);
    return (await source.copy(
      '${dir.path}/${const Uuid().v4()}.$extension',
    )).path;
  }

  @override
  Future<List<String>> references(String presetId) async {
    final roles = await ref.read(conversationsProvider.future);
    return [
      for (final role in roles)
        if (role.voiceFile == presetId) role.displayName,
    ];
  }

  @override
  Future<void> save(VoicePreset preset) async {
    await initialize();
    if (preset.name.trim().isEmpty) throw StateError('请填写预设名称');
    if (preset.synthesis != null && !preset.synthesis!.hasValidParameters) {
      throw StateError('预设参数不正确');
    }
    await ref.read(ttsPluginConfigProvider.notifier).savePreset(preset);
  }

  @override
  Future<void> remove(String presetId) async {
    if ((await references(presetId)).isNotEmpty) {
      throw StateError('仍有角色绑定此预设，请先更换角色的音色');
    }
    await ref.read(ttsPluginConfigProvider.notifier).removePreset(presetId);
    // Shared/local assets and remote voices are deliberately not deleted.
  }
}
