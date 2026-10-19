import '../../chat/domain/chat_display_policy.dart';
import '../../settings/app_settings.dart';
import '../../../ui/theme/moe_glass_theme.dart' show MoeSurfaceMaterial;
import '../domain/assistant_onboarding.dart' show providerHasApiKey;
import 'assistant_review.dart';

/// One setting the assistant may read and change (ADR0073, batch T3b).
/// The whitelist is the only way in: each entry declares its type, allowed
/// values, where the user finds it and its risk.
class AssistantSetting {
  const AssistantSetting({
    required this.key,
    required this.label,
    required this.page,
    required this.type,
    required this.read,
    required this.write,
    this.options,
    this.min,
    this.max,
    this.risk = AssistantRisk.reversible,
    this.riskOf,
    this.validate,
    this.nullable = false,
    this.stateOf,
    this.nextState,
    this.restore,
  });

  /// An empty string clears the setting.
  final bool nullable;

  /// What the change journal keeps, when the value alone cannot restore the
  /// setting (the default model is the head of an ordered list): the state
  /// now, the state after writing a value, and how to write a state back.
  final Object? Function(AppSettings settings)? stateOf;
  final Object? Function(AppSettings settings, Object? value)? nextState;
  final Future<void> Function(AppSettingsNotifier settings, Object? state)?
  restore;

  Object? journalState(AppSettings settings) =>
      (stateOf ?? read).call(settings);

  Object? journalStateAfter(AppSettings settings, Object? value) =>
      nextState?.call(settings, value) ?? value;

  Future<void> writeState(
    AppSettingsNotifier notifier,
    Object? state,
    AppSettings current,
  ) => restore?.call(notifier, state) ?? write(notifier, state, current);

  final String key;
  final String label;

  /// Where the user changes it by hand.
  final String page;

  /// `enum`, `bool`, `number`, `integer` or `string`.
  final String type;

  /// Value to label, for `enum`.
  final Map<String, String>? options;
  final num? min;
  final num? max;
  final AssistantRisk risk;

  /// Risk that depends on the new value; overrides [risk].
  final AssistantRisk Function(AppSettings settings, Object? value)? riskOf;

  /// Returns why [value] cannot be used, or null.
  final String? Function(AppSettings settings, Object? value)? validate;

  final Object? Function(AppSettings settings) read;

  /// Writes [value]; [current] is the settings it replaces.
  final Future<void> Function(
    AppSettingsNotifier settings,
    Object? value,
    AppSettings current,
  )
  write;

  AssistantRisk riskFor(AppSettings settings, Object? value) =>
      riskOf?.call(settings, value) ?? risk;

  /// The value in its declared type; `ok` is false when it has the wrong
  /// type. A cleared [nullable] setting is ok with a null value.
  ({bool ok, Object? value}) normalize(Object? value) {
    final normalized = switch (type) {
      'bool' => value is bool ? value : null,
      'number' => value is num ? value.toDouble() : null,
      'integer' =>
        value is num && value == value.roundToDouble() ? value.toInt() : null,
      'enum' => options!.containsKey(value) ? value : null,
      _ => value is String ? value.trim() : null,
    };
    if (nullable && (value == null || normalized == '')) {
      return (ok: true, value: null);
    }
    return (ok: normalized != null, value: normalized);
  }

  String? check(AppSettings settings, ({bool ok, Object? value}) input) {
    if (!input.ok) return '取值类型不对，应为 $type';
    final value = input.value;
    if (value == null) return null;
    if (value is num &&
        ((min != null && value < min!) || (max != null && value > max!))) {
      return '取值超出范围（$min～$max）';
    }
    return validate?.call(settings, value);
  }

  Map<String, Object?> describe(AppSettings settings) => {
    'key': key,
    'label': label,
    'page': page,
    'type': type,
    'value': read(settings),
    'options': ?options,
    'min': ?min,
    'max': ?max,
    'risk': switch (riskOf == null ? risk : null) {
      AssistantRisk.reversible => '直接生效，可撤销',
      AssistantRisk.review => '需审核',
      AssistantRisk.major => '需用户确认',
      _ => '看取值',
    },
  };
}

/// The model reference as the settings store writes it, so the check, the
/// undo record and the saved list agree (`deepseek: x` → `deepseek:x`).
String _modelRef(AppSettings settings, String model) {
  final trimmed = model.trim();
  final providerId = settings.getModelProviderId(trimmed);
  final rawModelId = settings.getRawModelId(trimmed);
  if (providerId == null || providerId.isEmpty) return rawModelId;
  return settings.buildModelRef(providerId, rawModelId);
}

/// The ordered list with [model] first, normalized and deduplicated the
/// way [AppSettingsNotifier.setDefaultChatModels] saves it.
List<String> _withFirst(AppSettings settings, String model) {
  final list = <String>[];
  for (final entry in [model, ...settings.defaultChatModels]) {
    final ref = _modelRef(settings, entry);
    if (ref.isNotEmpty && !list.contains(ref)) list.add(ref);
  }
  return list;
}

String? _providerOf(AppSettings settings, String modelRef) =>
    settings.getModelProviderId(modelRef);

String? _validChatModel(AppSettings settings, Object? value) {
  final ref = _modelRef(settings, value as String);
  final providerId = _providerOf(settings, ref);
  final provider = providerId == null ? null : settings.getProvider(providerId);
  if (provider == null) return '没有这个模型：$ref（用「渠道 id:模型名」）';
  if (!provider.enabled) return '渠道「${provider.id}」没启用';
  if (!provider.capabilities.contains('chat')) {
    return '渠道「${provider.id}」不能聊天';
  }
  if (!providerHasApiKey(provider)) return '渠道「${provider.id}」还没填 Key';
  if (!provider.models.contains(settings.getRawModelId(ref))) {
    return '渠道「${provider.id}」里没有模型 ${settings.getRawModelId(ref)}';
  }
  return null;
}

/// Changing to a model on another channel sends the chat to a service it
/// may not have gone to before: a major decision.
AssistantRisk _modelRisk(AppSettings settings, Object? value) =>
    value is String &&
        _providerOf(settings, _modelRef(settings, value)) ==
            _providerOf(settings, settings.defaultModelName)
    ? AssistantRisk.reversible
    : AssistantRisk.major;

final List<AssistantSetting> kAssistantSettings = [
  AssistantSetting(
    key: 'appearance.theme',
    label: '深浅色',
    page: '设置 · 通用 · 外观',
    type: 'enum',
    options: const {'system': '跟随系统', 'light': '浅色', 'dark': '深色'},
    read: (s) => s.useSystemTheme
        ? 'system'
        : s.isDarkMode
        ? 'dark'
        : 'light',
    write: (n, v, _) => n.setDarkModeAndSystemTheme(
      isDark: v == 'dark',
      useSystem: v == 'system',
    ),
  ),
  AssistantSetting(
    key: 'appearance.material',
    label: '界面材质',
    page: '设置 · 通用 · 材质等级',
    type: 'enum',
    options: {
      for (final material in MoeSurfaceMaterial.values)
        material.name: material.label,
    },
    read: (s) => s.surfaceMaterial.name,
    write: (n, v, _) =>
        n.setSurfaceMaterial(MoeSurfaceMaterial.values.byName(v! as String)),
  ),
  AssistantSetting(
    key: 'appearance.skin',
    label: '界面皮肤',
    page: '设置 · 通用 · 外观',
    type: 'enum',
    options: {for (final skin in InterfaceSkin.presets) skin.value: skin.label},
    read: (s) => s.interfaceSkin.value,
    write: (n, v, _) =>
        n.setInterfaceSkin(InterfaceSkin.tryParse(v! as String)!),
  ),
  AssistantSetting(
    key: 'appearance.text_scale',
    label: '文字大小',
    page: '设置 · 通用 · 显示',
    type: 'number',
    min: kMinTextScaleFactor,
    max: kMaxTextScaleFactor,
    read: (s) => s.textScaleFactor,
    write: (n, v, _) => n.setTextScaleFactor(v! as double),
  ),
  AssistantSetting(
    key: 'appearance.ui_scale',
    label: '界面缩放',
    page: '设置 · 通用 · 显示',
    type: 'number',
    min: kMinUiScaleFactor,
    max: kMaxUiScaleFactor,
    read: (s) => s.uiScaleFactor,
    write: (n, v, _) => n.setUiScaleFactor(v! as double),
  ),
  AssistantSetting(
    key: 'chat.display_style',
    label: '新会话默认样式',
    page: '设置 · 通用 · 聊天样式与分段',
    type: 'enum',
    options: const {'bubble': '气泡', 'document': '文档'},
    read: (s) => s.chatDisplayStyle.name,
    write: (n, v, _) =>
        n.setChatDisplayStyle(ChatDisplayStyle.values.byName(v! as String)),
  ),
  AssistantSetting(
    key: 'chat.auto_scroll_on_send',
    label: '发送消息自动回底',
    page: '聊天页「更多 · 聊天界面 · 行为」',
    type: 'bool',
    read: (s) => s.autoScrollOnSend,
    write: (n, v, _) => n.setAutoScrollOnSend(v! as bool),
  ),
  AssistantSetting(
    key: 'chat.message_chunking',
    label: '启用消息分段',
    page: '设置 · 通用 · 聊天样式与分段',
    type: 'bool',
    read: (s) => s.messageChunkingEnabled,
    write: (n, v, _) => n.setMessageChunkingEnabled(v! as bool),
  ),
  AssistantSetting(
    key: 'chat.hide_user_avatar',
    label: '隐藏用户头像',
    page: '设置 · 通用 · 聊天',
    type: 'bool',
    read: (s) => s.hideUserAvatar,
    write: (n, v, _) => n.setHideUserAvatar(v! as bool),
  ),
  AssistantSetting(
    key: 'chat.expand_audio_text',
    label: '语音消息默认展开文字',
    page: '设置 · 通用 · 聊天',
    type: 'bool',
    read: (s) => s.expandAudioText,
    write: (n, v, _) => n.setExpandAudioText(v! as bool),
  ),
  AssistantSetting(
    key: 'profile.user_name',
    label: '我的名字（角色和预设里的 {{user}}）',
    page: '设置 · 个人资料',
    type: 'string',
    risk: AssistantRisk.review,
    nullable: true,
    validate: (_, v) => (v as String).length > 30 ? '名字太长（最多 30 字）' : null,
    read: (s) {
      final name = s.userName?.trim();
      return name == null || name.isEmpty ? null : name;
    },
    write: (n, v, _) => n.setUserName(v as String?),
  ),
  AssistantSetting(
    key: 'model.default_chat',
    label: '默认聊天模型',
    page: '设置 · 模型 · 默认模型设置',
    type: 'string',
    riskOf: _modelRisk,
    validate: _validChatModel,
    read: (s) => s.defaultModelName,
    write: (n, v, s) => n.setDefaultChatModels(_withFirst(s, v! as String)),
    // Undo restores the whole ordered list, not just its head.
    stateOf: (s) => s.defaultChatModels,
    nextState: (s, v) => _withFirst(s, v! as String),
    restore: (n, state) => n.setDefaultChatModels([
      for (final model in state! as List) model.toString(),
    ]),
  ),
  AssistantSetting(
    key: 'context.window_tokens',
    label: '上下文窗口（token）',
    page: '设置 · 模型 · 默认模型设置 · 上下文与记忆',
    type: 'integer',
    min: 4000,
    max: 2000000,
    risk: AssistantRisk.review,
    read: (s) => s.contextWindowTokens,
    write: (n, v, _) => n.setContextWindowTokens(v! as int),
  ),
];

AssistantSetting? assistantSettingOf(Object? key) =>
    kAssistantSettings.where((s) => s.key == key).firstOrNull;

/// The settings page of the docs library, generated from the whitelist so
/// the docs and the tools never disagree.
String assistantSettingsDoc() => [
  '# 你能改的设置项（由白名单生成）',
  '',
  '用 aicove_settings_get 读当前值，aicove_settings_set 修改。不在这里的设置你改不了，告诉用户去哪个页面。',
  '',
  '| key | 名字 | 位置 | 取值 | 风险 |',
  '|---|---|---|---|---|',
  for (final s in kAssistantSettings)
    '| `${s.key}` | ${s.label} | ${s.page} | ${switch (s.type) {
      'enum' => s.options!.entries.map((e) => '`${e.key}`=${e.value}').join('，'),
      'bool' => 'true／false',
      'number' || 'integer' => '${s.min}～${s.max}',
      _ => '文本',
    }} | ${switch (s.riskOf == null ? s.risk : null) {
      AssistantRisk.reversible => '直接生效，可撤销',
      AssistantRisk.review => '需审核',
      AssistantRisk.major => '需用户确认',
      _ => s.key == 'model.default_chat' ? '同一渠道内换模型直接生效；换到别的渠道需用户确认（聊天会发给另一家）' : '看取值',
    }} |',
].join('\n');
