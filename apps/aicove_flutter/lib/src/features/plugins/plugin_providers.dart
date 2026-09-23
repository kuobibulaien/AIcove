import '../../core/sync/cloud_local_write.dart';
// ignore_for_file: avoid_print
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

import '../../core/app_logger.dart';
import '../settings/app_settings.dart';
import 'plugin_manager.dart';
import 'tts/tts_plugin.dart';
import 'tts/tts_config.dart';
import 'tts/voice_preset_migration.dart';
import 'tts/voice_preset_runtime.dart';
import 'tts/tts_player_manager.dart';
import 'tts/tts_service.dart';
import 'trigger/trigger_plugin.dart';
import 'trigger/trigger_config.dart';
import 'memory/memory_plugin.dart';
import 'sticker/sticker_plugin.dart';
import 'sticker/sticker_config.dart';
import 'image/image_plugin.dart';
import 'image/image_config.dart';
import 'time_awareness/time_awareness_plugin.dart';
import 'time_awareness/time_awareness_config.dart';

/// (注释已丢失)
final pluginManagerProvider = Provider<PluginManager>((ref) {
  // 监听配置变化，并在变化时更新插件实例
  final ttsConfig = ref.watch(ttsPluginConfigProvider);
  final triggerConfig = ref.watch(triggerPluginConfigProvider);
  final stickerConfig = ref.watch(stickerPluginConfigProvider);
  final imageConfig = ref.watch(imagePluginConfigProvider);
  final timeAwarenessConfig = ref.watch(timeAwarenessPluginConfigProvider);

  final appSettingsAsync = ref.watch(appSettingsProvider);
  final autoReplySettings = appSettingsAsync.valueOrNull?.autoReplySettings;
  final effectiveTriggerConfig = triggerConfig.copyWith(
    enabled: triggerConfig.enabled && (autoReplySettings?.enabled ?? false),
  );

  // Keep PluginManager as singleton to avoid recreating plugin instances.
  _pluginManagerSingleton ??= PluginManager();
  _pluginManagerSingleton!.updatePlugin(
    // Global registration supplies only availability. Every request replaces
    // this with TtsPlugin.forRequest using the role's complete voice preset.
    TtsPlugin(ttsConfig),
  );
  _pluginManagerSingleton!.updatePlugin(
    TriggerPlugin(effectiveTriggerConfig, ref),
  );
  _pluginManagerSingleton!.updatePlugin(MemoryPlugin(ref));
  _pluginManagerSingleton!.updatePlugin(StickerPlugin(stickerConfig));
  _pluginManagerSingleton!.updatePlugin(ImagePlugin(imageConfig, ref));
  _pluginManagerSingleton!.updatePlugin(
    TimeAwarenessPlugin(timeAwarenessConfig),
  );

  return _pluginManagerSingleton!;
});

// PluginManager 单例
PluginManager? _pluginManagerSingleton;

/// TTS 插件配置 Provider
final ttsPluginConfigProvider =
    StateNotifierProvider<TtsPluginConfigNotifier, TtsConfig>(
      (ref) => TtsPluginConfigNotifier(),
    );

/// TTS 插件配置 Notifier
class TtsPluginConfigNotifier extends StateNotifier<TtsConfig> {
  static const _storageKey = 'aicove.plugins.tts.config';

  late final Future<void> ready;
  Object? loadError;
  Future<void> _writes = Future<void>.value();

  TtsPluginConfigNotifier() : super(_defaultConfig()) {
    ready = _loadConfig();
  }

  Future<void> _transact(TtsConfig Function(TtsConfig current) change) {
    final task = _writes.catchError((_) {}).then((_) async {
      await ready;
      if (loadError != null) throw StateError('语音配置读取失败，未覆盖原数据：$loadError');
      final next = change(state);
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_storageKey);
      const backupKey = 'aicove.plugins.tts.before_voice_presets_v1';
      if (raw != null && !prefs.containsKey(backupKey)) {
        if (!await cloudLocalWrite(() => prefs.setString(backupKey, raw))) {
          throw StateError('旧语音配置备份失败，未修改配置');
        }
      }
      if (!await cloudLocalWrite(
        () => prefs.setString(_storageKey, jsonEncode(next.toJson())),
      )) {
        throw StateError('语音配置保存失败');
      }
      if (mounted) state = next;
    });
    _writes = task;
    return task;
  }

  Future<void> migratePresets(List<VoicePresetTarget> targets) async {
    await ready;
    if (loadError != null) throw StateError('语音配置读取失败：$loadError');
    if (state.presetSchemaVersion >= 1) return;
    await _transact((current) {
      if (current.presetSchemaVersion >= 1) return current;
      final plan = prepareVoicePresetMigration(
        config: current,
        targets: targets,
      );
      final oldDefault = plan.config.voicePresets
          .where(
            (p) => p.id == current.selectedVoicePresetId && p.synthesis != null,
          )
          .firstOrNull;
      return plan.config.copyWith(
        presetSchemaVersion: 1,
        defaultVoicePresetId: oldDefault?.id,
      );
    });
  }

  Future<void> savePreset(VoicePreset preset) => _transact((current) {
    final existing = current.voicePresets
        .where((p) => p.id == preset.id)
        .toList();
    if (existing.length > 1) throw StateError('预设标识重复，请先整理旧数据');
    return current.copyWith(
      voicePresets: [
        for (final item in current.voicePresets)
          item.id == preset.id ? preset : item,
        if (existing.isEmpty) preset,
      ],
    );
  });

  Future<void> saveCreatedVoice(VoicePreset expected, VoicePreset updated) =>
      _transact((current) {
        final saved = current.voicePresets
            .where((p) => p.id == expected.id)
            .firstOrNull;
        if (saved == null ||
            saved.synthesis == null ||
            jsonEncode(saved.synthesis!.toJson()) !=
                jsonEncode(expected.synthesis?.toJson()) ||
            saved.promptAudioUrl != expected.promptAudioUrl ||
            saved.localAudioPath != expected.localAudioPath ||
            saved.promptText != expected.promptText) {
          return current;
        }
        final binding = updated.bindings
            .where(
              (b) =>
                  b.providerId == saved.synthesis!.providerId &&
                  b.modelId == saved.synthesis!.modelId,
            )
            .firstOrNull;
        if (binding == null) return current;
        final next = saved.copyWith(
          bindings: [binding],
          synthesis: VoiceSynthesisSettings.fromJson({
            ...saved.synthesis!.toJson(),
            'voiceId': binding.remoteVoiceId,
          }),
        );
        return current.copyWith(
          voicePresets: [
            for (final p in current.voicePresets) p.id == saved.id ? next : p,
          ],
        );
      });

  Future<void> setDefaultPreset(String? id) => _transact((current) {
    if (id != null &&
        !current.voicePresets.any((p) => p.id == id && p.synthesis != null)) {
      throw StateError('请先完善音色预设');
    }
    return current.copyWith(defaultVoicePresetId: id);
  });

  Future<void> removePreset(String id) => _transact(
    (current) => current.copyWith(
      voicePresets: current.voicePresets.where((p) => p.id != id).toList(),
      defaultVoicePresetId: current.defaultVoicePresetId == id
          ? null
          : current.defaultVoicePresetId,
    ),
  );

  static TtsConfig _defaultConfig() {
    return TtsConfig(enabled: true);
  }

  Future<void> _loadConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = prefs.getString(_storageKey);

      if (json != null && json.isNotEmpty) {
        final data = jsonDecode(json) as Map<String, dynamic>;
        state = TtsConfig.fromJson(data);
      }
    } catch (e) {
      loadError = e;
      print('[TtsPluginConfigNotifier] Failed to load config: $e');
    }
  }

  Future<void> updateConfig(TtsConfig config) async {
    state = config;
    await _saveConfig();
  }

  Future<void> _saveConfig() async {
    final data = jsonEncode(state.toJson());
    final prefs = await SharedPreferences.getInstance();
    if (!await cloudLocalWrite(() => prefs.setString(_storageKey, data))) {
      throw StateError('配置写入失败');
    }
  }

  /// (注释已丢失)
  Future<void> setSelectedProvider(String? providerId) async {
    state = state.copyWith(selectedProviderId: providerId);
    await _saveConfig();
  }

  /// (注释已丢失)
  Future<void> setSelectedModel(String? modelId) async {
    state = state.copyWith(selectedModelId: modelId);
    await _saveConfig();
  }

  Future<void> setPromptAudio({String? audioUrl, String? text}) async {
    state = state.copyWith(promptAudioUrl: audioUrl, promptText: text);
    await _saveConfig();
  }

  Future<void> setSpeed(double? speed) async {
    state = state.copyWith(speed: speed);
    await _saveConfig();
  }

  Future<void> setMaxCharsPerChunk(int maxChars) async {
    state = state.copyWith(maxCharsPerChunk: maxChars);
    await _saveConfig();
  }

  /// Set emotion text (IndexTTS-2).
  Future<void> setEmoText({String? emoText, bool? useEmoText}) async {
    state = state.copyWith(emoText: emoText, useEmoText: useEmoText);
    await _saveConfig();
  }

  Future<void> setSystemPromptTemplate(String template) async {
    state = state.copyWith(systemPromptTemplate: template);
    await _saveConfig();
  }

  /// (注释已丢失)
  Future<void> setVoiceFrequency(int frequency) async {
    state = state.copyWith(voiceFrequency: frequency.clamp(0, 100));
    await _saveConfig();
  }

  /// (注释已丢失)
  Future<void> addVoicePreset(VoicePreset preset) async {
    final newPresets = [...state.voicePresets, preset];
    state = state.copyWith(voicePresets: newPresets);
    await _saveConfig();
  }

  /// (注释已丢失)
  Future<void> updateVoicePreset(VoicePreset preset) async {
    AppLogger.info(
      'TTS',
      '更新语音预设',
      metadata: {
        'presetId': preset.id,
        'presetName': preset.name,
        'aliyunVoiceId': preset.aliyunVoiceId,
        'existingPresetIds': state.voicePresets.map((p) => p.id).toList(),
      },
    );

    final newPresets = state.voicePresets.map((p) {
      if (p.id == preset.id) {
        AppLogger.info(
          'TTS',
          'Matched voice preset, updating',
          metadata: {
            'oldAliyunVoiceId': p.aliyunVoiceId,
            'newAliyunVoiceId': preset.aliyunVoiceId,
          },
        );
        return preset;
      }
      return p;
    }).toList();

    final matched = newPresets.any(
      (p) => p.id == preset.id && p.aliyunVoiceId == preset.aliyunVoiceId,
    );
    if (!matched) {
      AppLogger.warning(
        'TTS',
        'No matching voice preset found during update',
        metadata: {'presetId': preset.id},
      );
    }

    state = state.copyWith(voicePresets: newPresets);
    await _saveConfig();
  }

  /// (注释已丢失)
  Future<void> deleteVoicePreset(String presetId) async {
    final newPresets = state.voicePresets
        .where((p) => p.id != presetId)
        .toList();
    // (注释已丢失)
    String? newSelectedId = state.selectedVoicePresetId;
    if (newSelectedId == presetId) {
      newSelectedId = null;
    }
    state = state.copyWith(
      voicePresets: newPresets,
      selectedVoicePresetId: newSelectedId,
    );
    await _saveConfig();
  }

  /// (注释已丢失)
  Future<void> selectVoicePreset(String? presetId) async {
    state = state.copyWith(selectedVoicePresetId: presetId);
    await _saveConfig();
  }

  /// (注释已丢失)
  Future<void> addVoicePresets(List<VoicePreset> presets) async {
    // Filter out already existing presets by id.
    final existingIds = state.voicePresets.map((p) => p.id).toSet();
    final newPresets = presets
        .where((p) => !existingIds.contains(p.id))
        .toList();
    if (newPresets.isEmpty) return;

    final allPresets = [...state.voicePresets, ...newPresets];
    state = state.copyWith(voicePresets: allPresets);
    await _saveConfig();
  }
}

/// TTS 播放器管理器 Provider（单例）
/// (注释已丢失)
final ttsPlayerManagerProvider = Provider<TtsPlayerManager?>((ref) {
  final pluginManager = ref.watch(pluginManagerProvider);
  final ttsPlugin = pluginManager.getPlugin('tts') as TtsPlugin?;
  if (ttsPlugin == null) {
    // Do not throw when plugin is absent.
    return null;
  }

  // 创建 TtsService 获取器，每次调用时从 PluginManager 获取最新的 TtsPlugin.service
  // 这样可以确保即使 Provider 只被 read 一次，也能获取到最新的配置
  // Production events must carry an owner-bound request. No global fallback.
  TtsService? getLatestTtsService() => null;

  // Use singleton manager and refresh getter each rebuild.
  if (_ttsManagerSingleton == null) {
    _ttsManagerSingleton = TtsPlayerManager(getLatestTtsService);
    AppLogger.info('TTS', 'TtsPlayerManager 初始化');
  } else {
    _ttsManagerSingleton!.updateServiceGetter(getLatestTtsService);
    AppLogger.debug('TTS', 'TtsPlayerManager 服务引用已刷新');
  }

  return _ttsManagerSingleton!;
});

// (注释已丢失)
TtsPlayerManager? _ttsManagerSingleton;

/// (注释已丢失)
final ttsPlayStateProvider = StreamProvider<TtsPlayState>((ref) {
  final manager = ref.watch(ttsPlayerManagerProvider);
  if (manager == null) {
    // TTS 插件不存在，返回空流
    return Stream.value(TtsPlayState.idle);
  }
  return manager.playStateStream;
});

/// Trigger 插件配置 Provider
final triggerPluginConfigProvider =
    StateNotifierProvider<TriggerPluginConfigNotifier, TriggerConfig>((ref) {
      final notifier = TriggerPluginConfigNotifier(ref);
      notifier.syncFromAppSettings(ref.read(appSettingsProvider).valueOrNull);
      ref.listen<AsyncValue<AppSettings>>(appSettingsProvider, (
        previous,
        next,
      ) {
        notifier.syncFromAppSettings(next.valueOrNull);
      });
      return notifier;
    });

/// Trigger 插件配置 Notifier
class TriggerPluginConfigNotifier extends StateNotifier<TriggerConfig> {
  static const _storageKey = 'aicove.plugins.trigger.config';
  final Ref _ref;

  TriggerPluginConfigNotifier(this._ref) : super(const TriggerConfig()) {
    _loadConfig();
  }

  void syncFromAppSettings(AppSettings? settings) {
    if (settings == null) return;
    final enabled = settings.autoReplySettings.allowAiSetReminders;
    if (state.enabled != enabled) {
      state = state.copyWith(enabled: enabled);
    }
  }

  Future<void> _loadConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = prefs.getString(_storageKey);

      if (json != null && json.isNotEmpty) {
        final data = jsonDecode(json) as Map<String, dynamic>;
        final config = TriggerConfig.fromJson(data);
        state = state.copyWith(logicSystemPrompt: config.logicSystemPrompt);
      }
      syncFromAppSettings(_ref.read(appSettingsProvider).valueOrNull);
    } catch (e) {
      print('[TriggerPluginConfigNotifier] Failed to load config: $e');
    }
  }

  Future<void> setEnabled(bool enabled) async {
    state = state.copyWith(enabled: enabled);
    final settings = await _ref.read(appSettingsProvider.future);
    await _ref
        .read(appSettingsProvider.notifier)
        .updateAutoReplySettings(
          settings.autoReplySettings.copyWith(allowAiSetReminders: enabled),
        );
    await _saveConfig();
  }

  Future<void> setLogicSystemPrompt(String prompt) async {
    state = state.copyWith(logicSystemPrompt: prompt);
    await _saveConfig();
  }

  Future<void> _saveConfig() async {
    final data = jsonEncode(state.toJson());
    final prefs = await SharedPreferences.getInstance();
    if (!await cloudLocalWrite(() => prefs.setString(_storageKey, data))) {
      throw StateError('配置写入失败');
    }
  }
}

/// Sticker 插件配置 Provider
final stickerPluginConfigProvider =
    StateNotifierProvider<StickerPluginConfigNotifier, StickerConfig>(
      (ref) => StickerPluginConfigNotifier(),
    );

/// Sticker 插件配置 Notifier
class StickerPluginConfigNotifier extends StateNotifier<StickerConfig> {
  static const _storageKey = 'aicove.plugins.sticker.config';

  StickerPluginConfigNotifier() : super(const StickerConfig()) {
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = prefs.getString(_storageKey);

      if (json != null && json.isNotEmpty) {
        final data = jsonDecode(json) as Map<String, dynamic>;
        state = StickerConfig.fromJson(data);
      }
    } catch (e) {
      print('[StickerPluginConfigNotifier] Failed to load config: $e');
    }
  }

  Future<void> setSystemPromptTemplate(String template) async {
    state = state.copyWith(systemPromptTemplate: template);
    await _saveConfig();
  }

  Future<void> _saveConfig() async {
    final data = jsonEncode(state.toJson());
    final prefs = await SharedPreferences.getInstance();
    if (!await cloudLocalWrite(() => prefs.setString(_storageKey, data))) {
      throw StateError('配置写入失败');
    }
  }
}

/// Image 插件配置 Provider
final imagePluginConfigProvider =
    StateNotifierProvider<ImagePluginConfigNotifier, ImageConfig>(
      (ref) => ImagePluginConfigNotifier(),
    );

/// Image 插件配置 Notifier
class ImagePluginConfigNotifier extends StateNotifier<ImageConfig> {
  static const _storageKey = 'aicove.plugins.image.config';

  ImagePluginConfigNotifier() : super(const ImageConfig()) {
    _loadConfig();
  }

  ImageConfig get currentConfig => state;

  Future<void> _loadConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = prefs.getString(_storageKey);

      if (json != null && json.isNotEmpty) {
        final data = jsonDecode(json) as Map<String, dynamic>;
        state = ImageConfig.fromJson(data);
      }
    } catch (e) {
      print('[ImagePluginConfigNotifier] Failed to load config: $e');
    }
  }

  Future<void> updateConfig(ImageConfig config) async {
    final data = jsonEncode(config.toJson());
    final prefs = await SharedPreferences.getInstance();
    if (!await cloudLocalWrite(() => prefs.setString(_storageKey, data))) {
      throw StateError('配置写入失败');
    }
    state = config;
  }

  Future<void> _saveConfig() async {
    final data = jsonEncode(state.toJson());
    final prefs = await SharedPreferences.getInstance();
    if (!await cloudLocalWrite(() => prefs.setString(_storageKey, data))) {
      throw StateError('配置写入失败');
    }
  }

  Future<void> setSelectedProvider(String? providerId) async {
    final changed = providerId != state.selectedProviderId;
    state = state.copyWith(
      selectedProviderId: providerId,
      clearSelectedModelId: changed,
    );
    await _saveConfig();
  }

  Future<void> setSelectedModel(String? modelId) async {
    state = state.copyWith(selectedModelId: modelId);
    await _saveConfig();
  }

  Future<void> setDefaultNegativePrompt(String text) async {
    state = state.copyWith(defaultNegativePrompt: text.trim());
    await _saveConfig();
  }

  Future<void> setDefaultWidth(int width) async {
    state = state.copyWith(defaultWidth: width.clamp(256, 2048));
    await _saveConfig();
  }

  Future<void> setDefaultHeight(int height) async {
    state = state.copyWith(defaultHeight: height.clamp(256, 2048));
    await _saveConfig();
  }

  Future<void> setDefaultSteps(int steps) async {
    state = state.copyWith(defaultSteps: steps.clamp(1, 100));
    await _saveConfig();
  }

  Future<void> setDefaultGuidanceScale(double scale) async {
    state = state.copyWith(defaultGuidanceScale: scale.clamp(1.0, 20.0));
    await _saveConfig();
  }

  Future<void> setDefaultCount(int count) async {
    state = state.copyWith(defaultCount: count.clamp(1, 4));
    await _saveConfig();
  }

  Future<void> setDrawingSystemPrompt(String text) async {
    final updated = state.manualToolDescriptionBlocks.copyWith(
      promptDescription: text.trim(),
    );
    state = state.copyWith(
      drawingSystemPrompt: ImageConfig.encodeToolDescriptionBlocks(updated),
      clearSelectedSystemPromptPreset: true,
    );
    await _saveConfig();
  }

  Future<void> setManualToolDescriptionBlocks(
    DrawImageToolDescriptionBlocks blocks,
  ) async {
    state = state.copyWith(
      drawingSystemPrompt: ImageConfig.encodeToolDescriptionBlocks(blocks),
      clearSelectedSystemPromptPreset: true,
    );
    await _saveConfig();
  }

  Future<void> addArtistPreset(ArtistPreset preset) async {
    final updated = [...state.artistPresets, preset];
    state = state.copyWith(artistPresets: updated);
    await _saveConfig();
  }

  Future<void> removeArtistPreset(String name) async {
    final updated = state.artistPresets.where((p) => p.name != name).toList();
    final clearSelection = state.selectedArtistPresetName == name;
    state = state.copyWith(
      artistPresets: updated,
      clearSelectedArtistPreset: clearSelection,
    );
    await _saveConfig();
  }

  Future<void> selectArtistPreset(String? name) async {
    state = state.copyWith(
      selectedArtistPresetName: name,
      clearSelectedArtistPreset: name == null,
    );
    await _saveConfig();
  }

  Future<void> updateArtistPreset(
    String oldName,
    ArtistPreset newPreset,
  ) async {
    final updated = state.artistPresets.map((p) {
      return p.name == oldName ? newPreset : p;
    }).toList();
    final nameChanged =
        oldName != newPreset.name && state.selectedArtistPresetName == oldName;
    await updateConfig(
      state.copyWith(
        artistPresets: updated,
        selectedArtistPresetName: nameChanged
            ? newPreset.name
            : state.selectedArtistPresetName,
      ),
    );
  }
}

/// TimeAwareness 插件配置 Provider
final timeAwarenessPluginConfigProvider =
    StateNotifierProvider<
      TimeAwarenessPluginConfigNotifier,
      TimeAwarenessConfig
    >((ref) => TimeAwarenessPluginConfigNotifier());

/// TimeAwareness 插件配置 Notifier
class TimeAwarenessPluginConfigNotifier
    extends StateNotifier<TimeAwarenessConfig> {
  static const _storageKey = 'aicove.plugins.time_awareness.config';

  TimeAwarenessPluginConfigNotifier() : super(TimeAwarenessConfig()) {
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = prefs.getString(_storageKey);

      if (json != null && json.isNotEmpty) {
        final data = jsonDecode(json) as Map<String, dynamic>;
        state = TimeAwarenessConfig.fromJson(data);
      }
    } catch (e) {
      print('[TimeAwarenessPluginConfigNotifier] Failed to load config: $e');
    }
  }

  Future<void> updateConfig(TimeAwarenessConfig config) async {
    state = config;
    await _saveConfig();
  }

  Future<void> _saveConfig() async {
    final data = jsonEncode(state.toJson());
    final prefs = await SharedPreferences.getInstance();
    if (!await cloudLocalWrite(() => prefs.setString(_storageKey, data))) {
      throw StateError('配置写入失败');
    }
  }

  Future<void> setIncludeMessageTimestamp(bool include) async {
    state = state.copyWith(includeMessageTimestamp: include);
    await _saveConfig();
  }

  Future<void> setIncludeCurrentTime(bool include) async {
    state = state.copyWith(includeCurrentTime: include);
    await _saveConfig();
  }

  Future<void> setCurrentTimePromptTemplate(String template) async {
    state = state.copyWith(currentTimePromptTemplate: template);
    await _saveConfig();
  }
}
