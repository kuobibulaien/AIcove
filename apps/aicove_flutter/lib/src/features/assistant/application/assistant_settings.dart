import 'dart:io';

import '../../../core/utils/message_formatter.dart';
import '../../settings/app_settings.dart';
import '../../../ui/theme/moe_glass_theme.dart' show MoeSurfaceMaterial;
import '../../../ui/theme/tokens.dart' show kMinGlassBlurSigma, kMaxGlassBlurSigma;
import '../domain/assistant_onboarding.dart' show providerHasApiKey;
import 'assistant_review.dart';
import 'assistant_role_tools.dart' show kAssistantBuiltinImages;

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
    this.stateAt,
    this.choicesOf,
  });

  /// An empty string clears the setting.
  final bool nullable;

  /// What the change journal keeps, when the value alone cannot restore the
  /// setting (the default model is the head of an ordered list): the state
  /// now, the state after writing a value, and how to write a state back.
  final Object? Function(AppSettings settings)? stateOf;
  final Object? Function(AppSettings settings, Object? value)? nextState;
  final Future<void> Function(
    AppSettingsNotifier settings,
    Object? state,
    AppSettings current,
  )?
  restore;

  /// The state now of what [recorded] (a journal state) is about, for
  /// settings whose state names its target (a wallpaper, a punctuation set):
  /// undo checks that target even after another one became current. Null
  /// when the target is gone.
  final Object? Function(AppSettings settings, Object? recorded)? stateAt;

  /// Allowed values worked out from the settings (value to label), shown
  /// like [options] for a `string` setting.
  final Map<String, String> Function(AppSettings settings)? choicesOf;

  Object? journalState(AppSettings settings) =>
      (stateOf ?? read).call(settings);

  /// The state now, comparable with the journal state [recorded].
  Object? stateLike(AppSettings settings, Object? recorded) =>
      stateAt == null ? journalState(settings) : stateAt!(settings, recorded);

  Object? journalStateAfter(AppSettings settings, Object? value) =>
      nextState?.call(settings, value) ?? value;

  Future<void> writeState(
    AppSettingsNotifier notifier,
    Object? state,
    AppSettings current,
  ) =>
      restore?.call(notifier, state, current) ??
      write(notifier, state, current);

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
    'options': ?(options ?? choicesOf?.call(settings)),
    'min': ?min,
    'max': ?max,
    'risk': switch (riskOf == null ? risk : null) {
      AssistantRisk.reversible => '直接生效，可撤销',
      AssistantRisk.review => '默认直接生效，可撤销',
      AssistantRisk.major => '默认直接生效；每次询问模式下需确认',
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

/// The selected wallpaper as the settings tool names it: a built-in value,
/// or `custom:id` for an imported one.
String _wallpaperValue(AppSettings s) => s.globalWallpaper == GlobalWallpaper.custom
    ? 'custom:${s.globalWallpaperCustomId ?? ''}'
    : s.globalWallpaper.value;

Map<String, String> _wallpaperChoices(AppSettings s) => {
  for (final wallpaper in GlobalWallpaper.values)
    if (wallpaper != GlobalWallpaper.custom) wallpaper.value: wallpaper.label,
  for (final (index, item) in s.globalWallpaperCustoms.indexed)
    'custom:${item.id}': '自定义壁纸 ${index + 1}',
};

Future<void> _selectWallpaper(
  AppSettingsNotifier n,
  Object? value,
  AppSettings current,
) {
  final text = value! as String;
  if (!text.startsWith('custom:')) {
    return n.setGlobalWallpaper(
      GlobalWallpaper.values.firstWhere((w) => w.value == text),
    );
  }
  final id = text.substring('custom:'.length);
  if (!current.globalWallpaperCustoms.any((item) => item.id == id)) {
    throw StateError('那张自定义壁纸已经删除');
  }
  return n.selectCustomGlobalWallpaper(id);
}

/// The wallpaper whose mask and blur the settings change: the selected one,
/// or null with none selected (or a deleted custom one).
({String key, bool custom})? _activeWallpaper(AppSettings s) {
  final custom = s.activeCustomWallpaper;
  if (custom != null) return (key: custom.id, custom: true);
  if (s.globalWallpaper == GlobalWallpaper.none ||
      s.globalWallpaper == GlobalWallpaper.custom) {
    return null;
  }
  return (key: s.globalWallpaper.value, custom: false);
}

/// One wallpaper's style as the journal keeps it; null once a custom
/// wallpaper is deleted.
Map<String, Object?>? _wallpaperStyleState(
  AppSettings s,
  Object? key,
  Object? custom,
) {
  if (key is! String || custom is! bool) return null;
  if (custom && !s.globalWallpaperCustoms.any((item) => item.id == key)) {
    return null;
  }
  return {
    'key': key,
    'custom': custom,
    'style': s.wallpaperStyleFor(key, custom: custom).toJson(),
  };
}

/// Mask or blur of the selected wallpaper. The record names the wallpaper,
/// so undo after switching wallpapers changes the one it was made on.
AssistantSetting _wallpaperStyleSetting({
  required String key,
  required String label,
  required double max,
  required double Function(WallpaperStyle style) get,
  required WallpaperStyle Function(WallpaperStyle style, double value) set,
}) => AssistantSetting(
  key: key,
  label: label,
  page: '设置 · 通用 · 外观 · 全局壁纸 · 编辑',
  type: 'number',
  min: 0,
  max: max,
  validate: (s, _) =>
      _activeWallpaper(s) == null ? '现在没有选全局壁纸，先选一张再调' : null,
  read: (s) => get(s.activeWallpaperStyle),
  write: (n, v, s) {
    final wallpaper = _activeWallpaper(s)!;
    final style = s.wallpaperStyleFor(wallpaper.key, custom: wallpaper.custom);
    return n.setGlobalWallpaperStyle(wallpaper.key, set(style, v! as double));
  },
  stateOf: (s) {
    final wallpaper = _activeWallpaper(s);
    return wallpaper == null
        ? null
        : _wallpaperStyleState(s, wallpaper.key, wallpaper.custom);
  },
  nextState: (s, v) {
    final wallpaper = _activeWallpaper(s)!;
    final style = s.wallpaperStyleFor(wallpaper.key, custom: wallpaper.custom);
    return {
      'key': wallpaper.key,
      'custom': wallpaper.custom,
      'style': set(style, v! as double).toJson(),
    };
  },
  stateAt: (s, recorded) => recorded is Map
      ? _wallpaperStyleState(s, recorded['key'], recorded['custom'])
      : null,
  restore: (n, state, current) {
    final record = state as Map?;
    final saved = _wallpaperStyleState(
      current,
      record?['key'],
      record?['custom'],
    );
    if (record == null || saved == null) {
      throw StateError('那张壁纸已经删除');
    }
    final custom = record['custom'] as bool;
    return n.setGlobalWallpaperStyle(
      record['key'] as String,
      WallpaperStyle.fromJson(record['style'], custom: custom),
    );
  },
);

/// `FC96AA` from `#fc96aa`; null when it is not a six-digit hex color.
String? _hexColor(String value) {
  final hex = value.trim().replaceFirst('#', '').toUpperCase();
  return RegExp(r'^[0-9A-F]{6}$').hasMatch(hex) ? hex : null;
}

/// A custom color also switches the skin, so undo puts the skin and both
/// colors back together.
Map<String, Object?> _skinState(AppSettings s) => {
  'skin': s.interfaceSkin.value,
  'accent': s.accentColor,
  'chat_background': s.chatBackgroundColor.value,
};

Future<void> _restoreSkin(
  AppSettingsNotifier n,
  Object? state,
  AppSettings _,
) {
  final record = state! as Map;
  return n.setSkinColors(
    skin:
        InterfaceSkin.tryParse(record['skin'] as String?) ??
        InterfaceSkin.custom,
    accentColor: record['accent'] as String,
    chatBackground: ChatBackgroundColor.fromValue(
      record['chat_background'] as String?,
    ),
  );
}

MessageChunkPunctuationSet? _punctuationSet(AppSettings s, Object? id) => s
    .messageFormatConfig
    .chunkPunctuationSets
    .where((set) => set.id == id)
    .firstOrNull;

/// One set's punctuation as the journal keeps it, with the runtime list the
/// chat splits by (it can differ from the set's own) while the set is
/// active; once another set is active, [recordedRuntime] stands in, so only
/// the set is compared. Null once the set is deleted.
Map<String, Object?>? _setPunctuationsState(
  AppSettings s,
  Object? id, [
  Object? recordedRuntime,
]) {
  final config = s.messageFormatConfig;
  final set = _punctuationSet(s, id);
  if (set == null) return null;
  final active = set.id == config.activeChunkPunctuationSetId;
  return {
    'set': set.id,
    'punctuations': set.punctuations,
    'runtime': active ? config.chunkPunctuations : recordedRuntime,
  };
}

List<String> _tokens(Object? list) => [
  for (final token in list as List? ?? const []) '$token',
];

/// Writes a set's punctuation back, and the runtime list too while that set
/// is still active.
Future<void> _restoreSetPunctuations(
  AppSettingsNotifier n,
  Object? state,
  AppSettings current,
) {
  final record = state! as Map;
  final id = record['set'] as String;
  var config = current.messageFormatConfig.withSetPunctuations(
    id,
    _tokens(record['punctuations']),
  );
  if (config == null) throw StateError('这套分段标点已经删除');
  if (id == config.activeChunkPunctuationSetId && record['runtime'] != null) {
    config = config.copyWith(chunkPunctuations: _tokens(record['runtime']));
  }
  return n.updateMessageFormatConfig(config);
}

Future<void> _restoreActiveSet(
  AppSettingsNotifier n,
  Object? state,
  AppSettings current,
) {
  final record = state! as Map;
  final config = current.messageFormatConfig.withActiveSet(
    record['set'] as String,
    _tokens(record['punctuations']),
  );
  if (config == null) throw StateError('这套分段标点已经删除');
  return n.updateMessageFormatConfig(config);
}

/// The picture path for `builtin:名字`, an asset path or an existing file;
/// null when there is no such picture.
String? _avatarPath(String value) {
  final text = value.trim();
  if (text.startsWith('builtin:')) {
    return kAssistantBuiltinImages[text.substring('builtin:'.length)];
  }
  if (text.startsWith('assets/')) {
    return kAssistantBuiltinImages.containsValue(text) ? text : null;
  }
  return text.isNotEmpty && File(text).existsSync() ? text : null;
}

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
    label: '用户发消息自动回底',
    page: '聊天页「更多 · 聊天界面 · 行为」',
    type: 'bool',
    read: (s) => s.autoScrollOnSend,
    write: (n, v, _) => n.setAutoScrollOnSend(v! as bool),
  ),
  AssistantSetting(
    key: 'chat.auto_scroll_on_ai_reply',
    label: 'AI 发消息自动回底',
    page: '聊天页「更多 · 聊天界面 · 行为」',
    type: 'bool',
    read: (s) => s.autoScrollOnAiReply,
    write: (n, v, _) => n.setAutoScrollOnAiReply(v! as bool),
  ),
  AssistantSetting(
    key: 'chat.bubble_show_thinking',
    label: '气泡模式显示思维链',
    page: '聊天页「更多 · 聊天界面 · 界面 · 更多选项」',
    type: 'bool',
    read: (s) => s.bubbleShowThinking,
    write: (n, v, _) => n.setBubbleShowThinking(v! as bool),
  ),
  AssistantSetting(
    key: 'chat.document_show_thinking',
    label: '文档模式显示思维链',
    page: '聊天页「更多 · 聊天界面 · 界面 · 更多选项」',
    type: 'bool',
    read: (s) => s.documentShowThinking,
    write: (n, v, _) => n.setDocumentShowThinking(v! as bool),
  ),
  AssistantSetting(
    key: 'chat.document_show_tool_calls',
    label: '文档模式显示工具调用',
    page: '聊天页「更多 · 聊天界面 · 界面 · 更多选项」',
    type: 'bool',
    read: (s) => s.documentShowToolCalls,
    write: (n, v, _) => n.setDocumentShowToolCalls(v! as bool),
  ),
  AssistantSetting(
    key: 'chat.message_chunking',
    label: '启用消息分段',
    page: '设置 · 通用 · 聊天样式与分段',
    type: 'bool',
    // The chat reads the format config; `message_chunking_enabled` is a
    // legacy field nothing splits by any more.
    read: (s) => s.messageFormatConfig.enableChunking,
    write: (n, v, s) => n.updateMessageFormatConfig(
      s.messageFormatConfig.copyWith(enableChunking: v! as bool),
    ),
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
    restore: (n, state, _) => n.setDefaultChatModels([
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
  AssistantSetting(
    key: 'model.compaction',
    label: '压缩模型（整理长对话；留空跟随默认聊天模型）',
    page: '设置 · 模型 · 默认模型设置 · 上下文与记忆',
    type: 'string',
    nullable: true,
    riskOf: _modelRisk,
    validate: _validChatModel,
    read: (s) => s.compactionModel.isEmpty ? null : s.compactionModel,
    write: (n, v, s) =>
        n.setCompactionModel(v == null ? '' : _modelRef(s, v as String)),
    // The journal keeps the reference as stored, so undo can tell it is
    // still in effect.
    nextState: (s, v) => v == null ? null : _modelRef(s, v as String),
  ),
  AssistantSetting(
    key: 'model.memory',
    label: '记忆模型（整理长期记忆；留空跟随压缩模型）',
    page: '设置 · 模型 · 默认模型设置 · 上下文与记忆',
    type: 'string',
    nullable: true,
    riskOf: _modelRisk,
    validate: _validChatModel,
    read: (s) => s.memoryModel.isEmpty ? null : s.memoryModel,
    write: (n, v, s) =>
        n.setMemoryModel(v == null ? '' : _modelRef(s, v as String)),
    // The journal keeps the reference as stored, so undo can tell it is
    // still in effect.
    nextState: (s, v) => v == null ? null : _modelRef(s, v as String),
  ),
  // One entry per stored value: undo must write back the material it
  // changed, whichever material is showing by then.
  AssistantSetting(
    key: 'appearance.frosted_blur',
    label: '磨砂材质的模糊度',
    page: '设置 · 通用 · 材质等级',
    type: 'number',
    min: kMinGlassBlurSigma,
    max: kMaxGlassBlurSigma,
    read: (s) => s.frostedBlurSigma,
    write: (n, v, _) => n.setFrostedBlurSigma(v! as double),
  ),
  AssistantSetting(
    key: 'appearance.frosted_tint',
    label: '磨砂材质的底色填充（0～1）',
    page: '设置 · 通用 · 材质等级',
    type: 'number',
    min: 0,
    max: 1,
    read: (s) => s.frostedTintFill,
    write: (n, v, _) => n.setFrostedTintFill(v! as double),
  ),
  AssistantSetting(
    key: 'appearance.glass_blur',
    label: '玻璃材质的模糊度',
    page: '设置 · 通用 · 材质等级',
    type: 'number',
    min: kMinGlassBlurSigma,
    max: kMaxGlassBlurSigma,
    read: (s) => s.glassBlurSigma,
    write: (n, v, _) => n.setGlassBlurSigma(v! as double),
  ),
  AssistantSetting(
    key: 'appearance.glass_tint',
    label: '玻璃材质的底色填充（0～1）',
    page: '设置 · 通用 · 材质等级',
    type: 'number',
    min: 0,
    max: 1,
    read: (s) => s.glassTintFill,
    write: (n, v, _) => n.setGlassTintFill(v! as double),
  ),
  AssistantSetting(
    key: 'appearance.wallpaper',
    label: '全局壁纸（内置壁纸，或 custom:id 选用户导入过的自定义壁纸）',
    page: '设置 · 通用 · 外观 · 全局壁纸',
    type: 'string',
    choicesOf: _wallpaperChoices,
    validate: (s, v) =>
        _wallpaperChoices(s).containsKey(v) ? null : '没有这张壁纸：$v',
    read: _wallpaperValue,
    write: _selectWallpaper,
  ),
  _wallpaperStyleSetting(
    key: 'appearance.wallpaper_mask',
    label: '当前全局壁纸的遮罩（0～1，越大越淡）',
    max: 1,
    get: (style) => style.mask,
    set: (style, v) => style.copyWith(mask: v),
  ),
  _wallpaperStyleSetting(
    key: 'appearance.wallpaper_blur',
    label: '当前全局壁纸的模糊度',
    max: kMaxWallpaperBlur,
    get: (style) => style.blur,
    set: (style, v) => style.copyWith(blur: v),
  ),
  AssistantSetting(
    key: 'appearance.accent_color',
    label: '主题色（六位十六进制，如 FC96AA；改了会切到自定义皮肤）',
    page: '设置 · 通用 · 高级 · 自定义皮肤',
    type: 'string',
    validate: (_, v) =>
        _hexColor(v! as String) == null ? '颜色要写成六位十六进制，如 FC96AA' : null,
    read: (s) => s.accentColor,
    write: (n, v, _) => n.setCustomSkin(accentColor: _hexColor(v! as String)),
    stateOf: _skinState,
    nextState: (s, v) => {
      ..._skinState(s),
      'skin': InterfaceSkin.custom.value,
      'accent': _hexColor(v! as String),
    },
    restore: _restoreSkin,
  ),
  AssistantSetting(
    key: 'appearance.chat_background',
    label: '聊天背景色（改了会切到自定义皮肤）',
    page: '设置 · 通用 · 高级 · 自定义皮肤',
    type: 'enum',
    options: {
      for (final color in ChatBackgroundColor.values) color.value: color.label,
    },
    read: (s) => s.chatBackgroundColor.value,
    write: (n, v, _) => n.setCustomSkin(
      chatBackground: ChatBackgroundColor.fromValue(v! as String),
    ),
    stateOf: _skinState,
    nextState: (s, v) => {
      ..._skinState(s),
      'skin': InterfaceSkin.custom.value,
      'chat_background': v,
    },
    restore: _restoreSkin,
  ),
  AssistantSetting(
    key: 'chat.image_preview_scale',
    label: '图片预览大小',
    page: '设置 · 通用 · 聊天',
    type: 'number',
    min: kMinImagePreviewScale,
    max: kMaxImagePreviewScale,
    read: (s) => s.imagePreviewScale,
    write: (n, v, _) => n.setImagePreviewScale(v! as double),
  ),
  AssistantSetting(
    key: 'chat.filter_punctuation',
    label: '过滤句末标点',
    page: '设置 · 通用 · 聊天样式与分段',
    type: 'bool',
    read: (s) => s.messageFormatConfig.filterPunctuation,
    write: (n, v, s) => n.updateMessageFormatConfig(
      s.messageFormatConfig.copyWith(filterPunctuation: v! as bool),
    ),
  ),
  AssistantSetting(
    key: 'chat.filter_punctuations',
    label: '要过滤的句末标点（空格分隔；「过滤句末标点」开着才生效）',
    page: '设置 · 通用 · 聊天样式与分段',
    type: 'string',
    read: (s) => s.messageFormatConfig.filterPunctuations.join(' '),
    nextState: (_, v) =>
        MessageFormatConfig.parsePunctuations(v! as String).join(' '),
    write: (n, v, s) => n.updateMessageFormatConfig(
      s.messageFormatConfig.copyWith(
        filterPunctuations: MessageFormatConfig.parsePunctuations(v! as String),
      ),
    ),
  ),
  AssistantSetting(
    key: 'chat.chunk_punctuation_set',
    label: '分段用哪套标点',
    page: '设置 · 通用 · 聊天样式与分段 · 分段标点',
    type: 'string',
    choicesOf: (s) => {
      for (final set in s.messageFormatConfig.chunkPunctuationSets)
        set.id: set.displayName,
    },
    validate: (s, v) => _punctuationSet(s, v) == null ? '没有这套标点：$v' : null,
    read: (s) => s.messageFormatConfig.activeChunkPunctuationSetId,
    write: (n, v, s) => _restoreActiveSet(n, {
      'set': v,
      'punctuations': _punctuationSet(s, v)!.punctuations,
    }, s),
    // The runtime list goes with the id: it can differ from the set's own.
    stateOf: (s) => {
      'set': s.messageFormatConfig.activeChunkPunctuationSetId,
      'punctuations': s.messageFormatConfig.chunkPunctuations,
    },
    nextState: (s, v) => {
      'set': v,
      'punctuations': _punctuationSet(s, v)!.punctuations,
    },
    restore: _restoreActiveSet,
  ),
  AssistantSetting(
    key: 'chat.chunk_punctuations',
    label: '当前这套分段标点里的标点（空格分隔；空字符串表示这套不按标点切）',
    page: '设置 · 通用 · 聊天样式与分段 · 分段标点',
    type: 'string',
    read: (s) =>
        s.messageFormatConfig.activeChunkPunctuationSet?.punctuations.join(' '),
    write: (n, v, s) {
      final punctuations = MessageFormatConfig.parsePunctuations(v! as String);
      return _restoreSetPunctuations(n, {
        'set': s.messageFormatConfig.activeChunkPunctuationSetId,
        'punctuations': punctuations,
        'runtime': punctuations,
      }, s);
    },
    // The record names the set, so undo edits that set even after another
    // one was made active.
    stateOf: (s) => _setPunctuationsState(
      s,
      s.messageFormatConfig.activeChunkPunctuationSetId,
    ),
    nextState: (s, v) {
      final punctuations = MessageFormatConfig.parsePunctuations(v! as String);
      return {
        'set': s.messageFormatConfig.activeChunkPunctuationSetId,
        'punctuations': punctuations,
        'runtime': punctuations,
      };
    },
    stateAt: (s, recorded) => recorded is Map
        ? _setPunctuationsState(s, recorded['set'], recorded['runtime'])
        : null,
    restore: _restoreSetPunctuations,
  ),
  AssistantSetting(
    key: 'chat.min_segment_length',
    label: '分段最短字数（更短的段会并到相邻段）',
    page: '设置 · 通用 · 聊天样式与分段',
    type: 'integer',
    min: 0,
    max: 100,
    read: (s) => s.messageFormatConfig.minSegmentLength,
    write: (n, v, s) => n.updateMessageFormatConfig(
      s.messageFormatConfig.copyWith(minSegmentLength: v! as int),
    ),
  ),
  AssistantSetting(
    key: 'chat.protect_quotes',
    label: '分段时不切开引号里的话',
    page: '设置 · 通用 · 聊天样式与分段',
    type: 'bool',
    read: (s) => s.messageFormatConfig.protectQuotes,
    write: (n, v, s) => n.updateMessageFormatConfig(
      s.messageFormatConfig.copyWith(protectQuotes: v! as bool),
    ),
  ),
  AssistantSetting(
    key: 'chat.stream_segment_delay',
    label: '生成时分段消息之间的间隔（秒）',
    page: '调试 · 消息分段',
    type: 'number',
    min: 0,
    max: 5,
    read: (s) => s.streamSegmentDelaySeconds,
    write: (n, v, _) => n.setStreamSegmentDelaySeconds(v! as double),
  ),
  AssistantSetting(
    key: 'profile.user_avatar',
    label: '我的头像（builtin:名字 用内置图，或填某张已有图片的路径；用户自己的新图片要用户亲手在个人资料页选）',
    page: '设置 · 个人资料',
    type: 'string',
    nullable: true,
    validate: (_, v) => _avatarPath(v! as String) == null
        ? '找不到这张图片（内置图：${kAssistantBuiltinImages.keys.map((k) => 'builtin:$k').join('、')}）'
        : null,
    read: (s) {
      final avatar = s.userAvatar?.trim();
      return avatar == null || avatar.isEmpty ? null : avatar;
    },
    nextState: (_, v) => v == null ? null : _avatarPath(v as String),
    // Undo puts the old path back even if that file is gone: the avatar
    // falls back to the default picture.
    write: (n, v, _) {
      final text = v as String?;
      return n.setUserAvatar(text == null ? null : _avatarPath(text) ?? text);
    },
  ),
  AssistantSetting(
    key: 'window.close_behavior',
    label: '关闭窗口时（Windows）',
    page: '设置 · 通用 · 高级',
    type: 'enum',
    options: {
      for (final behavior in WindowsCloseBehavior.values)
        behavior.value: behavior.label,
    },
    read: (s) => s.windowsCloseBehavior.value,
    write: (n, v, _) => n.setWindowsCloseBehavior(
      WindowsCloseBehavior.values.firstWhere((b) => b.value == v),
    ),
  ),
  AssistantSetting(
    key: 'window.controls_side',
    label: '窗口按钮位置（Windows）',
    page: '设置 · 通用 · 高级',
    type: 'enum',
    options: {
      for (final side in WindowControlButtonSide.values) side.value: side.label,
    },
    read: (s) => s.windowsWindowControlsSide.value,
    write: (n, v, _) => n.setWindowsWindowControlsSide(
      WindowControlButtonSide.values.firstWhere((b) => b.value == v),
    ),
  ),
  ..._autoReplySettings,
];

AssistantSetting _autoReply({
  required String key,
  required String label,
  required String type,
  required Object? Function(AutoReplySettings settings) read,
  required AutoReplySettings Function(AutoReplySettings settings, Object? v)
  apply,
  num? min,
  num? max,
  String? Function(AppSettings settings, Object? value)? validate,
  String page = '设置 · 聊天插件 · 主动关怀',
}) => AssistantSetting(
  key: 'auto_reply.$key',
  label: '主动关怀：$label',
  page: page,
  type: type,
  min: min,
  max: max,
  validate: validate,
  read: (s) => read(s.autoReplySettings),
  write: (n, v, s) =>
      n.updateAutoReplySettings(apply(s.autoReplySettings, v)),
);

final _clockPattern = RegExp(r'^([01]\d|2[0-3]):[0-5]\d$');

String? _validClock(AppSettings _, Object? value) =>
    _clockPattern.hasMatch(value as String) ? null : '时间格式应为 HH:mm，比如 23:00';

final List<AssistantSetting> _autoReplySettings = [
  _autoReply(
    key: 'daily_limit',
    label: '每天最多几条',
    type: 'integer',
    min: 1,
    max: 6,
    read: (a) => a.dailyLimit,
    apply: (a, v) => a.copyWith(dailyLimit: v! as int),
  ),
  _autoReply(
    key: 'min_interval_minutes',
    label: '两条之间至少隔几分钟',
    type: 'integer',
    min: 30,
    max: 360,
    read: (a) => a.minIntervalMinutes,
    apply: (a, v) => a.copyWith(minIntervalMinutes: v! as int),
  ),
  _autoReply(
    key: 'quiet_hours',
    label: '夜间免打扰',
    type: 'bool',
    read: (a) => a.quietHoursEnabled,
    apply: (a, v) => a.copyWith(quietHoursEnabled: v! as bool),
  ),
  _autoReply(
    key: 'quiet_start',
    label: '免打扰开始时间（HH:mm）',
    type: 'string',
    validate: _validClock,
    read: (a) => a.quietHoursStart,
    apply: (a, v) => a.copyWith(quietHoursStart: v! as String),
  ),
  _autoReply(
    key: 'quiet_end',
    label: '免打扰结束时间（HH:mm）',
    type: 'string',
    validate: _validClock,
    read: (a) => a.quietHoursEnd,
    apply: (a, v) => a.copyWith(quietHoursEnd: v! as String),
  ),
  _autoReply(
    key: 'ai_reminders',
    label: '让 AI 帮你记提醒',
    type: 'bool',
    read: (a) => a.allowAiSetReminders,
    apply: (a, v) => a.copyWith(allowAiSetReminders: v! as bool),
  ),
  _autoReply(
    key: 'proactive_calls',
    label: '允许主动打电话',
    type: 'bool',
    read: (a) => a.allowProactiveCalls,
    apply: (a, v) => a.copyWith(allowProactiveCalls: v! as bool),
  ),
  _autoReply(
    key: 'exact_alarm',
    label: '更准时（Android 还要在系统里允许精确闹钟）',
    type: 'bool',
    page: '设置 · 聊天插件 · 主动关怀 · 更多设置',
    read: (a) => a.allowExactAlarm,
    apply: (a, v) => a.copyWith(allowExactAlarm: v! as bool),
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
  '界面被改乱、用户想恢复默认时，用 aicove_settings_reset_interface 一次恢复全局界面设置（默认直接生效，可撤销）。',
  '',
  '| key | 名字 | 位置 | 取值 | 风险 |',
  '|---|---|---|---|---|',
  for (final s in kAssistantSettings)
    '| `${s.key}` | ${s.label} | ${s.page} | ${switch (s.type) {
      'enum' => s.options!.entries.map((e) => '`${e.key}`=${e.value}').join('，'),
      'bool' => 'true／false',
      'number' || 'integer' => '${s.min}～${s.max}',
      _ => s.choicesOf == null ? '文本' : '文本（可选值用 aicove_settings_get 查）',
    }} | ${switch (s.riskOf == null ? s.risk : null) {
      AssistantRisk.reversible => '直接生效，可撤销',
      AssistantRisk.review => '默认直接生效，可撤销',
      AssistantRisk.major => '默认直接生效；每次询问模式下需确认',
      _ => s.key == 'model.default_chat' ? '同一渠道内换模型直接生效；换到别的渠道会把聊天发给另一家服务商' : '看取值',
    }} |',
].join('\n');
