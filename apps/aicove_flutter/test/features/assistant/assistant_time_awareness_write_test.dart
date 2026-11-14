import 'dart:convert';
import 'dart:io';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart';
import 'package:aicove_flutter/src/features/agent_context/data/silly_tavern_preset_store.dart';
import 'package:aicove_flutter/src/features/agent_plugins/file_change_journal.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_review.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_write_tools.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/domain/role_agent_mode.dart';
import 'package:aicove_flutter/src/features/plugins/time_awareness/time_awareness_role_options.dart';
import 'package:flutter_test/flutter_test.dart';

/// Focus on the write contract; the production role store is covered by
/// assistant_request_test and assistant_role_tools_test.
class _Roles implements AssistantRoleStore {
  _Roles(this.role);
  Conversation role;
  void Function()? beforeEdit;

  @override
  List<Conversation> snapshot() => [role];
  @override
  Future<List<Conversation>> load() async => [role];
  @override
  Future<void> edit(String roleId, Map<String, Object?> fields) async {
    final plugins = fields[RoleField.enabledPlugins] as List?;
    role = role.copyWith(
      enabledPlugins: plugins?.cast<String>(),
      agentMode: fields.containsKey(RoleField.agentMode)
          ? RoleAgentMode.fromValue(fields[RoleField.agentMode] as String?)
          : role.agentMode,
    );
  }

  @override
  Future<bool> editIf(
    String roleId,
    bool Function(Conversation) test,
    Map<String, Object?> fields,
  ) async {
    beforeEdit?.call();
    if (!test(role)) return false;
    await edit(roleId, fields);
    return true;
  }

  @override
  Future<String> create({RoleAgentMode mode = RoleAgentMode.chat}) =>
      throw UnimplementedError();
  @override
  Future<void> delete(String roleId) => throw UnimplementedError();
  @override
  Future<bool> deleteIf(String roleId, bool Function(Conversation, int) test) =>
      throw UnimplementedError();
}

void main() {
  late Directory dir;
  late _Roles store;
  late SillyTavernPresetStore presets;
  late FileChangeJournal journal;
  late AssistantWriteTools writes;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('assistant_time_options_');
    store = _Roles(
      Conversation(
        id: 'preset_nahida',
        title: '纳西妲',
        displayName: '纳西妲',
        createdAt: DateTime(2026, 10, 30),
        updatedAt: DateTime(2026, 10, 30),
        messages: const [],
      ),
    );
    presets = SillyTavernPresetStore(
      documentsDirectoryResolver: () async => dir,
    );
    journal = FileChangeJournal(
      file: () async => File('${dir.path}/journal.json'),
      appliers: assistantChangeAppliers(roles: store, presets: presets),
    );
    writes = AssistantWriteTools(
      roles: store,
      presets: presets,
      journal: journal,
    );
  });
  tearDown(() => dir.delete(recursive: true));

  Future<Conversation> nahida() async => store.role;

  Future<Map<String, dynamic>> setPlugins(
    Map<String, dynamic> args, {
    AssistantWriteTools? using,
  }) async =>
      jsonDecode(
            (await (using ?? writes)
                .tools()
                .singleWhere(
                  (t) => t.name == AssistantWriteTools.setRolePlugins,
                )
                .handler({'role_id': 'preset_nahida', ...args}))!,
          )
          as Map<String, dynamic>;

  test(
    'current_time alone preserves plugins and grants and can undo',
    () async {
      const before = [
        'memory',
        'time_awareness',
        'pkg:existing',
        'mcp:existing',
        'workspace:example',
      ];
      await store.edit('preset_nahida', {RoleField.enabledPlugins: before});
      final args = {'role_id': 'preset_nahida', 'current_time': false};
      expect(
        writes.riskOf(AssistantWriteTools.setRolePlugins, args),
        AssistantRisk.reversible,
      );
      final result = await setPlugins({'current_time': false});
      expect(result['ok'], isTrue, reason: '$result');
      expect(result['change'], contains('现在几点：不告诉'));
      expect(
        result['change'],
        isNot(contains(TimeAwarenessRoleOptions.noCurrentTimeId)),
      );
      expect(
        (await journal.recent()).single.change.description,
        contains('现在几点：不告诉'),
      );
      expect((await nahida()).enabledPlugins, [
        ...before,
        TimeAwarenessRoleOptions.noCurrentTimeId,
      ]);
      final description = writes
          .describe(AssistantWriteTools.setRolePlugins, args)
          .detail;
      expect(description, contains('现在几点：不告诉'));
      expect(
        description,
        isNot(contains(TimeAwarenessRoleOptions.noCurrentTimeId)),
      );
      await journal.undo((await journal.recent()).single.id);
      expect((await nahida()).enabledPlugins, before);
      await setPlugins({'current_time': false});
      final restored = await setPlugins({'current_time': true});
      expect(restored['ok'], isTrue);
      expect((await nahida()).enabledPlugins, before);
      expect(
        writes.describe(AssistantWriteTools.setRolePlugins, {
          'role_id': 'preset_nahida',
          'current_time': true,
        }).detail,
        contains('现在几点：告诉'),
      );
    },
  );

  test(
    'null roles become all builtins plus time option without extensions',
    () async {
      await store.edit('preset_nahida', {RoleField.enabledPlugins: null});
      final result = await setPlugins({'current_time': false});
      expect(result['ok'], isTrue, reason: '$result');
      expect(
        (await nahida()).enabledPlugins,
        unorderedEquals([
          ...kAssistantRolePlugins.keys.where((id) => id != 'aicove_assistant'),
          TimeAwarenessRoleOptions.noCurrentTimeId,
        ]),
      );
      await journal.undo((await journal.recent()).single.id);
      expect((await nahida()).enabledPlugins, isNull);
    },
  );

  test(
    'legacy tool capability can be disabled and undo restores null defaults',
    () async {
      store.role = store.role.copyWith(agentMode: RoleAgentMode.tool);
      expect(store.role.hasAssistantCapability, isTrue);
      final result = await setPlugins({'plugins': <String>[]});
      expect(result['ok'], isTrue);
      expect(store.role.agentMode, isNull);
      expect(store.role.enabledPlugins, isEmpty);
      expect(store.role.hasAssistantCapability, isFalse);
      await journal.undo((await journal.recent()).single.id);
      expect(store.role.agentMode, RoleAgentMode.tool);
      expect(store.role.enabledPlugins, isNull);
      expect(store.role.isPluginEnabled('image'), isTrue);
      expect(store.role.hasAssistantCapability, isTrue);
    },
  );

  test(
    'time-only edit preserves legacy capability explicitly and clears legacy mode',
    () async {
      store.role = store.role.copyWith(agentMode: RoleAgentMode.tool);
      final result = await setPlugins({'current_time': false});
      expect(result['ok'], isTrue);
      expect(store.role.agentMode, isNull);
      expect(store.role.enabledPlugins, contains('aicove_assistant'));
      expect(store.role.hasAssistantCapability, isTrue);
    },
  );

  test('all=true preserves time option and unmanaged plugins', () async {
    await store.edit('preset_nahida', {
      RoleField.enabledPlugins: [
        'memory',
        'web_search',
        'workspace:example',
        TimeAwarenessRoleOptions.noCurrentTimeId,
      ],
    });
    final result = await setPlugins({'all': true});
    expect(result['ok'], isTrue, reason: '$result');
    expect(
      (await nahida()).enabledPlugins,
      unorderedEquals([
        ...kAssistantRolePlugins.keys.where((id) => id != 'aicove_assistant'),
        'workspace:example',
        TimeAwarenessRoleOptions.noCurrentTimeId,
      ]),
    );
    expect(
      writes.describe(AssistantWriteTools.setRolePlugins, {
        'role_id': 'preset_nahida',
        'all': true,
      }).detail,
      isNot(contains(TimeAwarenessRoleOptions.noCurrentTimeId)),
    );
    expect(
      (await setPlugins({'all': true, 'current_time': true}))['ok'],
      isTrue,
    );
    expect(
      (await nahida()).enabledPlugins,
      isNot(contains(TimeAwarenessRoleOptions.noCurrentTimeId)),
    );
  });

  test(
    'current_time rejects non-booleans without changing or journaling',
    () async {
      final before = (await nahida()).enabledPlugins;
      for (final value in <Object?>['false', 0, null, [], {}]) {
        final result = await setPlugins({'current_time': value});
        expect(result['error'], 'invalid');
        expect(result['message'], contains('current_time 应为 true 或 false'));
        expect((await nahida()).enabledPlugins, before);
      }
      expect(await journal.recent(), isEmpty);
    },
  );

  test(
    'current_time still uses guarded writes and external-plugin risk',
    () async {
      await store.edit('preset_nahida', {
        RoleField.enabledPlugins: ['memory'],
      });
      final interleaved = AssistantWriteTools(
        roles: store,
        presets: presets,
        journal: journal,
      );
      expect(
        writes.riskOf(AssistantWriteTools.setRolePlugins, {
          'role_id': 'preset_nahida',
          'current_time': false,
          'plugins': ['web_search'],
        }),
        AssistantRisk.major,
      );
      store.beforeEdit = () =>
          store.role = store.role.copyWith(enabledPlugins: ['memory', 'tts']);
      final result = await setPlugins({
        'current_time': false,
      }, using: interleaved);
      expect(result['error'], 'invalid');
      expect((await nahida()).enabledPlugins, ['memory', 'tts']);
      expect(await journal.recent(), isEmpty);
    },
  );

  test(
    'rating detects a time-option change between approval and writing',
    () async {
      await store.edit('preset_nahida', {
        RoleField.enabledPlugins: ['memory'],
      });
      final args = {'role_id': 'preset_nahida', 'current_time': false};
      final scope = ToolCallScope();
      scope.run(() => writes.riskOf(AssistantWriteTools.setRolePlugins, args));
      scope.outcome = GateOutcome.allowed;
      await store.edit('preset_nahida', {
        RoleField.enabledPlugins: [
          'memory',
          TimeAwarenessRoleOptions.noCurrentTimeId,
        ],
      });
      final result = await scope.run(() => setPlugins({'current_time': false}));
      expect(result['error'], 'invalid');
      expect(result['message'], contains('角色的插件刚刚有变化'));
      expect(await journal.recent(), isEmpty);
    },
  );

  test(
    'role schemas replace retired modes with software-management plugins',
    () {
      for (final name in [
        AssistantWriteTools.createRole,
        AssistantWriteTools.updateRole,
      ]) {
        final tool = writes.tools().singleWhere((tool) => tool.name == name);
        final properties = tool.parameterSchema['properties'] as Map;
        expect(
          writes.riskOf(name, {
            'enabled_plugins': [' web_search '],
          }),
          AssistantRisk.major,
        );
        expect(properties, isNot(contains('agent_mode')));
        expect(properties['enabled_plugins']['type'], 'array');
        expect(
          properties['enabled_plugins']['description'],
          contains('aicove_assistant=软件管理'),
        );
      }
      expect(kAssistantRolePlugins['aicove_assistant'], '软件管理');
    },
  );

  test('tool schema exposes a role-scoped optional boolean', () {
    final tool = writes.tools().singleWhere(
      (t) => t.name == AssistantWriteTools.setRolePlugins,
    );
    final schema = tool.inputSchema!;
    expect(schema['required'], ['role_id']);
    expect((schema['properties'] as Map)['current_time'], {
      'type': 'boolean',
      'description': '是否让模型知道现在几点，只影响这个角色',
    });
    expect(tool.description, endsWith('其他不可管理插件始终保留。'));
  });
}
