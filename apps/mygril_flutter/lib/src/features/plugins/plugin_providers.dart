import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

import 'plugin_manager.dart';
import 'domain/plugin.dart';
import 'tts/tts_plugin.dart';
import 'tts/tts_config.dart';
import 'tts/tts_player_manager.dart';
import 'trigger/trigger_plugin.dart';
import 'trigger/trigger_config.dart';
import 'memory/memory_plugin.dart';
import 'memory/memory_config.dart';
import 'sticker/sticker_plugin.dart';
import 'sticker/sticker_config.dart';

/// 插件管理器 Provider
final pluginManagerProvider = Provider<PluginManager>((ref) {
  // 监听配置变化，并在变化时更新插件实例
  final ttsConfig = ref.watch(ttsPluginConfigProvider);
  final triggerConfig = ref.watch(triggerPluginConfigProvider);
  final memoryConfig = ref.watch(memoryPluginConfigProvider);
  final stickerConfig = ref.watch(stickerPluginConfigProvider);

  // 使用单例确保 PluginManager 不会重建，导致下游 Provider 拿不到更新
  _pluginManagerSingleton ??= PluginManager();
  _pluginManagerSingleton!.updatePlugin(TtsPlugin(ttsConfig));
  _pluginManagerSingleton!.updatePlugin(TriggerPlugin(triggerConfig, ref));
  _pluginManagerSingleton!.updatePlugin(MemoryPlugin(memoryConfig, ref));
  _pluginManagerSingleton!.updatePlugin(StickerPlugin(stickerConfig));

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
      requestUrl: '',
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

  Future<void> setApiKey(String? apiKey) async {
    state = state.copyWith(apiKey: apiKey);
    await _saveConfig();
  }

  Future<void> setRequestUrl(String url) async {
    state = state.copyWith(requestUrl: url);
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
}

/// TTS 播放器管理器 Provider（单例）
final ttsPlayerManagerProvider = Provider<TtsPlayerManager>((ref) {
  final ttsPlugin = ref.watch(pluginManagerProvider).getPlugin('tts') as TtsPlugin?;
  if (ttsPlugin == null) {
    throw StateError('TTS plugin not found');
  }

  // 使用静态单例，避免 ChatActions 拿到旧实例导致事件监听错位
  // 并在配置变化时更新其内部的 TtsService
  // ignore: prefer_const_constructors
  // 通过闭包静态变量保存实例
  // Dart 不支持文件级静态在函数内声明，这里用一个私有顶层变量见下方
  _ttsManagerSingleton ??= TtsPlayerManager(ttsPlugin.service);
  _ttsManagerSingleton!.updateService(ttsPlugin.service);
  return _ttsManagerSingleton!;
});

// 顶层单例存放
TtsPlayerManager? _ttsManagerSingleton;

/// TTS 播放状态 Provider
final ttsPlayStateProvider = StreamProvider<TtsPlayState>((ref) {
  final manager = ref.watch(ttsPlayerManagerProvider);
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

