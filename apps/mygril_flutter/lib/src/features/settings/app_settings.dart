/// 应用设置 Provider
/// 
/// 更新记录：
/// - 2025-12-31: 提取数据模型到 settings_models.dart
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/message_formatter.dart';
import 'settings_models.dart';
import 'ui_models_api.dart';

// 重新导出模型类，保持向后兼容
export 'settings_models.dart';

// ===== 辅助类型和函数 =====

class _ModelMeta {
  final List<String> visible;
  final List<String> allKnown;
  final String defaultModel;
  final Map<String, String> providerMap;

  const _ModelMeta({
    required this.visible,
    required this.allKnown,
    required this.defaultModel,
    required this.providerMap,
  });
}

String _normalizeModelId(String modelId) => modelId.trim();

_ModelMeta _calculateModelMeta(
  List<ProviderAuth> providers, {
  List<String>? fallbackVisible,
  String? serverDefault,
}) {
  final visible = <String>[];
  final allKnown = <String>[];
  final providerMap = <String, String>{};

  for (final provider in providers) {
    for (final model in provider.models) {
      final id = _normalizeModelId(model);
      if (id.isEmpty) continue;
      if (!allKnown.contains(id)) {
        allKnown.add(id);
      }
      providerMap.putIfAbsent(id, () => provider.id);
    }
    for (final model in provider.visibleModels) {
      final id = _normalizeModelId(model);
      if (id.isEmpty) continue;
      if (!visible.contains(id)) {
        visible.add(id);
      }
    }
  }

  if (visible.isEmpty && fallbackVisible != null) {
    for (final model in fallbackVisible) {
      final id = _normalizeModelId(model);
      if (id.isNotEmpty && providerMap.containsKey(id) && !visible.contains(id)) {
        visible.add(id);
      }
    }
  }

  if (visible.isEmpty && allKnown.isNotEmpty) {
    visible.add(allKnown.first);
  }

  final defaultModel = () {
    final candidate = serverDefault?.trim();
    if (candidate != null && candidate.isNotEmpty && visible.contains(candidate)) {
      return candidate;
    }
    if (visible.isNotEmpty) return visible.first;
    if (allKnown.isNotEmpty) return allKnown.first;
    return 'deepseek-chat';
  }();

  return _ModelMeta(
    visible: visible,
    allKnown: allKnown,
    defaultModel: defaultModel,
    providerMap: providerMap,
  );
}

List<String> _cleanStrings(dynamic source) {
  final list = <String>[];
  if (source is Iterable) {
    for (final item in source) {
      final value = item?.toString().trim() ?? '';
      if (value.isNotEmpty && !list.contains(value)) {
        list.add(value);
      }
    }
  }
  return list;
}

List<String> _collectVisible(List<Map<String, dynamic>> providers) {
  final set = <String>{};
  for (final provider in providers) {
    if (provider['enabled'] == false) continue;
    final visible = _cleanStrings(provider['visible_models']);
    set.addAll(visible);
  }
  final list = set.toList()
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return list;
}

AppSettings _mapToSettings(Map<String, dynamic> data) {
  final providers = (data['providers'] as List? ?? const <dynamic>[])
      .whereType<Map>()
      .map((e) => ProviderAuth.fromJson(e.cast<String, dynamic>()))
      .toList();
  final fallbackVisible =
      (data['visible_models'] as List? ?? const <dynamic>[])
          .map((e) => e.toString())
          .toList();
  final displayNames =
      (data['model_display_names'] as Map? ?? const <String, dynamic>{})
          .map((key, value) => MapEntry(key.toString(), value?.toString() ?? ''));
  final meta = _calculateModelMeta(
    providers,
    fallbackVisible: fallbackVisible,
    serverDefault: data['default_model'] as String?,
  );

  final messageFormatConfig = data['message_format_config'] != null
      ? MessageFormatConfig.fromJson(data['message_format_config'] as Map<String, dynamic>)
      : const MessageFormatConfig();
  
  final messageFontSize = (data['message_font_size'] as num?)?.toDouble() ?? FontSize.large.size;
  final userAvatar = data['user_avatar'] as String?;
  final userName = data['user_name'] as String?;
  final autoReplySettings = data['auto_reply_settings'] is Map
      ? AutoReplySettings.fromJson(
          (data['auto_reply_settings'] as Map).cast<String, dynamic>(),
        )
      : const AutoReplySettings();
  final chatBackgroundColor = ChatBackgroundColor.fromValue(
    data['chat_background_color'] as String?,
  );
  final isDarkMode = (data['is_dark_mode'] as bool?) ?? false;
  final useSystemTheme = (data['use_system_theme'] as bool?) ?? true;

  return AppSettings(
    ttsEnabled: true,
    defaultModelName: meta.defaultModel,
    temperature: 0.7,
    defaultPersonaPrompt: '',
    modelList: meta.visible.isEmpty ? <String>['deepseek-chat'] : meta.visible,
    allKnownModels: meta.allKnown.isEmpty ? <String>['deepseek-chat'] : meta.allKnown,
    modelDisplayNames: displayNames,
    apiKey: '',
    apiBaseUrl: 'https://api.openai.com/v1',
    imageGenerationEnabled: false,
    maxFileUploadMB: 10,
    historyMessageLimit: 100,
    customModels: const <CustomModel>[],
    providers: providers,
    modelProviderMap: meta.providerMap,
    backendApiKey: (data['backend_api_key'] as String?) ?? '',
    messageChunkingEnabled: data['message_chunking_enabled'] == true,
    messageFormatConfig: messageFormatConfig,
    messageFontSize: messageFontSize,
    autoReplySettings: autoReplySettings,
    chatBackgroundColor: chatBackgroundColor,
    isDarkMode: isDarkMode,
    useSystemTheme: useSystemTheme,
    userAvatar: userAvatar,
    userName: userName,
  );
}

// ===== Provider 定义 =====

final appSettingsProvider =
    AsyncNotifierProvider<AppSettingsNotifier, AppSettings>(AppSettingsNotifier.new);

class AppSettingsNotifier extends AsyncNotifier<AppSettings> {
  UiModelsApi get _api => const UiModelsApi();

  @override
  Future<AppSettings> build() async {
    final data = await _api.fetchAll();
    return _mapToSettings(data);
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = AsyncData(await build());
  }

  Future<void> setDefaultModelName(String modelId) async {
    await _commit(() => _api.updatePartial({'default_model': modelId}));
  }

  Future<void> setModelDisplayName({
    required String modelId,
    required String? displayName,
  }) async {
    await _commit(() async {
      final data = await _api.fetchAll();
      final names =
          (data['model_display_names'] as Map? ?? const <String, dynamic>{})
              .map((key, value) => MapEntry(key.toString(), value?.toString() ?? ''));
      if (displayName == null || displayName.trim().isEmpty) {
        names.remove(modelId);
      } else {
        names[modelId] = displayName.trim();
      }
      return _api.updatePartial({'model_display_names': names});
    });
  }

  Future<void> setModelVisibility({
    required String providerId,
    required String modelId,
    required bool visible,
  }) async {
    await _commit(() async {
      final data = await _api.fetchAll();
      final providers = (data['providers'] as List)
          .cast<Map<String, dynamic>>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      final index = providers.indexWhere((p) => p['id'] == providerId);
      if (index < 0) return data;
      final provider = providers[index];
      final models = _cleanStrings(provider['models']);
      final visibleModels = _cleanStrings(provider['visible_models']);
      final hiddenModels = _cleanStrings(provider['hidden_models']);

      if (!models.contains(modelId)) {
        models.add(modelId);
      }
      if (visible) {
        if (!visibleModels.contains(modelId)) {
          visibleModels.add(modelId);
        }
        hiddenModels.removeWhere((m) => m == modelId);
      } else {
        visibleModels.removeWhere((m) => m == modelId);
        if (!hiddenModels.contains(modelId)) {
          hiddenModels.add(modelId);
        }
      }

      provider['models'] = models;
      provider['visible_models'] = visibleModels;
      provider['hidden_models'] = hiddenModels.where((m) => !visibleModels.contains(m)).toList();
      providers[index] = provider;

      return _api.updatePartial({
        'providers': providers,
        'visible_models': _collectVisible(providers),
      });
    });
  }

  Future<void> setProviderEnabled(String providerId, bool enabled) async {
    await _commit(() => _api.updateProvider(providerId: providerId, enabled: enabled));
  }

  Future<void> deleteProvider(String providerId) async {
    await _commit(() => _api.deleteProvider(providerId));
  }

  Future<void> editProvider({
    required String providerId,
    String? displayName,
    String? apiBaseUrl,
    List<String>? apiKeys,
    List<String>? capabilities,
    Map<String, dynamic>? customConfig,
    String? modelType,
  }) async {
    await _commit(() => _api.updateProvider(
          providerId: providerId,
          displayName: displayName,
          apiBaseUrl: apiBaseUrl,
          apiKeys: apiKeys,
          capabilities: capabilities,
          customConfig: customConfig,
          modelType: modelType,
        ));
  }

  Future<List<String>> previewProviderModels({
    required String providerId,
    required String apiKey,
    required String apiBaseUrl,
  }) {
    return _api.previewProvider(
      providerId: providerId,
      apiKey: apiKey,
      apiBaseUrl: apiBaseUrl,
    );
  }

  Future<void> importCustomModel({
    required String? name,
    required String apiKey,
    required String apiBaseUrl,
    required String provider,
    String? displayName,
    List<String>? visibleModels,
    List<String>? hiddenModels,
    List<String>? allModels,
    List<String>? capabilities,
    Map<String, dynamic>? customConfig,
    String? modelType,
  }) async {
    await _commit(() => _api.importProvider(
          providerId: provider,
          model: name,
          apiKey: apiKey,
          apiBaseUrl: apiBaseUrl,
          displayName: displayName,
          visibleModels: visibleModels,
          hiddenModels: hiddenModels,
          allModels: allModels,
          capabilities: capabilities,
          customConfig: customConfig,
          modelType: modelType,
        ));
  }

  Future<void> setMessageChunkingEnabled(bool value) async {
    await _commit(() => _api.updatePartial({'message_chunking_enabled': value}));
  }

  Future<void> setBackendApiKey(String key) async {
    await _commit(() => _api.updatePartial({'backend_api_key': key}));
  }

  Future<void> updateMessageFormatConfig(MessageFormatConfig config) async {
    await _commit(() => _api.updatePartial({'message_format_config': config.toJson()}));
  }

  Future<void> setMessageFontSize(double size) async {
    await _commit(() => _api.updatePartial({'message_font_size': size}));
  }

  Future<void> setUserAvatar(String? avatar) async {
    await _commit(() => _api.updatePartial({'user_avatar': avatar}));
  }

  Future<void> setUserName(String? name) async {
    await _commit(() => _api.updatePartial({'user_name': name}));
  }

  Future<void> updateAutoReplySettings(AutoReplySettings settings) async {
    await _commit(() => _api.updatePartial({'auto_reply_settings': settings.toJson()}));
  }

  Future<void> setChatBackgroundColor(ChatBackgroundColor color) async {
    await _commit(() => _api.updatePartial({'chat_background_color': color.value}));
  }

  Future<void> setDarkMode(bool isDark) async {
    await _commit(() => _api.updatePartial({'is_dark_mode': isDark}));
  }

  Future<void> setUseSystemTheme(bool useSystem) async {
    await _commit(() => _api.updatePartial({'use_system_theme': useSystem}));
  }

  /// 同时设置暗色模式和是否跟随系统（避免两次状态更新冲突）
  Future<void> setDarkModeAndSystemTheme({required bool isDark, required bool useSystem}) async {
    await _commit(() => _api.updatePartial({
      'is_dark_mode': isDark,
      'use_system_theme': useSystem,
    }));
  }

  Future<void> _commit(
    Future<Map<String, dynamic>> Function() mutation,
  ) async {
    try {
      final data = await mutation();
      state = AsyncData(_mapToSettings(data));
    } catch (err, stack) {
      state = AsyncError(err, stack);
      rethrow;
    }
  }
}
