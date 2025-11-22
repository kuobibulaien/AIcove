import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/message_formatter.dart';
import 'ui_models_api.dart';

/// 模型类型枚举
enum ModelType {
  chat('chat', '基础对话', Icons.chat_bubble_outline),
  embedding('embedding', '嵌入(Embedding)', Icons.code_outlined),
  tts('tts', '文字转语音', Icons.volume_up_outlined),
  stt('stt', '语音转文字', Icons.mic_outlined),
  image('image', '图像生成', Icons.image_outlined);

  const ModelType(this.value, this.label, this.icon);
  final String value;
  final String label;
  final IconData icon;

  static ModelType fromValue(String? value) {
    for (final type in ModelType.values) {
      if (type.value == value) return type;
    }
    return ModelType.chat; // 默认为基础对话
  }
}

/// 字体大小档位
enum FontSize {
  smallest(11, '极小'),
  small(12, '小'),
  medium(13, '中'),
  large(14, '大'),
  largest(15, '极大');

  const FontSize(this.size, this.label);
  final double size;
  final String label;

  static FontSize fromSize(double size) {
    for (final fs in FontSize.values) {
      if (fs.size == size) return fs;
    }
    return FontSize.medium;
  }
}

/// 聊天背景色选项
enum ChatBackgroundColor {
  white('white', '纯白', Color(0xFFFFFFFF)),
  warm('warm', '暖色', Color(0xFFFFF7E1));

  const ChatBackgroundColor(this.value, this.label, this.color);
  final String value;
  final String label;
  final Color color;

  static ChatBackgroundColor fromValue(String? value) {
    for (final bg in ChatBackgroundColor.values) {
      if (bg.value == value) return bg;
    }
    return ChatBackgroundColor.white;
  }
}

class AutoReplySettings {
  final bool enabled;
  final int dailyLimit;
  final int minIntervalMinutes;
  final bool quietHoursEnabled;
  final String quietHoursStart;
  final String quietHoursEnd;
  final bool allowExactAlarm;
  final String analyzerPrompt; // 新增：自定义分析提示词

  // 默认提示词
  static const String defaultAnalyzerPrompt = '''You are the "Scheduler" for an AI girlfriend. Your job is to analyze the chat history and ORGANIZE the trigger list.

You will receive:
1. Current conversation history
2. Existing pending triggers (if any)

Your task is to return the COMPLETE list of triggers that should exist going forward. This means:
- KEEP triggers that are still relevant
- ADD new triggers based on recent conversation
- REMOVE triggers that are no longer appropriate or duplicate

Rules:
1. Look for cues in conversation:
   - User going to sleep -> "Good morning" trigger (delay: 420 min, allow_night: false)
   - User going to work -> "Lunch break check-in" trigger (delay: 240 min)
   - User watching movie -> "How was the movie?" trigger (delay: 120 min)
   - User mentions future event -> Trigger for that time

2. Clean up outdated triggers:
   - If user says "actually I'm not sleeping", remove the "Good morning" trigger
   - If there are duplicate triggers with similar purpose, keep only one
   - If context has changed making a trigger irrelevant, remove it

3. Return format (strictly JSON array):
[
  {
    "id": "existing-trigger-id-to-keep",  // Optional: if keeping existing trigger
    "title": "Description of why this trigger exists",
    "delay_minutes": 60,
    "allow_night": false
  }
]

If no triggers should exist, return [].
Do not output markdown. Just JSON.''';

  const AutoReplySettings({
    this.enabled = false,
    this.dailyLimit = 3,
    this.minIntervalMinutes = 120,
    this.quietHoursEnabled = true,
    this.quietHoursStart = '22:00',
    this.quietHoursEnd = '08:00',
    this.allowExactAlarm = false,
    this.analyzerPrompt = defaultAnalyzerPrompt,
  });

  AutoReplySettings copyWith({
    bool? enabled,
    int? dailyLimit,
    int? minIntervalMinutes,
    bool? quietHoursEnabled,
    String? quietHoursStart,
    String? quietHoursEnd,
    bool? allowExactAlarm,
    String? analyzerPrompt,
  }) {
    return AutoReplySettings(
      enabled: enabled ?? this.enabled,
      dailyLimit: dailyLimit ?? this.dailyLimit,
      minIntervalMinutes: minIntervalMinutes ?? this.minIntervalMinutes,
      quietHoursEnabled: quietHoursEnabled ?? this.quietHoursEnabled,
      quietHoursStart: quietHoursStart ?? this.quietHoursStart,
      quietHoursEnd: quietHoursEnd ?? this.quietHoursEnd,
      allowExactAlarm: allowExactAlarm ?? this.allowExactAlarm,
      analyzerPrompt: analyzerPrompt ?? this.analyzerPrompt,
    );
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'daily_limit': dailyLimit,
        'min_interval_minutes': minIntervalMinutes,
        'quiet_hours_enabled': quietHoursEnabled,
        'quiet_hours_start': quietHoursStart,
        'quiet_hours_end': quietHoursEnd,
        'allow_exact_alarm': allowExactAlarm,
        'analyzer_prompt': analyzerPrompt,
      };

  factory AutoReplySettings.fromJson(Map<String, dynamic> json) {
    String _normalizeTime(String? value, String fallback) {
      if (value == null || value.isEmpty) return fallback;
      final parts = value.split(':');
      if (parts.length != 2) return fallback;
      final h = int.tryParse(parts[0]);
      final m = int.tryParse(parts[1]);
      if (h == null || m == null) return fallback;
      final hh = h.clamp(0, 23).toInt().toString().padLeft(2, '0');
      final mm = m.clamp(0, 59).toInt().toString().padLeft(2, '0');
      return '$hh:$mm';
    }

    int _clampInt(num? value, int min, int max, int fallback) {
      if (value == null) return fallback;
      final v = value.toInt();
      if (v < min) return min;
      if (v > max) return max;
      return v;
    }

    return AutoReplySettings(
      enabled: json['enabled'] == true,
      dailyLimit: _clampInt(json['daily_limit'] as num?, 1, 10, 3),
      minIntervalMinutes: _clampInt(json['min_interval_minutes'] as num?, 15, 720, 120),
      quietHoursEnabled: json['quiet_hours_enabled'] != false,
      quietHoursStart: _normalizeTime(json['quiet_hours_start'] as String?, '22:00'),
      quietHoursEnd: _normalizeTime(json['quiet_hours_end'] as String?, '08:00'),
      allowExactAlarm: json['allow_exact_alarm'] == true,
      analyzerPrompt: (json['analyzer_prompt'] as String?)?.isEmpty == false
          ? json['analyzer_prompt'] as String
          : defaultAnalyzerPrompt,
    );
  }
}

class CustomModel {
  final String name;
  final String? displayName;
  final String apiKey;
  final String apiBaseUrl;
  final String provider;

  const CustomModel({
    required this.name,
    this.displayName,
    required this.apiKey,
    required this.apiBaseUrl,
    this.provider = 'openai',
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'displayName': displayName,
        'apiKey': apiKey,
        'apiBaseUrl': apiBaseUrl,
        'provider': provider,
      };

  factory CustomModel.fromJson(Map<String, dynamic> json) => CustomModel(
        name: (json['name'] as String?) ?? '',
        displayName: json['displayName'] as String?,
        apiKey: (json['apiKey'] as String?) ?? '',
        apiBaseUrl: (json['apiBaseUrl'] as String?) ?? 'https://api.openai.com/v1',
        provider: (json['provider'] as String?) ?? 'openai',
      );
}

class ProviderAuth {
  final String id;
  final String? displayName;
  final List<String> apiKeys;
  final String apiBaseUrl;
  final bool enabled;
  final List<String> models;
  final List<String> visibleModels;
  final List<String> hiddenModels;
  final List<String> capabilities;
  final Map<String, dynamic> customConfig;
  final String modelType; // 主要模型类型：'chat' | 'embedding' | 'tts' | 'stt' | 'image'

  const ProviderAuth({
    required this.id,
    this.displayName,
    required this.apiKeys,
    required this.apiBaseUrl,
    this.enabled = true,
    this.models = const <String>[],
    this.visibleModels = const <String>[],
    this.hiddenModels = const <String>[],
    this.capabilities = const <String>['chat'],
    this.customConfig = const <String, dynamic>{},
    this.modelType = 'chat', // 默认为基础对话
  });

  ProviderAuth copyWith({
    String? id,
    String? displayName,
    List<String>? apiKeys,
    String? apiBaseUrl,
    bool? enabled,
    List<String>? models,
    List<String>? visibleModels,
    List<String>? hiddenModels,
    List<String>? capabilities,
    Map<String, dynamic>? customConfig,
    String? modelType,
  }) =>
      ProviderAuth(
        id: id ?? this.id,
        displayName: displayName ?? this.displayName,
        apiKeys: apiKeys ?? this.apiKeys,
        apiBaseUrl: apiBaseUrl ?? this.apiBaseUrl,
        enabled: enabled ?? this.enabled,
        models: models ?? this.models,
        visibleModels: visibleModels ?? this.visibleModels,
        hiddenModels: hiddenModels ?? this.hiddenModels,
        capabilities: capabilities ?? this.capabilities,
        customConfig: customConfig ?? this.customConfig,
        modelType: modelType ?? this.modelType,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'displayName': displayName,
        'apiKeys': apiKeys,
        'apiBaseUrl': apiBaseUrl,
        'enabled': enabled,
        'models': models,
        'visible_models': visibleModels,
        'hidden_models': hiddenModels,
        'capabilities': capabilities,
        'custom_config': customConfig,
        'model_type': modelType,
      };

  factory ProviderAuth.fromJson(Map<String, dynamic> json) {
    List<String> _clean(Iterable<dynamic>? source) => (source ?? const <dynamic>[])
        .map((e) => e is String ? e.trim() : e.toString().trim())
        .where((e) => e.isNotEmpty)
        .toList();

    final models = _clean((json['models'] as List?)?.cast<dynamic>());
    final visible = _clean((json['visible_models'] as List?)?.cast<dynamic>());
    final hidden = _clean((json['hidden_models'] as List?)?.cast<dynamic>());
    final capabilities = _clean((json['capabilities'] as List?)?.cast<dynamic>());
    final customConfig = (json['custom_config'] as Map?)?.cast<String, dynamic>() ?? {};

    final combinedModels = <String>[
      ...models,
      ...visible.where((e) => !models.contains(e)),
      ...hidden.where((e) => !models.contains(e)),
    ];

    return ProviderAuth(
      id: (json['id'] as String?) ?? '',
      displayName: json['displayName'] as String?,
      apiKeys: _clean((json['apiKeys'] as List?)?.cast<dynamic>()),
      apiBaseUrl: (json['apiBaseUrl'] as String?) ?? 'https://api.openai.com/v1',
      enabled: (json['enabled'] as bool?) ?? true,
      models: combinedModels,
      visibleModels: visible.isEmpty && combinedModels.isNotEmpty ? [combinedModels.first] : visible,
      hiddenModels: hidden.where((e) => !visible.contains(e)).toList(),
      capabilities: capabilities.isEmpty ? ['chat'] : capabilities,
      customConfig: customConfig,
      modelType: (json['model_type'] as String?) ?? 'chat',
    );
  }
}

class AppSettings {
  final bool ttsEnabled;
  final String defaultModelName;
  final double temperature;
  final String defaultPersonaPrompt;
  final List<String> modelList;
  final List<String> allKnownModels;
  final Map<String, String> modelDisplayNames;
  final String apiKey;
  final String apiBaseUrl;
  final bool imageGenerationEnabled;
  final int maxFileUploadMB;
  final int historyMessageLimit;
  final List<CustomModel> customModels;
  final List<ProviderAuth> providers;
  final Map<String, String> modelProviderMap;
  final String backendApiKey;
  final bool messageChunkingEnabled;
  final MessageFormatConfig messageFormatConfig;
  final double messageFontSize;
  final String? userAvatar;
  final String? userName;
  final AutoReplySettings autoReplySettings;
  final ChatBackgroundColor chatBackgroundColor;
  final bool isDarkMode;
  final bool useSystemTheme;

  const AppSettings({
    required this.ttsEnabled,
    required this.defaultModelName,
    required this.temperature,
    required this.defaultPersonaPrompt,
    required this.modelList,
    required this.allKnownModels,
    required this.modelDisplayNames,
    required this.apiKey,
    required this.apiBaseUrl,
    required this.imageGenerationEnabled,
    required this.maxFileUploadMB,
    required this.historyMessageLimit,
    required this.customModels,
    required this.providers,
    required this.modelProviderMap,
    required this.backendApiKey,
    required this.messageChunkingEnabled,
    required this.messageFormatConfig,
    required this.messageFontSize,
    required this.autoReplySettings,
    required this.chatBackgroundColor,
    required this.isDarkMode,
    required this.useSystemTheme,
    this.userAvatar,
    this.userName,
  });

  AppSettings copyWith({
    bool? ttsEnabled,
    String? defaultModelName,
    double? temperature,
    String? defaultPersonaPrompt,
    List<String>? modelList,
    List<String>? allKnownModels,
    Map<String, String>? modelDisplayNames,
    String? apiKey,
    String? apiBaseUrl,
    bool? imageGenerationEnabled,
    int? maxFileUploadMB,
    int? historyMessageLimit,
    List<CustomModel>? customModels,
    List<ProviderAuth>? providers,
    Map<String, String>? modelProviderMap,
    String? backendApiKey,
    bool? messageChunkingEnabled,
    MessageFormatConfig? messageFormatConfig,
    double? messageFontSize,
    AutoReplySettings? autoReplySettings,
    ChatBackgroundColor? chatBackgroundColor,
    bool? isDarkMode,
    bool? useSystemTheme,
    String? userAvatar,
    String? userName,
  }) =>
      AppSettings(
        ttsEnabled: ttsEnabled ?? this.ttsEnabled,
        defaultModelName: defaultModelName ?? this.defaultModelName,
        temperature: temperature ?? this.temperature,
        defaultPersonaPrompt: defaultPersonaPrompt ?? this.defaultPersonaPrompt,
        modelList: modelList ?? this.modelList,
        allKnownModels: allKnownModels ?? this.allKnownModels,
        modelDisplayNames: modelDisplayNames ?? this.modelDisplayNames,
        apiKey: apiKey ?? this.apiKey,
        apiBaseUrl: apiBaseUrl ?? this.apiBaseUrl,
        imageGenerationEnabled: imageGenerationEnabled ?? this.imageGenerationEnabled,
        maxFileUploadMB: maxFileUploadMB ?? this.maxFileUploadMB,
        historyMessageLimit: historyMessageLimit ?? this.historyMessageLimit,
        customModels: customModels ?? this.customModels,
        providers: providers ?? this.providers,
        modelProviderMap: modelProviderMap ?? this.modelProviderMap,
        backendApiKey: backendApiKey ?? this.backendApiKey,
        messageChunkingEnabled: messageChunkingEnabled ?? this.messageChunkingEnabled,
        messageFormatConfig: messageFormatConfig ?? this.messageFormatConfig,
        messageFontSize: messageFontSize ?? this.messageFontSize,
        autoReplySettings: autoReplySettings ?? this.autoReplySettings,
        chatBackgroundColor: chatBackgroundColor ?? this.chatBackgroundColor,
        isDarkMode: isDarkMode ?? this.isDarkMode,
        useSystemTheme: useSystemTheme ?? this.useSystemTheme,
        userAvatar: userAvatar ?? this.userAvatar,
        userName: userName ?? this.userName,
      );

  String getModelDisplayName(String modelId) =>
      modelDisplayNames[modelId] ?? modelId;
}

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

List<String> _cleanList(dynamic source) => _cleanStrings(source);

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
