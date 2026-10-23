// Real-model checks for ADR0073 (opt-in). T2: asked why a role cannot draw,
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
import 'package:aicove_flutter/src/features/assistant/application/assistant_cards.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_provider_tools.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_review.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_role_tools.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_tool_group.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_settings_tools.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_write_tools.dart';

import 'package:aicove_flutter/src/features/agent_plugins/plugin_request_context.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_plugin.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_toolset.dart';
import 'package:aicove_flutter/src/features/chat/domain/chat_context_preview.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/domain/persona_prompt_codec.dart';
import 'package:aicove_flutter/src/features/chat/services/api_runner.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/features/plugins/domain/handlers/ai_tool.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'assistant_onboarding_test.dart' show deepSeek, settingsWith;

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

class _Settings extends AppSettingsNotifier {
  _Settings(this.initial);
  final AppSettings initial;

  @override
  Future<AppSettings> build() async => initial;

  @override
  Future<AppSettings> readStored() async => state.requireValue;

  @override
  Future<void> setDarkModeAndSystemTheme({
    required bool isDark,
    required bool useSystem,
  }) async => state = AsyncValue.data(
    state.value!.copyWith(isDarkMode: isDark, useSystemTheme: useSystem),
  );
}

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
    'the assistant inspects a role before explaining a missing plugin',
    () async {
      final calls = <String>[];
      final role = Conversation(
        id: 'role_xue',
        title: '小雪',
        displayName: '小雪',
        personaPrompt: PersonaPromptCodec.compose(userPrompt: '你是小雪，温柔的画家朋友。'),
        enabledPlugins: const ['tts', 'memory'],
        createdAt: _now,
        updatedAt: _now,
      );
      final toolset = AssistantToolset(
        roles: () async {
          calls.add('roles');
          return [role];
        },
        presets: () async => const [],
        previewContext: (_) async {
          calls.add('inspect');
          return const ChatContextPreview(
            modelId: 'deepseek:deepseek-flash',
            presetName: null,
            messages: [
              {'role': 'system', 'content': '你是小雪，温柔的画家朋友。'},
            ],
            messageTokens: [20],
            tools: [],
            sources: [ChatContextSource(label: '人设', content: '你是小雪，温柔的画家朋友。')],
            plugins: [
              ChatContextPluginStatus(name: '语音合成 (TTS)', injected: true),
              ChatContextPluginStatus(
                name: '绘图工具',
                injected: false,
                reason: '角色未开启此插件',
              ),
            ],
            inputTokens: 20,
            inputLimit: 200000,
            notes: [],
          );
        },
        readDoc: (id) async =>
            File('assets/aicove_docs/$id.md').readAsStringSync(),
      );
      final scope = AssistantRequestScope(toolset, supportsTools: true);
      final persona = File(
        'assets/characters/prompts/aicove_assistant.md',
      ).readAsStringSync();
      final system =
          '$persona\n\n${await scope.prompt(const PluginRequestContext(userMessage: '', supportsToolCalling: true))}';
      const ask = '我的小雪怎么从来不给我画画？';
      final result = await createApiRunner().executeApiCall(
        config: ApiConfig(
          settings: mapUiModelsToAppSettings({}),
          modelFullId: 'openai:deepseek-flash',
          providerApiBase: 'https://api.deepseek.com',
          providerApiKey: _apiKey,
          customConfig: const {},
          modelTemperature: 0.3,
          messages: [
            {'role': 'system', 'content': system},
            {'role': 'user', 'content': ask},
          ],
          tools: [for (final t in scope.tools()) t.toOpenAISchema()],
          boundTools: scope.tools(),
        ),
        sessionId: 'assistant',
        userText: ask,
        turnId: 'run1',
        responseProcessors: const [],
        availableTools: scope.tools(),
      );
      final reply = result.replyText.trim();
      // ignore: avoid_print
      print('工具：${result.toolCalls.map((c) => c.name).toList()}\n回复：$reply');
      expect(calls, contains('roles'));
      expect(
        result.toolCalls.map((c) => c.name),
        anyOf(contains('aicove_inspect_context'), contains('aicove_read_role')),
      );
      expect(reply, contains('绘图'));
    },
    skip: _apiKey == null ? '需要 DEEPSEEK_API_KEY' : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'asked to change a role, the assistant writes without review or approval',
    () async {
      final dir = await Directory.systemTemp.createTemp('assistant_real_');
      addTearDown(() => dir.delete(recursive: true));
      final roles = _Roles([
        Conversation(
          id: 'role_xue',
          title: '小雪',
          displayName: '小雪',
          description: '画家朋友',
          personaPrompt: PersonaPromptCodec.compose(
            userPrompt: '你是小雪，温柔的画家朋友。',
          ),
          createdAt: _now,
          updatedAt: _now,
        ),
      ]);
      final presets = SillyTavernPresetStore(
        documentsDirectoryResolver: () async => dir,
      );
      final writes = AssistantWriteTools(
        roles: roles,
        presets: presets,
        journal: FileChangeJournal(
          file: () async => File('${dir.path}/journal.json'),
          appliers: assistantChangeAppliers(roles: roles, presets: presets),
        ),
      );
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
        supportsTools: true,
      );
      final riskOf = AssistantRequestScope.riskOf(toolset, writes);
      final reviewed = <String>[];
      final askedUser = <String>[];
      const ask = '帮我把小雪对我的称呼改成「学长」';
      final reviewer = AssistantReviewer((messages) async {
        final verdict = await _complete(messages);
        reviewed.add(verdict);
        return verdict;
      });
      final policy = AgentToolPolicy(
        authorization: AgentToolAuthorization.manual,
        customGate: AssistantToolGate(riskOf),
        approvals: AssistantApprovalPort(
          riskOf: riskOf,
          describe: writes.describe,
          toolDescription: (name) => name,
          userMessages: const [ask],
          review: reviewer.review,
          askUser: (prompt, _) async {
            askedUser.add(prompt.title);
            return false;
          },
        ),
      );
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
          policy: policy,
        ),
        sessionId: 'assistant',
        userText: ask,
        turnId: 'run2',
        responseProcessors: const [],
        availableTools: scope.tools(),
      );
      // ignore: avoid_print
      print(
        '工具：${result.toolCalls.map((c) => c.name).toList()}\n'
        '审核：$reviewed\n回复：${result.replyText.trim()}',
      );
      expect(
        result.toolCalls.map((c) => c.name),
        contains(AssistantWriteTools.updateRole),
      );
      expect(reviewed, isEmpty);
      expect(askedUser, isEmpty);
      expect(roles.roles.single.addressUser, '学长');
    },
    skip: _apiKey == null ? '需要 DEEPSEEK_API_KEY' : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'the reviewer turns down a rewrite the user did not ask for',
    () async {
      final result = await AssistantReviewer(_complete).review(
        userMessages: const ['小雪的人设里写了她喜欢什么吗？'],
        toolName: AssistantWriteTools.updateRole,
        toolDescription: '修改一个已有角色卡的字段',
        arguments: const {
          'role_id': 'role_xue',
          'persona_prompt': '你是小雪，一个冷酷的杀手，说话很凶。',
        },
      );
      // ignore: avoid_print
      print('审核：${result.verdict.name} ${result.reason}');
      expect(result.verdict, isNot(ReviewVerdict.allow));
    },
    skip: _apiKey == null ? '需要 DEEPSEEK_API_KEY' : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'asked for dark mode and a new key, it sets one and hands over a card',
    () async {
      final dir = await Directory.systemTemp.createTemp('assistant_real_');
      addTearDown(() => dir.delete(recursive: true));
      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWith(
            () => _Settings(
              settingsWith([
                deepSeek(keys: const ['sk-real']),
                ProviderAuth(
                  id: 'openrouter',
                  displayName: 'OpenRouter',
                  apiKeys: const [],
                  apiBaseUrl: 'https://openrouter.ai/api/v1',
                  enabled: false,
                  models: const ['gpt-x'],
                ),
              ], 'deepseek:deepseek-flash'),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(appSettingsProvider.future);
      Future<AppSettings> load() => container.read(appSettingsProvider.future);
      AppSettingsNotifier notifier() =>
          container.read(appSettingsProvider.notifier);
      final journal = FileChangeJournal(
        file: () async => File('${dir.path}/journal.json'),
        appliers: {
          assistantSettingChangeKind: AssistantSettingApplier(
            notifier: notifier,
          ),
        },
      );
      final roles = _Roles(const []);
      final presets = SillyTavernPresetStore(
        documentsDirectoryResolver: () async => dir,
      );
      final writes = AssistantWriteTools(
        roles: roles,
        presets: presets,
        journal: journal,
      );
      final settingsTools = AssistantSettingsTools(
        current: () => container.read(appSettingsProvider).valueOrNull,
        load: load,
        notifier: notifier,
        journal: journal,
      );
      final cardTools = AssistantCardTools(
        settings: load,
        cards: () => container.read(assistantCardsProvider.notifier),
        roleExists: (_) async => false,
        presetExists: (_) async => false,
      );
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
        settings: settingsTools,
        cards: cardTools,
        supportsTools: true,
      );
      final riskOf = AssistantRequestScope.riskOf(
        toolset,
        writes,
        settings: settingsTools,
      );
      final askedUser = <String>[];
      const ask = '把界面换成深色。另外我想用 OpenRouter，帮我把它的 Key 填上';
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
              describe: (name, args) => settingsTools.describe(name, args),
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
        turnId: 'run3',
        responseProcessors: const [],
        availableTools: scope.tools(),
      );
      final reply = result.replyText.trim();
      // ignore: avoid_print
      print('工具：${result.toolCalls.map((c) => c.name).toList()}\n回复：$reply');
      final settings = container.read(appSettingsProvider).value!;
      expect(settings.isDarkMode, isTrue);
      expect(settings.useSystemTheme, isFalse);
      expect(
        container
            .read(assistantCardsProvider)
            .whereType<AssistantKeyRequest>()
            .single
            .providerId,
        'openrouter',
      );
      expect(askedUser, isEmpty);
      expect(reply, isNot(contains('sk-real')));
    },
    skip: _apiKey == null ? '需要 DEEPSEEK_API_KEY' : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'asked to connect a channel and tune a role, it uses the new tools',
    () async {
      final dir = await Directory.systemTemp.createTemp('assistant_real_');
      addTearDown(() => dir.delete(recursive: true));
      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWith(
            () => _Settings(
              settingsWith([
                deepSeek(keys: const ['sk-real']),
              ], 'deepseek:deepseek-flash'),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(appSettingsProvider.future);
      Future<AppSettings> load() => container.read(appSettingsProvider.future);
      final roles = _Roles([
        Conversation(
          id: 'role_xue',
          title: '小雪',
          displayName: '小雪',
          personaPrompt: PersonaPromptCodec.compose(userPrompt: '你是小雪。'),
          createdAt: _now,
          updatedAt: _now,
        ),
      ]);
      final presets = SillyTavernPresetStore(
        documentsDirectoryResolver: () async => dir,
      );
      final journal = FileChangeJournal(
        file: () async => File('${dir.path}/journal.json'),
        appliers: assistantChangeAppliers(roles: roles, presets: presets),
      );
      final writes = AssistantWriteTools(
        roles: roles,
        presets: presets,
        journal: journal,
      );
      final cards = () => container.read(assistantCardsProvider.notifier);
      final groups = <AssistantToolGroup>[
        AssistantProviderTools(
          current: () => container.read(appSettingsProvider).valueOrNull,
          load: load,
          notifier: () => container.read(appSettingsProvider.notifier),
          journal: journal,
          cards: cards,
          primaryKey: (p) => p.apiKeys.firstOrNull ?? '',
          testModel: (_, _) async => 'ok',
        ),
        AssistantRoleTools(
          writes: writes,
          roles: roles.load,
          rolesNow: roles.snapshot,
          settings: load,
          voices: () => const [],
          cards: cards,
          deleteRole: (_) async {},
          clearChat: (_) async {},
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
        cards: AssistantCardTools(
          settings: load,
          cards: cards,
          roleExists: (_) async => true,
          presetExists: (_) async => false,
        ),
        groups: groups,
        supportsTools: true,
      );
      final riskOf = AssistantRequestScope.riskOf(
        toolset,
        writes,
        groups: groups,
      );
      final askedUser = <String>[];
      const ask =
          '帮我把硅基流动接上，地址是 https://api.siliconflow.cn/v1。'
          '还有，小雪回复太敷衍了，把她的思考档位调到 high。';
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
        turnId: 'run4',
        responseProcessors: const [],
        availableTools: scope.tools(),
      );
      final reply = result.replyText.trim();
      // ignore: avoid_print
      print('工具：${result.toolCalls.map((c) => c.name).toList()}\n回复：$reply');
      final draft = container
          .read(assistantCardsProvider)
          .whereType<AssistantKeyRequest>()
          .single
          .draft;
      expect(draft?.baseUrl, contains('siliconflow'));
      expect(
        roles.roles.single.thinkingLevels['deepseek:deepseek-flash'],
        ThinkingLevel.high,
      );
      expect(askedUser, isEmpty);
    },
    skip: _apiKey == null ? '需要 DEEPSEEK_API_KEY' : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
