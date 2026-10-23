import 'dart:convert';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart'
    show ReversibleChange, ToolEffect;

import '../../agent_plugins/file_change_journal.dart';
import '../../plugins/domain/handlers/ai_tool.dart';
import '../../plugins/prompts/plugin_prompts.dart';
import '../../plugins/web_search/web_search_config.dart';
import 'assistant_review.dart';
import 'assistant_tool_group.dart';

const assistantPluginOptionChangeKind = 'assistant.plugin_option';

/// One global plugin option the assistant may read and change: a bool, an
/// integer or a text kept in a plugin's own store.
class AssistantPluginOption {
  const AssistantPluginOption({
    required this.key,
    required this.label,
    required this.page,
    required this.read,
    required this.write,
    this.min,
    this.max,
    this.defaultText,
    this.writeIf,
  });

  final String key;
  final String label;
  final String page;

  /// Integer options have bounds; text options have [defaultText]; the
  /// others are bools.
  final int? min;
  final int? max;

  /// What an empty text puts back.
  final String? defaultText;
  final Object Function() read;
  final Future<void> Function(Object value) write;

  /// Writes the value only while the option still reads `expected`, checked
  /// and written in one turn of its store; false when it does not. Options
  /// without it are checked, then written.
  final Future<bool> Function(Object expected, Object value)? writeIf;

  bool get isInteger => min != null;
  bool get isText => defaultText != null;

  static const maxTextLength = 4000;

  /// The value in this option's type, or null when it does not fit.
  Object? normalize(Object? value) {
    if (isText) {
      if (value is! String || value.length > maxTextLength) return null;
      // Kept as it reads back once stored: a text equal to the default but
      // for surrounding blanks is stored as the default.
      return value.trim().isEmpty || value.trim() == defaultText!.trim()
          ? defaultText
          : value;
    }
    if (!isInteger) return value is bool ? value : null;
    if (value is! num || value != value.roundToDouble()) return null;
    final integer = value.toInt();
    return integer < min! || integer > max! ? null : integer;
  }
}

/// Global options of chat plugins (ADR0073 full access, batch P5). Each
/// change is undoable; options holding keys stay on their pages.
class AssistantPluginOptionTools extends AssistantToolGroup {
  AssistantPluginOptionTools({
    required this.options,
    required this.journal,
    this.onChanged,
  });

  final List<AssistantPluginOption> options;
  final FileChangeJournal journal;
  final void Function()? onChanged;

  static const getTool = 'aicove_plugin_options_get';
  static const setTool = 'aicove_plugin_options_set';

  AssistantPluginOption? optionOf(Object? key) =>
      options.where((o) => o.key == key).firstOrNull;

  @override
  List<AITool> tools() => [
    assistantTool(
      getTool,
      '读插件的全局选项（时间感知、联网搜索、表情包说明等工具提示词）：当前值、取值范围、所在页面。',
      const {},
      const [],
      ToolEffect.readDiagnostic,
      (_) async => {
        'options': [
          for (final option in options)
            {
              'key': option.key,
              'label': option.label,
              'page': option.page,
              'value': option.read(),
              if (option.isInteger) 'range': '${option.min}～${option.max}',
              if (option.isText) 'type': 'text',
            },
        ],
      },
    ),
    assistantTool(
      setTool,
      '改一个插件全局选项（key 见 $getTool）。直接生效，可撤销。'
      '用户嫌表情包太多或太少时，改表情包说明里的使用要求（prompt.sticker）。',
      {
        'key': {'type': 'string'},
        'value': {'description': 'true／false、整数或文本（文本传空字符串恢复默认）'},
      },
      ['key', 'value'],
      ToolEffect.write,
      _set,
    ),
  ];

  @override
  AssistantRisk riskOf(String toolName, Map<String, dynamic> args) =>
      toolName == getTool ? AssistantRisk.readOnly : AssistantRisk.reversible;

  @override
  ApprovalPrompt describe(String toolName, Map<String, dynamic> args) {
    final option = optionOf(args['key']);
    final value = '${args['value']}';
    return ApprovalPrompt(
      title: option?.isText == true
          ? '修改「${option!.label}」'
          : '把「${option?.label ?? args['key']}」改成 $value',
      detail: '可以在「${option?.page ?? '设置'}」改回来',
    );
  }

  Future<Map<String, Object?>> _set(Map<String, dynamic> args) async {
    final option = optionOf(args['key']);
    if (option == null) {
      return assistantToolError('没有这个选项：${args['key']}');
    }
    final value = option.normalize(args['value']);
    if (value == null) {
      return assistantToolError(
        option.isText
            ? '取值应为不超过 ${AssistantPluginOption.maxTextLength} 字的文本'
            : option.isInteger
            ? '取值应为 ${option.min}～${option.max} 的整数'
            : '取值应为 true 或 false',
      );
    }
    final before = option.read();
    if (jsonEncode(before) == jsonEncode(value)) {
      return {'ok': true, 'change': '没有变化'};
    }
    final description = option.isText
        ? '改了「${option.label}」'
        : '把「${option.label}」改成了 $value';
    final change = ReversibleChange(
      kind: assistantPluginOptionChangeKind,
      description: description,
      before: {'key': option.key, 'value': before},
      after: {'key': option.key, 'value': value},
    );
    final writeIf = option.writeIf;
    if (writeIf == null) {
      await journal.commit(setTool, change);
    } else if (await journal.commitIf(
          setTool,
          change,
          () => writeIf(before, value),
        ) ==
        null) {
      return assistantToolError('这个选项刚被改过，请重新读取再改');
    }
    onChanged?.call();
    return {'ok': true, 'change': description, 'undo': '用户可以在聊天页撤销这次修改'};
  }
}

/// Writes a plugin option back for undo.
class AssistantPluginOptionApplier extends CheckedChangeApplier {
  AssistantPluginOptionApplier(this.options);

  final List<AssistantPluginOption> Function() options;

  AssistantPluginOption _option(Map<String, Object?> state) =>
      options().where((o) => o.key == state['key']).firstOrNull ??
      (throw StateError('这个选项已经没有了：${state['key']}'));

  @override
  Future<void> apply(Map<String, Object?> state) =>
      _option(state).write(state['value']!);

  @override
  Future<bool> isCurrent(Map<String, Object?> state) async =>
      jsonEncode(_option(state).read()) == jsonEncode(state['value']);

  @override
  Future<bool> applyIfCurrent(
    Map<String, Object?> expected,
    Map<String, Object?> state,
  ) {
    final writeIf = _option(state).writeIf;
    return writeIf == null
        ? super.applyIfCurrent(expected, state)
        : writeIf(expected['value']!, state['value']!);
  }
}

/// The plugin options the assistant may change, bound to their stores.
List<AssistantPluginOption> assistantPluginOptions({
  required ({bool messageTimestamp, bool currentTime}) Function() time,
  required Future<void> Function({bool? messageTimestamp, bool? currentTime})
  setTime,
  required WebSearchConfig Function() webSearch,
  required Future<void> Function(WebSearchConfig config) setWebSearch,
  required PluginPrompts Function() prompts,
  required Future<void> Function(PluginPromptSlot slot, String text) setPrompt,
  required Future<bool> Function(
    PluginPromptSlot slot,
    String expected,
    String text,
  )
  setPromptIf,
}) => [
  for (final slot in PluginPromptSlot.values)
    AssistantPluginOption(
      key: 'prompt.${slot.name}',
      label: '${slot.plugin}：${slot.title}（所有角色共用；${slot.hint}）',
      page: '设置 · 聊天插件 · 工具提示词',
      defaultText: slot.defaultText,
      read: () => prompts().of(slot),
      write: (v) => setPrompt(slot, v as String),
      writeIf: (expected, v) =>
          setPromptIf(slot, expected as String, v as String),
    ),
  AssistantPluginOption(
    key: 'time.message_timestamp',
    label: '时间感知：历史消息带发送时间',
    page: '设置 · 聊天插件 · 时间感知',
    read: () => time().messageTimestamp,
    write: (v) => setTime(messageTimestamp: v as bool),
  ),
  AssistantPluginOption(
    key: 'time.current_time',
    label: '时间感知：告诉模型现在几点',
    page: '设置 · 聊天插件 · 时间感知',
    read: () => time().currentTime,
    write: (v) => setTime(currentTime: v as bool),
  ),
  AssistantPluginOption(
    key: 'web_search.replace_builtin',
    label: '联网搜索：用本插件替代模型自带的搜索',
    page: '设置 · 聊天插件 · 联网搜索',
    read: () => webSearch().replaceModelBuiltinSearch,
    write: (v) => setWebSearch(
      webSearch().copyWith(replaceModelBuiltinSearch: v as bool),
    ),
  ),
  AssistantPluginOption(
    key: 'web_search.num_results',
    label: '联网搜索：每次返回几条结果',
    page: '设置 · 聊天插件 · 联网搜索',
    min: 1,
    max: WebSearchConfig.maxResults,
    read: () => webSearch().numResults,
    write: (v) => setWebSearch(webSearch().copyWith(numResults: v as int)),
  ),
  AssistantPluginOption(
    key: 'web_search.max_characters',
    label: '联网搜索：每条结果带回的最多字数',
    page: '设置 · 聊天插件 · 联网搜索',
    min: WebSearchConfig.minCharacters,
    max: WebSearchConfig.maxCharacters,
    read: () => webSearch().maxCharactersPerResult,
    write: (v) =>
        setWebSearch(webSearch().copyWith(maxCharactersPerResult: v as int)),
  ),
];
