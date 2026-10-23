import 'dart:convert';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart'
    show ReversibleChange, ToolEffect;

import '../../../core/sync/cloud_setting_policy.dart'
    show canonicalSettingJson;
import '../../agent_plugins/file_change_journal.dart';
import '../../plugins/domain/handlers/ai_tool.dart';
import '../../settings/app_settings.dart';
import 'assistant_review.dart';
import 'assistant_settings.dart';

const assistantSettingChangeKind = 'assistant.setting';
const assistantInterfaceResetChangeKind = 'assistant.interface_reset';

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
  static const resetTool = 'aicove_settings_reset_interface';

  /// Writing tools of this group, which [describe] handles.
  static bool describes(String toolName) =>
      toolName == setTool || toolName == resetTool;

  AssistantRisk? riskOf(String toolName, Map<String, dynamic> args) {
    if (toolName == getTool) return AssistantRisk.readOnly;
    // The user confirms every reset: it changes many settings at once.
    if (toolName == resetTool) return AssistantRisk.major;
    if (toolName != setTool) return null;
    final setting = assistantSettingOf(args['key']);
    final settings = current();
    // Unknown keys and values fail in the tool itself; nothing runs.
    if (setting == null || settings == null) return AssistantRisk.reversible;
    return setting.riskFor(settings, setting.normalize(args['value']).value);
  }

  ApprovalPrompt describe(String toolName, Map<String, dynamic> args) {
    if (toolName == resetTool) {
      return const ApprovalPrompt(
        title: '恢复默认界面设置',
        detail:
            '深浅色、材质、皮肤、全局壁纸、缩放、聊天样式、分段和思维链显示回到新装时的样子；'
            '聊天记录、角色和各聊天自己的样式、模型和渠道都不变，可以在聊天页撤销',
      );
    }
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
          '可撤销；换到别的渠道的模型会把聊天发给另一家服务商。',
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
    AITool(
      name: resetTool,
      description:
          '把全局界面设置恢复成新装时的样子（深浅色、材质、皮肤、全局壁纸、缩放、聊天样式、分段、思维链显示）。'
          '用户说界面被改乱了、想恢复默认时用。不动聊天记录、角色和各聊天自己的样式、模型和渠道、用户资料。'
          '开启「修改前每次问我」后需确认，可撤销。',
      parameters: const {},
      inputSchema: const {'type': 'object', 'properties': {}},
      effect: ToolEffect.write,
      handler: (_) async => jsonEncode(await _reset()),
    ),
  ];

  Future<Map<String, Object?>> _reset() async {
    final n = notifier();
    final before = await n.readInterfaceSettings();
    final after = interfaceResetPatch();
    if (canonicalSettingJson(before) == canonicalSettingJson(after)) {
      return {'ok': true, 'change': '界面设置已经是默认的'};
    }
    const description = '把界面设置恢复成了默认';
    final entry = await journal.commitIf(
      resetTool,
      ReversibleChange(
        kind: assistantInterfaceResetChangeKind,
        description: description,
        before: before,
        after: after,
      ),
      () => AssistantInterfaceResetApplier(
        notifier: notifier,
      ).applyIfCurrent(before, after),
    );
    if (entry == null) {
      return {'error': 'conflict', 'message': '界面设置刚被改过，请重新再试'};
    }
    onChanged?.call();
    return {'ok': true, 'change': description, 'undo': '用户可以在聊天页撤销这次修改'};
  }

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
    final before = {'key': setting.key, 'value': setting.journalState(settings)};
    final after = {
      'key': setting.key,
      'value': setting.journalStateAfter(settings, value),
    };
    // Compares what would be written: a color equal to the stored custom one
    // still switches a preset skin to custom.
    if (AssistantSettingApplier._same(before['value'], after['value'])) {
      return {'ok': true, 'change': '没有变化'};
    }
    final shown =
        setting.options?[value] ??
        setting.choicesOf?.call(settings)[value] ??
        value ??
        '（清空）';
    final description = '把「${setting.label}」改成了 $shown';
    // Written only if the setting still holds what the record calls
    // `before`, checked under the settings lock inside the journal lock.
    final entry = await journal.commitIf(
      setTool,
      ReversibleChange(
        kind: assistantSettingChangeKind,
        description: description,
        before: before,
        after: after,
      ),
      () => AssistantSettingApplier(
        notifier: notifier,
      ).applyIfCurrent(before, after),
    );
    if (entry == null) {
      return {'error': 'conflict', 'message': '这项设置刚被改过，请重新读取再改'};
    }
    onChanged?.call();
    return {'ok': true, 'change': description, 'undo': '用户可以在聊天页撤销这次修改'};
  }
}

/// Writes a whitelisted setting back for undo.
class AssistantSettingApplier extends CheckedChangeApplier {
  AssistantSettingApplier({required this.notifier});

  final AppSettingsNotifier Function() notifier;

  AssistantSetting _setting(Map<String, Object?> state) =>
      assistantSettingOf(state['key']) ??
      (throw StateError('这个设置项已不在白名单：${state['key']}'));

  @override
  Future<void> apply(Map<String, Object?> state) =>
      notifier().transaction(() async {
        final n = notifier();
        final settings = await n.readStored();
        await _setting(state).writeState(n, state['value'], settings);
      });

  /// Checked and written under the settings write lock.
  @override
  Future<bool> applyIfCurrent(
    Map<String, Object?> expected,
    Map<String, Object?> state,
  ) => notifier().transaction(() => super.applyIfCurrent(expected, state));

  @override
  Future<bool> isCurrent(Map<String, Object?> state) async => _same(
    _setting(state).stateLike(await notifier().readStored(), state['value']),
    state['value'],
  );

  static bool _same(Object? a, Object? b) =>
      canonicalSettingJson(a) == canonicalSettingJson(b);
}

/// Writes the interface settings back for undo of a reset, only while none
/// of them has changed since.
class AssistantInterfaceResetApplier extends CheckedChangeApplier {
  AssistantInterfaceResetApplier({required this.notifier});

  final AppSettingsNotifier Function() notifier;

  @override
  Future<void> apply(Map<String, Object?> state) =>
      notifier().writeInterfaceSettings(state);

  @override
  Future<bool> applyIfCurrent(
    Map<String, Object?> expected,
    Map<String, Object?> state,
  ) => notifier().transaction(() => super.applyIfCurrent(expected, state));

  @override
  Future<bool> isCurrent(Map<String, Object?> state) async =>
      canonicalSettingJson(await notifier().readInterfaceSettings()) ==
      canonicalSettingJson(state);
}
