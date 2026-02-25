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

String _buildProviderModelRef(String providerId, String modelId) =>
    '${providerId.trim()}:${modelId.trim()}';

String _normalizeStoredModelRef(
  String modelRef, {
  required Map<String, String> providerMap,
  required Set<String> providerIds,
}) {
  final ref = modelRef.trim();
  if (ref.isEmpty) return ref;

  final idx = ref.indexOf(':');
  if (idx > 0 && idx < ref.length - 1) {
    final providerId = ref.substring(0, idx).trim();
    final modelId = ref.substring(idx + 1).trim();
    if (providerIds.contains(providerId) && modelId.isNotEmpty) {
      return _buildProviderModelRef(providerId, modelId);
    }
  }

  final providerId = providerMap[ref];
  if (providerId == null || providerId.isEmpty) {
    return ref;
  }
  return _buildProviderModelRef(providerId, ref);
}

/// 将旧枚举值迁移为十六进制颜色值
String _migrateAccentColor(String value) {
  const legacyMap = {
    'pink': 'FC96AA',
    'blue': '4A90E2',
    'mint': '4ECDC4',
    'lavender': 'B39DDB',
    'coral': 'FF8A65',
  };
  return legacyMap[value] ?? value;
}

_ModelMeta _calculateModelMeta(
  List<ProviderAuth> providers, {
  List<String>? fallbackVisible,
  String? serverDefault,
}) {
  final visible = <String>[];
  final allKnown = <String>[];
  final providerMap = <String, String>{};
  final providerIds = <String>{};

  for (final provider in providers) {
    // 只收集 chat 类型的 provider 的模型到对话模型列表
    if (provider.modelType != 'chat') continue;
    providerIds.add(provider.id);
    for (final model in provider.models) {
      final id = _normalizeModelId(model);
      if (id.isEmpty) continue;
      final modelRef = _buildProviderModelRef(provider.id, id);
      if (!allKnown.contains(modelRef)) {
        allKnown.add(modelRef);
      }
      providerMap[modelRef] = provider.id;
      providerMap.putIfAbsent(id, () => provider.id);
    }
    for (final model in provider.visibleModels) {
      final id = _normalizeModelId(model);
      if (id.isEmpty) continue;
      final modelRef = _buildProviderModelRef(provider.id, id);
      if (!visible.contains(modelRef)) {
        visible.add(modelRef);
      }
      if (!allKnown.contains(modelRef)) {
        allKnown.add(modelRef);
      }
      providerMap[modelRef] = provider.id;
      providerMap.putIfAbsent(id, () => provider.id);
    }
  }

  if (visible.isEmpty && fallbackVisible != null) {
    for (final model in fallbackVisible) {
      final modelRef = _normalizeStoredModelRef(
        model,
        providerMap: providerMap,
        providerIds: providerIds,
      );
      if (modelRef.isNotEmpty &&
          providerMap.containsKey(modelRef) &&
          !visible.contains(modelRef)) {
        visible.add(modelRef);
      }
    }
  }

  if (visible.isEmpty && allKnown.isNotEmpty) {
    visible.add(allKnown.first);
  }

  final defaultModel = () {
    final candidate = serverDefault == null
        ? null
        : _normalizeStoredModelRef(
            serverDefault,
            providerMap: providerMap,
            providerIds: providerIds,
          );
    if (candidate != null &&
        candidate.isNotEmpty &&
        visible.contains(candidate)) {
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
  final fallbackVisible = (data['visible_models'] as List? ?? const <dynamic>[])
      .map((e) => e.toString())
      .toList();
  final displayNames = (data['model_display_names'] as Map? ??
          const <String, dynamic>{})
      .map((key, value) => MapEntry(key.toString(), value?.toString() ?? ''));
  final modelTypes = (data['model_types'] as Map? ?? const <String, dynamic>{})
      .map((key, value) => MapEntry(key.toString(), value?.toString() ?? ''));
  // 解析模型级别配置
  final modelConfigsRaw =
      data['model_configs'] as Map? ?? const <String, dynamic>{};
  final modelConfigs = <String, ModelConfig>{};
  for (final entry in modelConfigsRaw.entries) {
    final key = entry.key.toString();
    if (entry.value is Map) {
      modelConfigs[key] =
          ModelConfig.fromJson((entry.value as Map).cast<String, dynamic>());
    }
  }
  final meta = _calculateModelMeta(
    providers,
    fallbackVisible: fallbackVisible,
    serverDefault: data['default_model'] as String?,
  );

  final messageFormatConfig = data['message_format_config'] != null
      ? MessageFormatConfig.fromJson(
          data['message_format_config'] as Map<String, dynamic>)
      : const MessageFormatConfig();

  final textScaleFactor =
      ((data['text_scale_factor'] as num?)?.toDouble() ?? 1.0)
          .clamp(kMinTextScaleFactor, kMaxTextScaleFactor)
          .toDouble();
  final uiScaleFactor = ((data['ui_scale_factor'] as num?)?.toDouble() ?? 1.0)
      .clamp(kMinUiScaleFactor, kMaxUiScaleFactor)
      .toDouble();
  final imagePreviewScale =
      ((data['image_preview_scale'] as num?)?.toDouble() ?? 1.0)
          .clamp(kMinImagePreviewScale, kMaxImagePreviewScale)
          .toDouble();
  final hideUserAvatar = data['hide_user_avatar'] != false;
  final userAvatar = data['user_avatar'] as String?;
  final userName = data['user_name'] as String?;
  final autoReplySettings = data['auto_reply_settings'] is Map
      ? AutoReplySettings.fromJson(
          (data['auto_reply_settings'] as Map).cast<String, dynamic>(),
        )
      : const AutoReplySettings();
  final enhancedDialogueSettings = data['enhanced_dialogue_settings'] is Map
      ? EnhancedDialogueSettings.fromJson(
          (data['enhanced_dialogue_settings'] as Map).cast<String, dynamic>(),
        )
      : const EnhancedDialogueSettings();
  final callFlowSettings = data['call_flow_settings'] is Map
      ? CallFlowSettings.fromJson(
          (data['call_flow_settings'] as Map).cast<String, dynamic>(),
        )
      : const CallFlowSettings();
  final chatBackgroundColor = ChatBackgroundColor.fromValue(
    data['chat_background_color'] as String?,
  );
  final globalBackgroundColor = GlobalBackgroundColor.fromValue(
    data['global_background_color'] as String?,
  );
  final isDarkMode = (data['is_dark_mode'] as bool?) ?? false;
  final useSystemTheme = (data['use_system_theme'] as bool?) ?? true;
  // 支持十六进制颜色值（如 'FC96AA'）或旧枚举值（如 'pink'）
  final rawAccent = (data['accent_color'] as String?) ?? 'FC96AA';
  final accentColor = _migrateAccentColor(rawAccent);

  // 解析默认聊天模型列表和图片识别模型
  final chatProviderIds =
      providers.where((p) => p.modelType == 'chat').map((p) => p.id).toSet();
  final defaultChatModels = <String>[];
  for (final model in _cleanStrings(data['default_chat_models'])) {
    final modelRef = _normalizeStoredModelRef(
      model,
      providerMap: meta.providerMap,
      providerIds: chatProviderIds,
    );
    if (modelRef.isNotEmpty && !defaultChatModels.contains(modelRef)) {
      defaultChatModels.add(modelRef);
    }
  }
  final rawDefaultVisionModel = data['default_vision_model'] as String?;
  final defaultVisionModel = rawDefaultVisionModel == null
      ? null
      : _normalizeStoredModelRef(
          rawDefaultVisionModel,
          providerMap: meta.providerMap,
          providerIds: chatProviderIds,
        );
  final skipVisionCompatDialog = data['skip_vision_compat_dialog'] == true;

  return AppSettings(
    ttsEnabled: true,
    defaultModelName: meta.defaultModel,
    temperature: 0.7,
    defaultPersonaPrompt: '',
    modelList: meta.visible.isEmpty ? <String>['deepseek-chat'] : meta.visible,
    allKnownModels:
        meta.allKnown.isEmpty ? <String>['deepseek-chat'] : meta.allKnown,
    modelDisplayNames: displayNames,
    modelTypes: modelTypes,
    modelConfigs: modelConfigs,
    apiKey: '',
    apiBaseUrl: 'https://api.openai.com/v1',
    imageGenerationEnabled: data['image_generation_enabled'] == true,
    maxFileUploadMB: 10,
    historyMessageLimit: 100,
    customModels: const <CustomModel>[],
    providers: providers,
    modelProviderMap: meta.providerMap,
    backendApiKey: (data['backend_api_key'] as String?) ?? '',
    messageChunkingEnabled: data['message_chunking_enabled'] == true,
    messageFormatConfig: messageFormatConfig,
    textScaleFactor: textScaleFactor,
    uiScaleFactor: uiScaleFactor,
    imagePreviewScale: imagePreviewScale,
    hideUserAvatar: hideUserAvatar,
    autoReplySettings: autoReplySettings,
    globalBackgroundColor: globalBackgroundColor,
    chatBackgroundColor: chatBackgroundColor,
    isDarkMode: isDarkMode,
    useSystemTheme: useSystemTheme,
    accentColor: accentColor,
    userAvatar: userAvatar,
    userName: userName,
    defaultChatModels: defaultChatModels,
    defaultVisionModel: defaultVisionModel,
    skipVisionCompatDialog: skipVisionCompatDialog,
    enhancedDialogueSettings: enhancedDialogueSettings,
    callFlowSettings: callFlowSettings,
  );
}

// ===== Provider 定义 =====

final appSettingsProvider =
    AsyncNotifierProvider<AppSettingsNotifier, AppSettings>(
        AppSettingsNotifier.new);

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

  String _normalizeModelRefForPersist(String modelRef) {
    final trimmed = modelRef.trim();
    if (trimmed.isEmpty) return trimmed;

    final settings = state.value;
    if (settings == null) return trimmed;

    final providerId = settings.getModelProviderId(trimmed);
    final rawModelId = settings.getRawModelId(trimmed);
    if (providerId == null || providerId.isEmpty) {
      return rawModelId;
    }
    return settings.buildModelRef(providerId, rawModelId);
  }

  Future<void> setDefaultModelName(String modelId) async {
    final modelRef = _normalizeModelRefForPersist(modelId);
    await _commit(() => _api.updatePartial({'default_model': modelRef}));
  }

  Future<void> setModelDisplayName({
    required String modelId,
    required String? displayName,
  }) async {
    await _commit(() async {
      final data = await _api.fetchAll();
      final names =
          (data['model_display_names'] as Map? ?? const <String, dynamic>{})
              .map((key, value) =>
                  MapEntry(key.toString(), value?.toString() ?? ''));
      if (displayName == null || displayName.trim().isEmpty) {
        names.remove(modelId);
      } else {
        names[modelId] = displayName.trim();
      }
      return _api.updatePartial({'model_display_names': names});
    });
  }

  /// 设置模型类型（chat 类型会被移除，因为是默认值）
  Future<void> setModelType({
    required String modelId,
    required ModelType type,
  }) async {
    await _commit(() async {
      final data = await _api.fetchAll();
      final types = (data['model_types'] as Map? ?? const <String, dynamic>{})
          .map((key, value) =>
              MapEntry(key.toString(), value?.toString() ?? ''));
      if (type == ModelType.chat) {
        // chat 是默认值，不需要存储
        types.remove(modelId);
      } else {
        types[modelId] = type.value;
      }
      return _api.updatePartial({'model_types': types});
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
      provider['hidden_models'] =
          hiddenModels.where((m) => !visibleModels.contains(m)).toList();
      providers[index] = provider;

      return _api.updatePartial({
        'providers': providers,
        'visible_models': _collectVisible(providers),
      });
    });
  }

  /// 从指定渠道中删除一个模型（同时从 models/visible/hidden 中移除）
  Future<void> deleteProviderModel({
    required String providerId,
    required String modelId,
  }) async {
    final current = state.value;
    if (current == null) return;

    final provider = current.providers.firstWhere(
      (p) => p.id == providerId,
      orElse: () => const ProviderAuth(id: '', apiBaseUrl: '', apiKeys: []),
    );

    if (provider.id.isEmpty) return;

    final allModels = [...provider.models]..removeWhere((m) => m == modelId);
    final visibleModels = [...provider.visibleModels]
      ..removeWhere((m) => m == modelId);
    final hiddenModels = [...provider.hiddenModels]
      ..removeWhere((m) => m == modelId);

    await updateProviderModels(
      providerId: providerId,
      allModels: allModels,
      visibleModels: visibleModels,
      hiddenModels: hiddenModels,
    );
  }

  Future<void> setProviderEnabled(String providerId, bool enabled) async {
    await _commit(
        () => _api.updateProvider(providerId: providerId, enabled: enabled));
  }

  /// 设置渠道是否禁用工具调用
  Future<void> setProviderDisableToolCalling(
      String providerId, bool disableToolCalling) async {
    await _commit(() => _api.updateProvider(
          providerId: providerId,
          disableToolCalling: disableToolCalling,
        ));
  }

  /// 更新渠道的模型参数（temperature, topP, contextMessageLimit）
  Future<void> updateProviderParams({
    required String providerId,
    double? temperature,
    bool clearTemperature = false,
    double? topP,
    bool clearTopP = false,
    int? contextMessageLimit,
    bool clearContextMessageLimit = false,
  }) async {
    await _commit(() => _api.updateProvider(
          providerId: providerId,
          temperature: temperature,
          clearTemperature: clearTemperature,
          topP: topP,
          clearTopP: clearTopP,
          contextMessageLimit: contextMessageLimit,
          clearContextMessageLimit: clearContextMessageLimit,
        ));
  }

  /// 设置模型是否禁用工具调用
  Future<void> setModelDisableToolCalling({
    required String modelId,
    required bool disableToolCalling,
  }) async {
    await updateModelConfig(
      modelId: modelId,
      disableToolCalling: disableToolCalling,
    );
  }

  /// 更新模型级别配置（温度、Top P、上下文消息数、工具调用等）
  Future<void> updateModelConfig({
    required String modelId,
    bool? disableToolCalling,
    double? temperature,
    bool clearTemperature = false,
    double? topP,
    bool clearTopP = false,
    int? contextMessageLimit,
    bool clearContextMessageLimit = false,
  }) async {
    await _commit(() async {
      final data = await _api.fetchAll();
      final configs =
          (data['model_configs'] as Map? ?? const <String, dynamic>{})
              .map((key, value) => MapEntry(key.toString(), value));

      // 获取现有配置或创建新配置
      final existing = configs[modelId] is Map
          ? ModelConfig.fromJson(
              (configs[modelId] as Map).cast<String, dynamic>())
          : const ModelConfig();

      final updated = existing.copyWith(
        disableToolCalling: disableToolCalling,
        temperature: temperature,
        clearTemperature: clearTemperature,
        topP: topP,
        clearTopP: clearTopP,
        contextMessageLimit: contextMessageLimit,
        clearContextMessageLimit: clearContextMessageLimit,
      );

      if (updated.isDefault) {
        // 全部为默认值时，移除配置以节省空间
        configs.remove(modelId);
      } else {
        configs[modelId] = updated.toJson();
      }
      return _api.updatePartial({'model_configs': configs});
    });
  }

  Future<void> deleteProvider(String providerId) async {
    await _commit(() => _api.deleteProvider(providerId));
  }

  Future<void> reorderProviders(List<String> providerIds) async {
    await _commit(() => _api.reorderProviders(providerIds));
  }

  Future<void> reorderProviderModels({
    required String providerId,
    required List<String> modelIds,
  }) async {
    await _commit(() => _api.reorderProviderModels(
          providerId: providerId,
          modelIds: modelIds,
        ));
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

  /// 测试指定模型是否可用（发一条极简请求验证）
  Future<String> testModel({
    required String providerId,
    required String apiKey,
    required String apiBaseUrl,
    required String modelId,
  }) {
    return _api.testModel(
      providerId: providerId,
      apiKey: apiKey,
      apiBaseUrl: apiBaseUrl,
      modelId: modelId,
    );
  }

  /// 为 OpenAI 渠道分配唯一 ID，避免新建渠道覆盖旧渠道。
  /// 规则：
  /// - 第一个保持 `openai`
  /// - 后续依次为 `openai__2`、`openai__3`...
  String _resolveImportProviderId(String providerId) {
    final base = providerId.trim();
    if (base.isEmpty) return base;
    if (base.toLowerCase() != 'openai') return base;

    final current = state.value;
    if (current == null) return base;

    final usedIds =
        current.providers.map((p) => p.id.trim().toLowerCase()).toSet();
    if (!usedIds.contains('openai')) return 'openai';

    var index = 2;
    while (usedIds.contains('openai__$index')) {
      index++;
    }
    return 'openai__$index';
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
    final resolvedProviderId = _resolveImportProviderId(provider);
    await _commit(() => _api.importProvider(
          providerId: resolvedProviderId,
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

  /// 更新渠道的模型列表
  Future<void> updateProviderModels({
    required String providerId,
    required List<String> allModels,
    List<String>? visibleModels,
    List<String>? hiddenModels,
  }) async {
    await _commit(() => _api.updateProvider(
          providerId: providerId,
          allModels: allModels,
          visibleModels: visibleModels ?? allModels,
          hiddenModels: hiddenModels,
        ));
  }

  /// 添加自定义模型到渠道
  Future<void> addCustomModel({
    required String providerId,
    required String modelId,
    String? displayName,
  }) async {
    final current = state.value;
    if (current == null) return;

    final provider = current.providers.firstWhere(
      (p) => p.id == providerId,
      orElse: () => const ProviderAuth(id: '', apiBaseUrl: '', apiKeys: []),
    );
    if (provider.id.isEmpty) return;

    // 添加到 visibleModels（不重复添加）
    final newVisible = [...provider.visibleModels];
    if (!newVisible.contains(modelId)) {
      newVisible.add(modelId);
    }

    await _commit(() => _api.updateProvider(
          providerId: providerId,
          visibleModels: newVisible,
        ));

    // 如果有显示名称，同时设置
    if (displayName != null && displayName.isNotEmpty) {
      await setModelDisplayName(modelId: modelId, displayName: displayName);
    }
  }

  Future<void> setMessageChunkingEnabled(bool value) async {
    await _commit(
        () => _api.updatePartial({'message_chunking_enabled': value}));
  }

  Future<void> setImageGenerationEnabled(bool value) async {
    await _commit(
        () => _api.updatePartial({'image_generation_enabled': value}));
  }

  Future<void> setBackendApiKey(String key) async {
    await _commit(() => _api.updatePartial({'backend_api_key': key}));
  }

  Future<void> updateMessageFormatConfig(MessageFormatConfig config) async {
    await _commit(
        () => _api.updatePartial({'message_format_config': config.toJson()}));
  }

  Future<void> setTextScaleFactor(double scale) async {
    await _commit(
      () => _api.updatePartial({
        'text_scale_factor':
            scale.clamp(kMinTextScaleFactor, kMaxTextScaleFactor),
      }),
    );
  }

  Future<void> setUiScaleFactor(double scale) async {
    await _commit(
      () => _api.updatePartial({
        'ui_scale_factor': scale.clamp(kMinUiScaleFactor, kMaxUiScaleFactor),
      }),
    );
  }

  Future<void> setImagePreviewScale(double scale) async {
    await _commit(
      () => _api.updatePartial({
        'image_preview_scale':
            scale.clamp(kMinImagePreviewScale, kMaxImagePreviewScale),
      }),
    );
  }

  Future<void> setHideUserAvatar(bool hide) async {
    await _commit(() => _api.updatePartial({'hide_user_avatar': hide}));
  }

  Future<void> setUserAvatar(String? avatar) async {
    await _commit(() => _api.updatePartial({'user_avatar': avatar}));
  }

  Future<void> setUserName(String? name) async {
    await _commit(() => _api.updatePartial({'user_name': name}));
  }

  Future<void> updateAutoReplySettings(AutoReplySettings settings) async {
    await _commit(
        () => _api.updatePartial({'auto_reply_settings': settings.toJson()}));
  }

  Future<void> updateEnhancedDialogueSettings(
      EnhancedDialogueSettings settings) async {
    await _commit(() =>
        _api.updatePartial({'enhanced_dialogue_settings': settings.toJson()}));
  }

  Future<void> updateCallFlowSettings(CallFlowSettings settings) async {
    await _commit(
        () => _api.updatePartial({'call_flow_settings': settings.toJson()}));
  }

  Future<void> setGlobalBackgroundColor(GlobalBackgroundColor color) async {
    await _commit(
        () => _api.updatePartial({'global_background_color': color.value}));
  }

  Future<void> setChatBackgroundColor(ChatBackgroundColor color) async {
    await _commit(
        () => _api.updatePartial({'chat_background_color': color.value}));
  }

  Future<void> setDarkMode(bool isDark) async {
    await _commit(() => _api.updatePartial({'is_dark_mode': isDark}));
  }

  Future<void> setUseSystemTheme(bool useSystem) async {
    await _commit(() => _api.updatePartial({'use_system_theme': useSystem}));
  }

  Future<void> setAccentColor(String color) async {
    await _commit(() => _api.updatePartial({'accent_color': color}));
  }

  /// 同时设置暗色模式和是否跟随系统（避免两次状态更新冲突）
  Future<void> setDarkModeAndSystemTheme(
      {required bool isDark, required bool useSystem}) async {
    await _commit(() => _api.updatePartial({
          'is_dark_mode': isDark,
          'use_system_theme': useSystem,
        }));
  }

  /// 设置默认聊天模型列表（有序，第一个为首选）
  Future<void> setDefaultChatModels(List<String> models) async {
    final normalized = <String>[];
    for (final model in models) {
      final modelRef = _normalizeModelRefForPersist(model);
      if (modelRef.isNotEmpty && !normalized.contains(modelRef)) {
        normalized.add(modelRef);
      }
    }
    await _commit(
      () => _api.updatePartial({'default_chat_models': normalized}),
    );
  }

  /// 设置默认图片识别模型
  Future<void> setDefaultVisionModel(String? modelId) async {
    final normalized =
        modelId == null ? null : _normalizeModelRefForPersist(modelId);
    await _commit(
      () => _api.updatePartial({'default_vision_model': normalized}),
    );
  }

  /// 设置是否跳过视觉兼容性弹窗
  Future<void> setSkipVisionCompatDialog(bool skip) async {
    await _commit(
        () => _api.updatePartial({'skip_vision_compat_dialog': skip}));
  }

  Future<void> _commit(
    Future<Map<String, dynamic>> Function() mutation,
  ) async {
    final data = await mutation();
    state = AsyncData(_mapToSettings(data));
  }
}
