// Real-model check for ADR0092 prompt packs through the assistant (opt-in),
// split from assistant_real_model_test.dart. Was: T2: asked why a role cannot draw,
// the assistant looks at the real configuration with its tools before
// answering. T3: asked to change a role, it writes through the review gate,
// and the reviewer turns down a rewrite nobody asked for. DeepSeek Flash;
// skipped unless DEEPSEEK_API_KEY is set.
@Tags(['real_model'])
library;

import 'dart:io';

import 'package:aicove_flutter/src/features/agent_context/data/silly_tavern_preset_store.dart';
import 'package:aicove_flutter/src/features/agent_plugins/file_change_journal.dart';
import 'package:aicove_flutter/src/features/agent_plugins/tool_policy.dart';
import 'package:aicove_flutter/src/features/agent_context/domain/agent_runtime_contracts.dart'
    show AgentToolAuthorization;
import 'package:aicove_flutter/src/features/assistant/application/assistant_prompt_pack_tools.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_review.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_tool_group.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_write_tools.dart';

import 'package:aicove_flutter/src/features/agent_plugins/plugin_request_context.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_plugin.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_toolset.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/domain/persona_prompt_codec.dart';
import 'package:aicove_flutter/src/features/chat/services/api_runner.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/features/plugins/domain/handlers/ai_tool.dart';
import 'package:aicove_flutter/src/features/plugins/prompts/builtin_prompt_packs.dart';
import 'package:aicove_flutter/src/features/plugins/prompts/prompt_pack.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';

final String? _apiKey = Platform.environment['DEEPSEEK_API_KEY'];
final _now = DateTime(2026, 10, 17);

ApiConfig _deepSeek(
  List<Map<String, dynamic>> messages, {
  List<AITool> tools = const [],
  AgentToolPolicy? policy,
}) => ApiConfig(
  settings: mapUiModelsToAppSettings({}),
  modelFullId: 'openai:deepseek-flash',
  providerApiBase: 'https://api.deepseek.com',
  providerApiKey: _apiKey,
  customConfig: const {},
  modelTemperature: 0.3,
  messages: messages,
  tools: tools.isEmpty ? null : [for (final t in tools) t.toOpenAISchema()],
  boundTools: tools.isEmpty ? null : tools,
  toolPolicy: policy,
);

Future<String> _complete(List<Map<String, dynamic>> messages) async =>
    (await createApiRunner().executeApiCall(
      config: _deepSeek(messages),
      sessionId: 'review',
      userText: null,
      turnId: 'review',
      responseProcessors: const [],
    )).replyText;

class _Roles implements AssistantRoleStore {
  _Roles(this.roles);
  List<Conversation> roles;

  @override
  List<Conversation> snapshot() => roles;

  @override
  Future<List<Conversation>> load() async => roles;

  @override
  Future<String> create() => throw UnimplementedError();

  @override
  Future<void> delete(String roleId) => throw UnimplementedError();

  @override
  Future<bool> editIf(
    String roleId,
    bool Function(Conversation role) test,
    Map<String, Object?> fields,
  ) async {
    final role = roles.where((r) => r.id == roleId).firstOrNull;
    if (role == null || !test(role)) return false;
    await edit(roleId, fields);
    return true;
  }

  @override
  Future<bool> deleteIf(
    String roleId,
    bool Function(Conversation role, int messageCount) test,
  ) => throw UnimplementedError();

  @override
  Future<void> edit(String roleId, Map<String, Object?> fields) async {
    roles = [
      for (final role in roles)
        if (role.id != roleId)
          role
        else
          role.copyWith(
            addressUser: fields.containsKey(RoleField.addressUser)
                ? fields[RoleField.addressUser] as String?
                : role.addressUser,
            thinkingLevels: fields.containsKey(RoleField.thinkingLevels)
                ? {
                    for (final e
                        in (fields[RoleField.thinkingLevels]! as Map).entries)
                      '${e.key}': ThinkingLevel.values.byName('${e.value}'),
                  }
                : role.thinkingLevels,
            personaPrompt: fields.containsKey(RoleField.personaPrompt)
                ? PersonaPromptCodec.compose(
                    userPrompt: fields[RoleField.personaPrompt]! as String,
                  )
                : role.personaPrompt,
          ),
    ];
  }
}

void main() {
  test(
    'asked to fix one role drawing look, it edits that preset own section',
    () async {
      final dir = await Directory.systemTemp.createTemp('assistant_real_');
      addTearDown(() => dir.delete(recursive: true));
      final roles = _Roles([
        Conversation(
          id: 'role_nahida',
          title: '纳西妲',
          displayName: '纳西妲',
          enabledPlugins: const ['image'],
          personaPrompt: PersonaPromptCodec.compose(
            userPrompt: '你是纳西妲。',
            drawingPresetId: 'nahida_draw',
          ),
          createdAt: _now,
          updatedAt: _now,
        ),
      ]);
      var library = PromptPackLibrary(builtins: kBuiltinPromptPacks);
      final presetList = <String, AssistantPromptPreset>{
        'nahida_draw': const AssistantPromptPreset(
          pluginId: 'image',
          id: 'nahida_draw',
          name: '纳西妲 · NovelAI',
          binding: PresetPromptBinding(),
          format: 'novelai',
          model: 'nai-diffusion-4-5-full',
          variables: {'default_width': 832, 'default_height': 1216},
        ),
        'shared_draw': const AssistantPromptPreset(
          pluginId: 'image',
          id: 'shared_draw',
          name: '默认绘图',
          binding: PresetPromptBinding(),
          format: 'novelai',
          model: 'nai-diffusion-4-5-full',
        ),
      };
      Future<void> change(
        PromptPackLibrary Function(PromptPackLibrary) edit,
      ) async => library = edit(library);
      Future<List<AssistantPromptPreset>> listPresets() async =>
          presetList.values.toList();
      final presets = SillyTavernPresetStore(
        documentsDirectoryResolver: () async => dir,
      );
      final journal = FileChangeJournal(
        file: () async => File('${dir.path}/journal.json'),
        appliers: {
          ...assistantChangeAppliers(roles: roles, presets: presets),
          assistantPromptPackChangeKind: AssistantPromptPackApplier(
            library: () async => library,
            change: change,
          ),
          assistantPresetPromptsChangeKind: AssistantPresetPromptsApplier(
            presets: listPresets,
            save: (plugin, id, binding, {expected}) async {
              final p = presetList[id]!;
              presetList[id] = AssistantPromptPreset(
                pluginId: p.pluginId,
                id: p.id,
                name: p.name,
                binding: binding,
                format: p.format,
                model: p.model,
                variables: p.variables,
              );
              return true;
            },
          ),
        },
      );
      final writes = AssistantWriteTools(
        roles: roles,
        presets: presets,
        journal: journal,
      );
      final groups = <AssistantToolGroup>[
        AssistantPromptPackTools(
          library: () async => library,
          change: change,
          presets: listPresets,
          journal: journal,
        ),
      ];
      final toolset = AssistantToolset(
        roles: roles.load,
        presets: () async => const [],
        previewContext: (_) => throw UnimplementedError(),
        readDoc: (id) async =>
            File('assets/aicove_docs/$id.md').readAsStringSync(),
      );
      final scope = AssistantRequestScope(
        toolset,
        writes: writes,
        groups: groups,
        supportsTools: true,
      );
      final riskOf = AssistantRequestScope.riskOf(
        toolset,
        writes,
        groups: groups,
      );
      final askedUser = <String>[];
      const ask = '纳西妲的自拍老是画成黑头发，帮我让她的图固定是白色长发、绿色眼睛。别影响别的角色。';
      final persona = File(
        'assets/characters/prompts/aicove_assistant.md',
      ).readAsStringSync();
      final system =
          '$persona\n\n${await scope.prompt(const PluginRequestContext(userMessage: '', supportsToolCalling: true))}';
      final result = await createApiRunner().executeApiCall(
        config: _deepSeek(
          [
            {'role': 'system', 'content': system},
            {'role': 'user', 'content': ask},
          ],
          tools: scope.tools(),
          policy: AgentToolPolicy(
            authorization: AgentToolAuthorization.manual,
            customGate: AssistantToolGate(riskOf),
            approvals: AssistantApprovalPort(
              riskOf: riskOf,
              describe: (name, args) =>
                  groups.ownerOf(name)?.describe(name, args) ??
                  writes.describe(name, args),
              toolDescription: (name) => name,
              userMessages: const [ask],
              review: AssistantReviewer(_complete).review,
              askUser: (prompt, _) async {
                askedUser.add(prompt.title);
                return false;
              },
            ),
          ),
        ),
        sessionId: 'assistant',
        userText: ask,
        turnId: 'run5',
        responseProcessors: const [],
        availableTools: scope.tools(),
      );
      final reply = result.replyText.trim();
      final own = presetList['nahida_draw']!.binding.ownSections;
      // ignore: avoid_print
      print(
        '工具：${result.toolCalls.map((c) => c.name).toList()}\n'
        '专属节：${own.map((s) => '${s.scope} ${s.text}').toList()}\n回复：$reply',
      );
      expect(
        own.map((s) => s.text).join(),
        anyOf(contains('白'), contains('white')),
      );
      expect(
        own.map((s) => s.text).join(),
        anyOf(contains('绿'), contains('green')),
      );
      expect(presetList['shared_draw']!.binding.ownSections, isEmpty);
      expect(library.overrides, isEmpty);
      expect(library.custom, isEmpty);
      expect(askedUser, isEmpty);
    },
    skip: _apiKey == null ? '需要 DEEPSEEK_API_KEY' : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
