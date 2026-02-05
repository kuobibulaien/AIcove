// ignore_for_file: avoid_print
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

import '../../core/app_logger.dart';
import '../settings/app_settings.dart';
import 'plugin_manager.dart';
import 'tts/tts_plugin.dart';
import 'tts/tts_config.dart';
import 'tts/tts_player_manager.dart';
import 'tts/tts_service.dart';
import 'trigger/trigger_plugin.dart';
import 'trigger/trigger_config.dart';
import 'memory/memory_plugin.dart';
import 'memory/memory_config.dart';
import 'sticker/sticker_plugin.dart';
import 'sticker/sticker_config.dart';
import 'time_awareness/time_awareness_plugin.dart';
import 'time_awareness/time_awareness_config.dart';

String? _lastTtsProviderDiag;

/// 插件管理器 Provider
final pluginManagerProvider = Provider<PluginManager>((ref) {
  // 监听配置变化，并在变化时更新插件实例
  final ttsConfig = ref.watch(ttsPluginConfigProvider);
  final triggerConfig = ref.watch(triggerPluginConfigProvider);
  final memoryConfig = ref.watch(memoryPluginConfigProvider);
  final stickerConfig = ref.watch(stickerPluginConfigProvider);
  final timeAwarenessConfig = ref.watch(timeAwarenessPluginConfigProvider);

  // 从 appSettingsProvider 获取 TTS 渠道配置
  String? ttsApiKey;
  String ttsRequestUrl = '';
  String ttsRequestFormat = 'openai_tts';
  String? ttsSelectedModel;

  final appSettingsAsync = ref.watch(appSettingsProvider);
  appSettingsAsync.whenData((settings) {
    ProviderAuth? selectedProvider;

    if (ttsConfig.selectedProviderId != null) {
      // 现在通过模型类型标签选择 TTS 模型，不再要求渠道具有 'tts' capability
      selectedProvider = settings.providers.where(
        (p) => p.id == ttsConfig.selectedProviderId,
      ).firstOrNull;
      if (selectedProvider != null) {
        ttsApiKey =
            selectedProvider.apiKeys.isNotEmpty ? selectedProvider.apiKeys.first : null;
        ttsRequestUrl = selectedProvider.apiBaseUrl;
        ttsRequestFormat =
            selectedProvider.customConfig['requestFormat'] as String? ?? 'openai_tts';

        // 获取选中的模型（校验是否在渠道的可见模型或全部模型中）
        final modelId = ttsConfig.selectedModelId;
        if (modelId != null &&
            (selectedProvider.visibleModels.contains(modelId) ||
             selectedProvider.models.contains(modelId))) {
          ttsSelectedModel = modelId;
        }
      }
    }

    // 诊断日志：告诉你"对话里为什么没有走到语音插件"
    final diagKey =
        'enabled:${ttsConfig.enabled}|selected:${ttsConfig.selectedProviderId}|model:$ttsSelectedModel|found:${selectedProvider != null}|url:$ttsRequestUrl|fmt:$ttsRequestFormat';
    if (_lastTtsProviderDiag != diagKey) {
      _lastTtsProviderDiag = diagKey;
      // 精简模型列表：只显示数量和当前使用的模型
      final models = selectedProvider?.models ?? [];
      final modelsSummary = models.isEmpty
          ? '[]'
          : '共${models.length}个, 当前: $ttsSelectedModel';
      AppLogger.info('TTS', 'TTS 插件配置诊断', metadata: {
        'pluginEnabled': ttsConfig.enabled,
        'selectedProviderId': ttsConfig.selectedProviderId,
        'selectedModelId': ttsConfig.selectedModelId,
        'effectiveModel': ttsSelectedModel,
        'providerFound': selectedProvider != null,
        'providerEnabled': selectedProvider?.enabled,
        'providerModelType': selectedProvider?.modelType,
        'providerApiBaseUrl': selectedProvider?.apiBaseUrl,
        'providerModels': modelsSummary,
        'requestFormat': ttsRequestFormat,
        'hasApiKey': (selectedProvider?.apiKeys.isNotEmpty ?? false),
      });
    }

    if (ttsConfig.enabled) {
      if (ttsConfig.selectedProviderId == null ||
          ttsConfig.selectedProviderId!.trim().isEmpty) {
        AppLogger.warning('TTS', 'TTS 插件已启用，但未选择渠道');
      } else if (selectedProvider == null) {
        AppLogger.warning('TTS', 'TTS 插件已启用，但未找到对应渠道', metadata: {
          'selectedProviderId': ttsConfig.selectedProviderId,
        });
      } else if (ttsRequestUrl.trim().isEmpty) {
        AppLogger.warning('TTS', 'TTS 插件已启用，但渠道 API 地址为空', metadata: {
          'selectedProviderId': ttsConfig.selectedProviderId,
        });
      } else if (ttsSelectedModel == null) {
        final availableCount = selectedProvider?.models.length ?? 0;
        AppLogger.warning('TTS', 'TTS 插件已启用，但未选择模型', metadata: {
          'selectedProviderId': ttsConfig.selectedProviderId,
          'selectedModelId': ttsConfig.selectedModelId,
          'availableModelsCount': availableCount,
        });
      }
    }
  });

  // 使用单例确保 PluginManager 不会重建，导致下游 Provider 拿不到更新
  _pluginManagerSingleton ??= PluginManager();
  _pluginManagerSingleton!.updatePlugin(
    TtsPlugin(
      ttsConfig,
      apiKey: ttsApiKey,
      requestUrl: ttsRequestUrl,
      requestFormat: ttsRequestFormat,
      selectedModel: ttsSelectedModel,
      onVoiceCreated: (updatedPreset) async {
        // 当音色 ID 创建成功后，更新配置
        ref.read(ttsPluginConfigProvider.notifier).updateVoicePreset(updatedPreset);
        AppLogger.info('TTS', '音色 ID 已保存', metadata: {
          'presetId': updatedPreset.id,
          'presetName': updatedPreset.name,
          'aliyunVoiceId': updatedPreset.aliyunVoiceId,
        });
      },
    ),
  );
  _pluginManagerSingleton!.updatePlugin(TriggerPlugin(triggerConfig, ref));
  _pluginManagerSingleton!.updatePlugin(MemoryPlugin(memoryConfig, ref));
  _pluginManagerSingleton!.updatePlugin(StickerPlugin(stickerConfig));
  _pluginManagerSingleton!.updatePlugin(TimeAwarenessPlugin(timeAwarenessConfig));

  return _pluginManagerSingleton!;
});



/// Memory 插件配置 Provider
final memoryPluginConfigProvider = StateNotifierProvider<MemoryPluginConfigNotifier, MemoryConfig>(
  (ref) => MemoryPluginConfigNotifier(),
);

/// Memory 插件配置 Notifier
class MemoryPluginConfigNotifier extends StateNotifier<MemoryConfig> {
  static const _storageKey = 'mygril.plugins.memory.config';

  MemoryPluginConfigNotifier() : super(MemoryConfig()) {
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = prefs.getString(_storageKey);

      if (json != null && json.isNotEmpty) {
        final data = jsonDecode(json) as Map<String, dynamic>;
        state = MemoryConfig.fromJson(data);
      }
    } catch (e) {
      print('[MemoryPluginConfigNotifier] Failed to load config: $e');
    }
  }

  Future<void> updateConfig(MemoryConfig config) async {
    state = config;
    await _saveConfig();
  }

  Future<void> _saveConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_storageKey, jsonEncode(state.toJson()));
    } catch (e) {
      print('[MemoryPluginConfigNotifier] Failed to save config: $e');
    }
  }

  /// 设置启用状态
  Future<void> setEnabled(bool enabled) async {
    state = MemoryConfig(
      enabled: enabled,
      summarizeProviderId: state.summarizeProviderId,
      summarizeModelName: state.summarizeModelName,
      summarizePrompt: state.summarizePrompt,
      embeddingProviderId: state.embeddingProviderId,
      embeddingModelName: state.embeddingModelName,
      fallbackEmbeddingEnabled: state.fallbackEmbeddingEnabled,
      fallbackEmbeddingProviderId: state.fallbackEmbeddingProviderId,
      fallbackEmbeddingModelName: state.fallbackEmbeddingModelName,
      triggerInterval: state.triggerInterval,
    );
    await _saveConfig();
  }

  /// 设置摘要模型
  Future<void> setSummarizeModel(String? providerId, String? modelName) async {
    state = MemoryConfig(
      enabled: state.enabled,
      summarizeProviderId: providerId,
      summarizeModelName: modelName,
      summarizePrompt: state.summarizePrompt,
      embeddingProviderId: state.embeddingProviderId,
      embeddingModelName: state.embeddingModelName,
      fallbackEmbeddingEnabled: state.fallbackEmbeddingEnabled,
      fallbackEmbeddingProviderId: state.fallbackEmbeddingProviderId,
      fallbackEmbeddingModelName: state.fallbackEmbeddingModelName,
      triggerInterval: state.triggerInterval,
    );
    await _saveConfig();
  }

  /// 设置主嵌入模型
  Future<void> setEmbeddingModel(String? providerId, String? modelName) async {
    state = MemoryConfig(
      enabled: state.enabled,
      summarizeProviderId: state.summarizeProviderId,
      summarizeModelName: state.summarizeModelName,
      summarizePrompt: state.summarizePrompt,
      embeddingProviderId: providerId,
      embeddingModelName: modelName,
      fallbackEmbeddingEnabled: state.fallbackEmbeddingEnabled,
      fallbackEmbeddingProviderId: state.fallbackEmbeddingProviderId,
      fallbackEmbeddingModelName: state.fallbackEmbeddingModelName,
      triggerInterval: state.triggerInterval,
    );
    await _saveConfig();
  }

  /// 设置备用嵌入模型
  Future<void> setFallbackEmbeddingModel(bool enabled, String? providerId, String? modelName) async {
    state = MemoryConfig(
      enabled: state.enabled,
      summarizeProviderId: state.summarizeProviderId,
      summarizeModelName: state.summarizeModelName,
      summarizePrompt: state.summarizePrompt,
      embeddingProviderId: state.embeddingProviderId,
      embeddingModelName: state.embeddingModelName,
      fallbackEmbeddingEnabled: enabled,
      fallbackEmbeddingProviderId: providerId,
      fallbackEmbeddingModelName: modelName,
      triggerInterval: state.triggerInterval,
    );
    await _saveConfig();
  }
}


// PluginManager 单例
PluginManager? _pluginManagerSingleton;

/// TTS 插件配置 Provider
final ttsPluginConfigProvider = StateNotifierProvider<TtsPluginConfigNotifier, TtsConfig>(
  (ref) => TtsPluginConfigNotifier(),
);

/// TTS 插件配置 Notifier
class TtsPluginConfigNotifier extends StateNotifier<TtsConfig> {
  static const _storageKey = 'mygril.plugins.tts.config';

  TtsPluginConfigNotifier() : super(_defaultConfig()) {
    _loadConfig();
  }

  static TtsConfig _defaultConfig() {
    return TtsConfig(
      enabled: false,
    );
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
      print('[TtsPluginConfigNotifier] Failed to load config: $e');
    }
  }

  Future<void> updateConfig(TtsConfig config) async {
    state = config;
    await _saveConfig();
  }

  Future<void> _saveConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_storageKey, jsonEncode(state.toJson()));
    } catch (e) {
      print('[TtsPluginConfigNotifier] Failed to save config: $e');
    }
  }

  Future<void> setEnabled(bool enabled) async {
    state = state.copyWith(enabled: enabled);
    await _saveConfig();
  }

  /// 设置选中的 TTS 渠道
  Future<void> setSelectedProvider(String? providerId) async {
    state = state.copyWith(selectedProviderId: providerId);
    await _saveConfig();
  }

  /// 设置选中的 TTS 模型
  Future<void> setSelectedModel(String? modelId) async {
    state = state.copyWith(selectedModelId: modelId);
    await _saveConfig();
  }

  Future<void> setPromptAudio({String? audioUrl, String? text}) async {
    state = state.copyWith(
      promptAudioUrl: audioUrl,
      promptText: text,
    );
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

  /// 设置情感文本（IndexTTS-2 专用）
  Future<void> setEmoText({String? emoText, bool? useEmoText}) async {
    state = state.copyWith(
      emoText: emoText,
      useEmoText: useEmoText,
    );
    await _saveConfig();
  }

  /// 设置语音使用频率 (0-100)
  Future<void> setVoiceFrequency(int frequency) async {
    state = state.copyWith(voiceFrequency: frequency.clamp(0, 100));
    await _saveConfig();
  }

  /// 添加音色预设
  Future<void> addVoicePreset(VoicePreset preset) async {
    final newPresets = [...state.voicePresets, preset];
    state = state.copyWith(voicePresets: newPresets);
    await _saveConfig();
  }

  /// 更新音色预设
  Future<void> updateVoicePreset(VoicePreset preset) async {
    AppLogger.info('TTS', '更新音色预设', metadata: {
      'presetId': preset.id,
      'presetName': preset.name,
      'aliyunVoiceId': preset.aliyunVoiceId,
      'existingPresetIds': state.voicePresets.map((p) => p.id).toList(),
    });

    final newPresets = state.voicePresets.map((p) {
      if (p.id == preset.id) {
        AppLogger.info('TTS', '找到匹配的音色预设，更新中', metadata: {
          'oldAliyunVoiceId': p.aliyunVoiceId,
          'newAliyunVoiceId': preset.aliyunVoiceId,
        });
        return preset;
      }
      return p;
    }).toList();

    final matched = newPresets.any((p) => p.id == preset.id && p.aliyunVoiceId == preset.aliyunVoiceId);
    if (!matched) {
      AppLogger.warning('TTS', '未找到匹配的音色预设，更新失败', metadata: {
        'presetId': preset.id,
      });
    }

    state = state.copyWith(voicePresets: newPresets);
    await _saveConfig();
  }

  /// 删除音色预设
  Future<void> deleteVoicePreset(String presetId) async {
    final newPresets = state.voicePresets.where((p) => p.id != presetId).toList();
    // 如果删除的是当前选中的音色，清空选择
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

  /// 选择音色预设
  Future<void> selectVoicePreset(String? presetId) async {
    state = state.copyWith(selectedVoicePresetId: presetId);
    await _saveConfig();
  }

  /// 批量添加音色预设（用于从渠道商获取预置音色）
  Future<void> addVoicePresets(List<VoicePreset> presets) async {
    // 过滤掉已存在的音色（根据 id 判断）
    final existingIds = state.voicePresets.map((p) => p.id).toSet();
    final newPresets = presets.where((p) => !existingIds.contains(p.id)).toList();
    if (newPresets.isEmpty) return;

    final allPresets = [...state.voicePresets, ...newPresets];
    state = state.copyWith(voicePresets: allPresets);
    await _saveConfig();
  }
}

/// TTS 播放器管理器 Provider（单例）
/// 注意：如果 TTS 插件不存在，返回 null 而不是抛异常，确保解耦合
final ttsPlayerManagerProvider = Provider<TtsPlayerManager?>((ref) {
  final pluginManager = ref.watch(pluginManagerProvider);
  final ttsPlugin = pluginManager.getPlugin('tts') as TtsPlugin?;
  if (ttsPlugin == null) {
    // 不抛异常，返回 null，让调用方自行处理
    return null;
  }

  // 创建 TtsService 获取器，每次调用时从 PluginManager 获取最新的 TtsPlugin.service
  // 这样可以确保即使 Provider 只被 read 一次，也能获取到最新的配置
  TtsService? getLatestTtsService() {
    final currentPlugin = pluginManager.getPlugin('tts') as TtsPlugin?;
    final service = currentPlugin?.service;

    // 调试日志
    AppLogger.debug('TTS', 'getLatestTtsService 被调用', metadata: {
      'pluginExists': currentPlugin != null,
      'serviceUrl': service?.requestUrl ?? '',
      'serviceModel': service?.model,
      'hasApiKey': service?.apiKey?.isNotEmpty == true,
    });

    return service;
  }

  // 使用静态单例，避免 ChatActions 拿到旧实例导致事件监听错位
  if (_ttsManagerSingleton == null) {
    _ttsManagerSingleton = TtsPlayerManager(getLatestTtsService);
    AppLogger.info('TTS', 'TtsPlayerManager 单例创建');
  } else {
    _ttsManagerSingleton!.updateServiceGetter(getLatestTtsService);
    AppLogger.debug('TTS', 'TtsPlayerManager 服务获取器已更新');
  }

  return _ttsManagerSingleton!;
});

// 顶层单例存放
TtsPlayerManager? _ttsManagerSingleton;

/// TTS 播放状态 Provider
final ttsPlayStateProvider = StreamProvider<TtsPlayState>((ref) {
  final manager = ref.watch(ttsPlayerManagerProvider);
  if (manager == null) {
    // TTS 插件不存在，返回空流
    return Stream.value(TtsPlayState.idle);
  }
  return manager.playStateStream;
});

/// Trigger 插件配置 Provider
final triggerPluginConfigProvider = StateNotifierProvider<TriggerPluginConfigNotifier, TriggerConfig>(
  (ref) => TriggerPluginConfigNotifier(),
);

/// Trigger 插件配置 Notifier
class TriggerPluginConfigNotifier extends StateNotifier<TriggerConfig> {
  static const _storageKey = 'mygril.plugins.trigger.config';

  TriggerPluginConfigNotifier() : super(const TriggerConfig()) {
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = prefs.getString(_storageKey);

      if (json != null && json.isNotEmpty) {
        final data = jsonDecode(json) as Map<String, dynamic>;
        state = TriggerConfig.fromJson(data);
      }
    } catch (e) {
      print('[TriggerPluginConfigNotifier] Failed to load config: $e');
    }
  }

  Future<void> setEnabled(bool enabled) async {
    state = state.copyWith(enabled: enabled);
    await _saveConfig();
  }

  Future<void> _saveConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_storageKey, jsonEncode(state.toJson()));
    } catch (e) {
      print('[TriggerPluginConfigNotifier] Failed to save config: $e');
    }
  }
}

/// Sticker 插件配置 Provider
final stickerPluginConfigProvider = StateNotifierProvider<StickerPluginConfigNotifier, StickerConfig>(
  (ref) => StickerPluginConfigNotifier(),
);

/// Sticker 插件配置 Notifier
class StickerPluginConfigNotifier extends StateNotifier<StickerConfig> {
  static const _storageKey = 'mygril.plugins.sticker.config';

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

  Future<void> setEnabled(bool enabled) async {
    state = state.copyWith(enabled: enabled);
    await _saveConfig();
  }

  Future<void> _saveConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_storageKey, jsonEncode(state.toJson()));
    } catch (e) {
      print('[StickerPluginConfigNotifier] Failed to save config: $e');
    }
  }
}

/// TimeAwareness 插件配置 Provider
final timeAwarenessPluginConfigProvider = StateNotifierProvider<TimeAwarenessPluginConfigNotifier, TimeAwarenessConfig>(
  (ref) => TimeAwarenessPluginConfigNotifier(),
);

/// TimeAwareness 插件配置 Notifier
class TimeAwarenessPluginConfigNotifier extends StateNotifier<TimeAwarenessConfig> {
  static const _storageKey = 'mygril.plugins.time_awareness.config';

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
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_storageKey, jsonEncode(state.toJson()));
    } catch (e) {
      print('[TimeAwarenessPluginConfigNotifier] Failed to save config: $e');
    }
  }

  Future<void> setEnabled(bool enabled) async {
    state = state.copyWith(enabled: enabled);
    await _saveConfig();
  }

  Future<void> setIncludeMessageTimestamp(bool include) async {
    state = state.copyWith(includeMessageTimestamp: include);
    await _saveConfig();
  }

  Future<void> setIncludeCurrentTime(bool include) async {
    state = state.copyWith(includeCurrentTime: include);
    await _saveConfig();
  }
}
