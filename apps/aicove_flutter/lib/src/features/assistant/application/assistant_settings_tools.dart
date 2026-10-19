import 'dart:convert';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart'
    show ReversibleChange, ToolEffect;

import '../../agent_plugins/file_change_journal.dart';
import '../../plugins/domain/handlers/ai_tool.dart';
import '../../settings/app_settings.dart';
import 'assistant_review.dart';
import 'assistant_settings.dart';

const assistantSettingChangeKind = 'assistant.setting';

/// Settings access of the assistant: only [kAssistantSettings], each change
/// recorded in the journal (ADR0073, batch T3b).
class AssistantSettingsTools {
  AssistantSettingsTools({
    required this.current,
    required this.load,
    required this.notifier,
    required this.journal,
    this.onChanged,
  });

  /// The settings now, without waiting; null before they have loaded.
  final AppSettings? Function() current;
  final Future<AppSettings> Function() load;
  final AppSettingsNotifier Function() notifier;
  final FileChangeJournal journal;
  final void Function()? onChanged;

  static const getTool = 'aicove_settings_get';
  static const setTool = 'aicove_settings_set';

  AssistantRisk? riskOf(String toolName, Map<String, dynamic> args) {
    if (toolName == getTool) return AssistantRisk.readOnly;
    if (toolName != setTool) return null;
    final setting = assistantSettingOf(args['key']);
    final settings = current();
    // Unknown keys and values fail in the tool itself; nothing runs.
    if (setting == null || settings == null) return AssistantRisk.reversible;
    return setting.riskFor(settings, setting.normalize(args['value']).value);
  }

  ApprovalPrompt describe(Map<String, dynamic> args) {
    final setting = assistantSettingOf(args['key']);
    final value = args['value'];
    final shown = setting?.options?[value] ?? value;
    return ApprovalPrompt(
      title: '把「${setting?.label ?? args['key']}」改成 $shown',
      detail: setting?.key == 'model.default_chat'
          ? '之后的聊天会发给这个模型所在的渠道'
          : '可以在「${setting?.page ?? '设置'}」改回来',
    );
  }

  List<AITool> tools() => [
    AITool(
      name: getTool,
      description: '读取你能修改的设置项：当前值、可选值、所在页面和风险。不传 keys 读全部。',
      parameters: const {},
      inputSchema: const {
        'type': 'object',
        'properties': {
          'keys': {
            'type': 'array',
            'items': {'type': 'string'},
          },
        },
      },
      effect: ToolEffect.readDiagnostic,
      handler: (args) async {
        final settings = await load();
        final wanted = [
          if (args['keys'] is List)
            for (final key in args['keys'] as List) key.toString(),
        ];
        return jsonEncode({
          'settings': [
            for (final setting in kAssistantSettings)
              if (wanted.isEmpty || wanted.contains(setting.key))
                setting.describe(settings),
          ],
        });
      },
    ),
    AITool(
      name: setTool,
      description:
          '修改一个设置项（key 见 aicove_settings_get 或资料库 settings）。'
          '可撤销；换到别的渠道的模型需要用户确认。',
      parameters: const {},
      inputSchema: const {
        'type': 'object',
        'properties': {
          'key': {'type': 'string'},
          'value': {'description': '新值，类型按设置项'},
        },
        'required': ['key', 'value'],
      },
      effect: ToolEffect.write,
      handler: (args) async => jsonEncode(await _set(args)),
    ),
  ];

  Future<Map<String, Object?>> _set(Map<String, dynamic> args) async {
    final setting = assistantSettingOf(args['key']);
    if (setting == null) {
      return {'error': 'invalid', 'message': '没有这个设置项或你不能改：${args['key']}'};
    }
    final settings = await load();
    final input = setting.normalize(args['value']);
    final problem = setting.check(settings, input);
    if (problem != null) return {'error': 'invalid', 'message': problem};
    final value = input.value;
    if (setting.read(settings) == value) return {'ok': true, 'change': '没有变化'};
    final shown = setting.options?[value] ?? value ?? '（清空）';
    final description = '把「${setting.label}」改成了 $shown';
    await journal.commit(
      setTool,
      ReversibleChange(
        kind: assistantSettingChangeKind,
        description: description,
        before: {'key': setting.key, 'value': setting.journalState(settings)},
        after: {
          'key': setting.key,
          'value': setting.journalStateAfter(settings, value),
        },
      ),
    );
    onChanged?.call();
    return {'ok': true, 'change': description, 'undo': '用户可以在聊天页撤销这次修改'};
  }
}

/// Writes a whitelisted setting back for undo.
class AssistantSettingApplier extends CheckedChangeApplier {
  AssistantSettingApplier({required this.load, required this.notifier});

  final Future<AppSettings> Function() load;
  final AppSettingsNotifier Function() notifier;

  AssistantSetting _setting(Map<String, Object?> state) =>
      assistantSettingOf(state['key']) ??
      (throw StateError('这个设置项已不在白名单：${state['key']}'));

  @override
  Future<void> apply(Map<String, Object?> state) async =>
      _setting(state).writeState(notifier(), state['value'], await load());

  @override
  Future<bool> isCurrent(Map<String, Object?> state) async =>
      _same(_setting(state).journalState(await load()), state['value']);

  static bool _same(Object? a, Object? b) => jsonEncode(a) == jsonEncode(b);
}
