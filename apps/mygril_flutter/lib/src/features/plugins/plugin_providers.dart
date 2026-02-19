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
import 'image/image_plugin.dart';
import 'image/image_config.dart';
import 'time_awareness/time_awareness_plugin.dart';
import 'time_awareness/time_awareness_config.dart';

String? _lastTtsProviderDiag;

/// 鎻掍欢绠＄悊鍣?Provider
final pluginManagerProvider = Provider<PluginManager>((ref) {
  // 鐩戝惉閰嶇疆鍙樺寲锛屽苟鍦ㄥ彉鍖栨椂鏇存柊鎻掍欢瀹炰緥
  final ttsConfig = ref.watch(ttsPluginConfigProvider);
  final triggerConfig = ref.watch(triggerPluginConfigProvider);
  final memoryConfig = ref.watch(memoryPluginConfigProvider);
  final stickerConfig = ref.watch(stickerPluginConfigProvider);
  final imageConfig = ref.watch(imagePluginConfigProvider);
  final timeAwarenessConfig = ref.watch(timeAwarenessPluginConfigProvider);

  // 浠?appSettingsProvider 鑾峰彇 TTS 娓犻亾閰嶇疆
  String? ttsApiKey;
  String ttsRequestUrl = '';
  String ttsRequestFormat = 'openai_tts';
  String? ttsSelectedModel;

  final appSettingsAsync = ref.watch(appSettingsProvider);
  appSettingsAsync.whenData((settings) {
    ProviderAuth? selectedProvider;

    if (ttsConfig.selectedProviderId != null) {
      // 鐜板湪閫氳繃妯″瀷绫诲瀷鏍囩閫夋嫨 TTS 妯″瀷锛屼笉鍐嶈姹傛笭閬撳叿鏈?'tts' capability
      selectedProvider = settings.providers
          .where(
            (p) => p.id == ttsConfig.selectedProviderId,
          )
          .firstOrNull;
      if (selectedProvider != null) {
        ttsApiKey = selectedProvider.apiKeys.isNotEmpty
            ? selectedProvider.apiKeys.first
            : null;
        ttsRequestUrl = selectedProvider.apiBaseUrl;
        ttsRequestFormat =
            selectedProvider.customConfig['requestFormat'] as String? ??
                'openai_tts';
        final modelId = ttsConfig.selectedModelId;
        if (modelId != null &&
            (selectedProvider.visibleModels.contains(modelId) ||
                selectedProvider.models.contains(modelId))) {
          ttsSelectedModel = modelId;
        }
      }
    }

    // 璇婃柇鏃ュ織锛氬憡璇変綘"瀵硅瘽閲屼负浠€涔堟病鏈夎蛋鍒拌闊虫彃浠?
    final diagKey =
        'enabled:${ttsConfig.enabled}|selected:${ttsConfig.selectedProviderId}|model:$ttsSelectedModel|found:${selectedProvider != null}|url:$ttsRequestUrl|fmt:$ttsRequestFormat';
    if (_lastTtsProviderDiag != diagKey) {
      _lastTtsProviderDiag = diagKey;
      // 绮剧畝妯″瀷鍒楄〃锛氬彧鏄剧ず鏁伴噺鍜屽綋鍓嶄娇鐢ㄧ殑妯″瀷
      final models = selectedProvider?.models ?? [];
      final modelsSummary =
          models.isEmpty ? '[]' : '鍏?{models.length}涓? 褰撳墠: $ttsSelectedModel';
      AppLogger.info('TTS', 'TTS 鎻掍欢閰嶇疆璇婃柇', metadata: {
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
        AppLogger.warning('TTS', 'TTS 鎻掍欢宸插惎鐢紝浣嗘湭閫夋嫨娓犻亾');
      } else if (selectedProvider == null) {
        AppLogger.warning('TTS', 'TTS 鎻掍欢宸插惎鐢紝浣嗘湭鎵惧埌瀵瑰簲娓犻亾', metadata: {
          'selectedProviderId': ttsConfig.selectedProviderId,
        });
      } else if (ttsRequestUrl.trim().isEmpty) {
        AppLogger.warning('TTS', 'TTS 鎻掍欢宸插惎鐢紝浣嗘笭閬?API 鍦板潃涓虹┖', metadata: {
          'selectedProviderId': ttsConfig.selectedProviderId,
        });
      } else if (ttsSelectedModel == null) {
        final availableCount = selectedProvider.models.length;
        AppLogger.warning('TTS', 'TTS 鎻掍欢宸插惎鐢紝浣嗘湭閫夋嫨妯″瀷', metadata: {
          'selectedProviderId': ttsConfig.selectedProviderId,
          'selectedModelId': ttsConfig.selectedModelId,
          'availableModelsCount': availableCount,
        });
      }
    }
  });

  // Keep PluginManager as singleton to avoid recreating plugin instances.
  _pluginManagerSingleton ??= PluginManager();
  _pluginManagerSingleton!.updatePlugin(
    TtsPlugin(
      ttsConfig,
      apiKey: ttsApiKey,
      requestUrl: ttsRequestUrl,
      requestFormat: ttsRequestFormat,
      selectedModel: ttsSelectedModel,
      onVoiceCreated: (updatedPreset) async {
        await ref
            .read(ttsPluginConfigProvider.notifier)
            .updateVoicePreset(updatedPreset);
        AppLogger.info('TTS', 'Voice preset persisted', metadata: {
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
  _pluginManagerSingleton!.updatePlugin(ImagePlugin(imageConfig, ref));
  _pluginManagerSingleton!
      .updatePlugin(TimeAwarenessPlugin(timeAwarenessConfig));

  return _pluginManagerSingleton!;
});

/// Memory 鎻掍欢閰嶇疆 Provider
final memoryPluginConfigProvider =
    StateNotifierProvider<MemoryPluginConfigNotifier, MemoryConfig>(
  (ref) => MemoryPluginConfigNotifier(),
);

/// Memory 鎻掍欢閰嶇疆 Notifier
class MemoryPluginConfigNotifier extends StateNotifier<MemoryConfig> {
  static const _storageKey = 'aicove.plugins.memory.config';

  MemoryPluginConfigNotifier() : super(const MemoryConfig()) {
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

  Future<void> setEnabled(bool enabled) async {
    state = state.copyWith(enabled: enabled);
    await _saveConfig();
  }

  Future<void> setSummarizeModel(String? providerId, String? modelName) async {
    state = state.copyWith(
      summarizeProviderId: providerId,
      summarizeModelName: modelName,
    );
    await _saveConfig();
  }

  Future<void> setEmbeddingModel(String? providerId, String? modelName) async {
    state = state.copyWith(
      embeddingProviderId: providerId,
      embeddingModelName: modelName,
    );
    await _saveConfig();
  }

  Future<void> setFallbackEmbeddingModel(
      bool enabled, String? providerId, String? modelName) async {
    state = state.copyWith(
      fallbackEmbeddingEnabled: enabled,
      fallbackEmbeddingProviderId: providerId,
      fallbackEmbeddingModelName: modelName,
    );
    await _saveConfig();
  }

  Future<void> setRoundSplitThreshold(int value) async {
    state = state.copyWith(roundSplitThreshold: value.clamp(5, 200));
    await _saveConfig();
  }
}

// PluginManager 鍗曚緥
PluginManager? _pluginManagerSingleton;

/// TTS 鎻掍欢閰嶇疆 Provider
final ttsPluginConfigProvider =
    StateNotifierProvider<TtsPluginConfigNotifier, TtsConfig>(
  (ref) => TtsPluginConfigNotifier(),
);

/// TTS 鎻掍欢閰嶇疆 Notifier
class TtsPluginConfigNotifier extends StateNotifier<TtsConfig> {
  static const _storageKey = 'aicove.plugins.tts.config';

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

  /// 璁剧疆閫変腑鐨?TTS 娓犻亾
  Future<void> setSelectedProvider(String? providerId) async {
    state = state.copyWith(selectedProviderId: providerId);
    await _saveConfig();
  }

  /// 璁剧疆閫変腑鐨?TTS 妯″瀷
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

  /// Set emotion text (IndexTTS-2).
  Future<void> setEmoText({String? emoText, bool? useEmoText}) async {
    state = state.copyWith(
      emoText: emoText,
      useEmoText: useEmoText,
    );
    await _saveConfig();
  }

  /// 璁剧疆璇煶浣跨敤棰戠巼 (0-100)
  Future<void> setVoiceFrequency(int frequency) async {
    state = state.copyWith(voiceFrequency: frequency.clamp(0, 100));
    await _saveConfig();
  }

  /// 娣诲姞闊宠壊棰勮
  Future<void> addVoicePreset(VoicePreset preset) async {
    final newPresets = [...state.voicePresets, preset];
    state = state.copyWith(voicePresets: newPresets);
    await _saveConfig();
  }

  /// 鏇存柊闊宠壊棰勮
  Future<void> updateVoicePreset(VoicePreset preset) async {
    AppLogger.info('TTS', '鏇存柊闊宠壊棰勮', metadata: {
      'presetId': preset.id,
      'presetName': preset.name,
      'aliyunVoiceId': preset.aliyunVoiceId,
      'existingPresetIds': state.voicePresets.map((p) => p.id).toList(),
    });

    final newPresets = state.voicePresets.map((p) {
      if (p.id == preset.id) {
        AppLogger.info('TTS', 'Matched voice preset, updating', metadata: {
          'oldAliyunVoiceId': p.aliyunVoiceId,
          'newAliyunVoiceId': preset.aliyunVoiceId,
        });
        return preset;
      }
      return p;
    }).toList();

    final matched = newPresets.any(
        (p) => p.id == preset.id && p.aliyunVoiceId == preset.aliyunVoiceId);
    if (!matched) {
      AppLogger.warning('TTS', 'No matching voice preset found during update',
          metadata: {
            'presetId': preset.id,
          });
    }

    state = state.copyWith(voicePresets: newPresets);
    await _saveConfig();
  }

  /// 鍒犻櫎闊宠壊棰勮
  Future<void> deleteVoicePreset(String presetId) async {
    final newPresets =
        state.voicePresets.where((p) => p.id != presetId).toList();
    // 濡傛灉鍒犻櫎鐨勬槸褰撳墠閫変腑鐨勯煶鑹诧紝娓呯┖閫夋嫨
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

  /// 閫夋嫨闊宠壊棰勮
  Future<void> selectVoicePreset(String? presetId) async {
    state = state.copyWith(selectedVoicePresetId: presetId);
    await _saveConfig();
  }

  /// 鎵归噺娣诲姞闊宠壊棰勮锛堢敤浜庝粠娓犻亾鍟嗚幏鍙栭缃煶鑹诧級
  Future<void> addVoicePresets(List<VoicePreset> presets) async {
    // Filter out already existing presets by id.
    final existingIds = state.voicePresets.map((p) => p.id).toSet();
    final newPresets =
        presets.where((p) => !existingIds.contains(p.id)).toList();
    if (newPresets.isEmpty) return;

    final allPresets = [...state.voicePresets, ...newPresets];
    state = state.copyWith(voicePresets: allPresets);
    await _saveConfig();
  }
}

/// TTS 鎾斁鍣ㄧ鐞嗗櫒 Provider锛堝崟渚嬶級
/// 娉ㄦ剰锛氬鏋?TTS 鎻掍欢涓嶅瓨鍦紝杩斿洖 null 鑰屼笉鏄姏寮傚父锛岀‘淇濊В鑰﹀悎
final ttsPlayerManagerProvider = Provider<TtsPlayerManager?>((ref) {
  final pluginManager = ref.watch(pluginManagerProvider);
  final ttsPlugin = pluginManager.getPlugin('tts') as TtsPlugin?;
  if (ttsPlugin == null) {
    // Do not throw when plugin is absent.
    return null;
  }

  // 鍒涘缓 TtsService 鑾峰彇鍣紝姣忔璋冪敤鏃朵粠 PluginManager 鑾峰彇鏈€鏂扮殑 TtsPlugin.service
  // 杩欐牱鍙互纭繚鍗充娇 Provider 鍙 read 涓€娆★紝涔熻兘鑾峰彇鍒版渶鏂扮殑閰嶇疆
  TtsService? getLatestTtsService() {
    final currentPlugin = pluginManager.getPlugin('tts') as TtsPlugin?;
    final service = currentPlugin?.service;

    AppLogger.debug('TTS', 'getLatestTtsService invoked', metadata: {
      'pluginExists': currentPlugin != null,
      'serviceUrl': service?.requestUrl ?? '',
      'serviceModel': service?.model,
      'hasApiKey': service?.apiKey?.isNotEmpty == true,
    });

    return service;
  }

  // Use singleton manager and refresh getter each rebuild.
  if (_ttsManagerSingleton == null) {
    _ttsManagerSingleton = TtsPlayerManager(getLatestTtsService);
    AppLogger.info('TTS', 'TtsPlayerManager 鍗曚緥鍒涘缓');
  } else {
    _ttsManagerSingleton!.updateServiceGetter(getLatestTtsService);
    AppLogger.debug('TTS', 'TtsPlayerManager 鏈嶅姟鑾峰彇鍣ㄥ凡鏇存柊');
  }

  return _ttsManagerSingleton!;
});

// 椤跺眰鍗曚緥瀛樻斁
TtsPlayerManager? _ttsManagerSingleton;

/// TTS 鎾斁鐘舵€?Provider
final ttsPlayStateProvider = StreamProvider<TtsPlayState>((ref) {
  final manager = ref.watch(ttsPlayerManagerProvider);
  if (manager == null) {
    // TTS 鎻掍欢涓嶅瓨鍦紝杩斿洖绌烘祦
    return Stream.value(TtsPlayState.idle);
  }
  return manager.playStateStream;
});

/// Trigger 鎻掍欢閰嶇疆 Provider
final triggerPluginConfigProvider =
    StateNotifierProvider<TriggerPluginConfigNotifier, TriggerConfig>(
  (ref) => TriggerPluginConfigNotifier(),
);

/// Trigger 鎻掍欢閰嶇疆 Notifier
class TriggerPluginConfigNotifier extends StateNotifier<TriggerConfig> {
  static const _storageKey = 'aicove.plugins.trigger.config';

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

/// Sticker 鎻掍欢閰嶇疆 Provider
final stickerPluginConfigProvider =
    StateNotifierProvider<StickerPluginConfigNotifier, StickerConfig>(
  (ref) => StickerPluginConfigNotifier(),
);

/// Sticker 鎻掍欢閰嶇疆 Notifier
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

/// Image 鎻掍欢閰嶇疆 Provider
final imagePluginConfigProvider =
    StateNotifierProvider<ImagePluginConfigNotifier, ImageConfig>(
  (ref) => ImagePluginConfigNotifier(),
);

/// Image 鎻掍欢閰嶇疆 Notifier
class ImagePluginConfigNotifier extends StateNotifier<ImageConfig> {
  static const _storageKey = 'aicove.plugins.image.config';

  ImagePluginConfigNotifier() : super(const ImageConfig()) {
    _loadConfig();
  }

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
    state = config;
    await _saveConfig();
  }

  Future<void> _saveConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_storageKey, jsonEncode(state.toJson()));
    } catch (e) {
      print('[ImagePluginConfigNotifier] Failed to save config: $e');
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
}

/// TimeAwareness 鎻掍欢閰嶇疆 Provider
final timeAwarenessPluginConfigProvider = StateNotifierProvider<
    TimeAwarenessPluginConfigNotifier, TimeAwarenessConfig>(
  (ref) => TimeAwarenessPluginConfigNotifier(),
);

/// TimeAwareness 鎻掍欢閰嶇疆 Notifier
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
