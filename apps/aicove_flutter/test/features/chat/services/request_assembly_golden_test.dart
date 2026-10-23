// Golden request copies for ChatSendBackendService.prepareApiConfig.
//
// ADR0064 batch 2b moves plugin assembly out of the core; these goldens pin
// the exact request (messages, tools, tool choice) before and after, so the
// refactor must keep them byte-identical. Regenerate only for an intended
// behaviour change: AICOVE_UPDATE_GOLDENS=1 tool/flutterw test <this file>.
import 'dart:convert';
import 'dart:io';

import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/agent_context/data/silly_tavern_preset_store.dart';
import 'package:aicove_flutter/src/features/agent_context/providers/preset_recipe_provider.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/domain/role_agent_mode.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/domain/persona_prompt_codec.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_request_message_builder.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_backend_service.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_service.dart';
import 'package:aicove_flutter/src/features/memory/application/memory_keeper_service.dart';
import 'package:aicove_flutter/src/features/memory/providers/memory_providers.dart';
import 'package:aicove_flutter/src/features/observability/trace_store.dart';
import 'package:aicove_flutter/src/features/plugins/mcp/mcp_connector.dart';
import 'package:aicove_flutter/src/features/plugins/mcp/mcp_connector_providers.dart';
import 'package:aicove_flutter/src/features/plugins/plugin_providers.dart';
import 'package:aicove_flutter/src/features/plugins/tts/tts_config.dart';
import 'package:aicove_flutter/src/features/plugins/tts/tts_service.dart';
import 'package:aicove_flutter/src/features/plugins/tts/voice_preset_application.dart';
import 'package:aicove_flutter/src/features/plugins/tts/voice_request.dart';
import 'package:aicove_flutter/src/features/plugins/web_search/web_search_config.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
  @override
  Future<String?> getTemporaryPath() async => path;
}

class _Settings extends AppSettingsNotifier {
  _Settings(this._settings);
  final AppSettings _settings;
  @override
  Future<AppSettings> build() async => _settings;
}

// UTC keeps the rendered offset independent of the machine's time zone.
final _now = DateTime.utc(2026, 10, 12, 10, 5, 30);
const _model = 'openai:gpt-4o';

AppSettings _settings({required CallFlowMode mode, required bool tools}) =>
    mapUiModelsToAppSettings({'context_window_tokens': 272000}).copyWith(
      defaultModelName: _model,
      defaultChatModels: const [_model],
      imageGenerationEnabled: true,
      callFlowSettings: CallFlowSettings(mode: mode),
      modelConfigs: {
        _model: ModelConfig(
          chatCapabilities: tools ? const ['tools', 'vision'] : const [],
        ),
      },
      // An image channel, so the image plugin is usable (it stays silent
      // without one); its generic model keeps the default prompt pack.
      modelTypes: const {_model: 'chat', 'image-model': 'image'},
      providers: const [
        ProviderAuth(
          id: 'openai',
          apiKeys: ['test-key'],
          apiBaseUrl: 'https://api.openai.com/v1',
          models: ['image-model'],
          visibleModels: ['image-model'],
        ),
      ],
      modelProviderMap: const {_model: 'openai', 'gpt-4o': 'openai'},
    );

class _Voice implements VoicePresetApplicationPort {
  @override
  Future<VoiceRequest> forRole(Conversation owner) async => VoiceRequest(
        ownerId: owner.id,
        service: TtsService(
          config: TtsConfig(enabled: true),
          requestUrl: 'https://tts.invalid',
        ),
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Scenario {
  const _Scenario(
    this.name, {
    this.plugins,
    this.mode = CallFlowMode.call,
    this.tools = true,
    this.preset = false,
    this.mcpConfigured = false,
    this.imageFailure = false,
    this.tts = false,
    this.webSearch = false,
    this.agentMode,
  });

  final String name;

  /// Role plugin selection; null means "all plugins".
  final List<String>? plugins;
  final CallFlowMode mode;
  final bool tools;
  final bool preset;
  final bool mcpConfigured;
  final bool imageFailure;
  final bool tts;
  final bool webSearch;

  /// Null means chat mode (ADR0097).
  final RoleAgentMode? agentMode;
}

const _scenarios = [
  _Scenario('all_plugins_stable'),
  _Scenario('all_plugins_fast', mode: CallFlowMode.fast),
  _Scenario('all_plugins_no_tool_model', tools: false),
  _Scenario('no_plugins', plugins: []),
  _Scenario('image_only', plugins: ['image']),
  _Scenario('image_failure_reminder', plugins: ['image'], imageFailure: true),
  _Scenario('bound_preset', plugins: ['image', 'tts', 'time_awareness'],
      preset: true),
  _Scenario('mcp_enabled', plugins: ['mcp:notes', 'time_awareness'],
      mcpConfigured: true),
  _Scenario('mcp_not_enabled', plugins: ['time_awareness'],
      mcpConfigured: true),
  _Scenario('tts_enabled', plugins: ['tts', 'time_awareness'], tts: true),
  _Scenario('web_search_takeover', plugins: ['web_search'], webSearch: true),
  _Scenario('tool_mode_web_search', plugins: ['web_search'], webSearch: true,
      agentMode: RoleAgentMode.tool),
];

List<Message> _history(_Scenario s) => [
      Message(
        id: 'u1',
        role: 'user',
        content: '早上好',
        createdAt: _now.subtract(const Duration(hours: 3)),
      ),
      Message(
        id: 'a1',
        role: 'assistant',
        content: '早呀<image>a cat on a sofa</image>今天想做什么？'
            '<tts voice="v">早上好</tts>',
        createdAt: _now.subtract(const Duration(hours: 3, minutes: -1)),
      ),
      if (s.imageFailure)
        Message.fromBlocks(
          id: 'a_fail',
          role: 'assistant',
          blocks: [
            TextBlock(messageId: 'a_fail', content: '刚才试着给你画图。'),
            ToolBlock(
              messageId: 'a_fail',
              toolName: ChatRequestMessageBuilder.internalImageContextToolName,
              result: ChatRequestMessageBuilder.buildImageContextPayload(
                role: 'assistant',
                status: 'failed',
                rawPrompt: '1girl',
                prompt: 'style, 1girl',
                reason: 'timeout',
                imagePresent: false,
              ),
            ),
          ],
          createdAt: _now.subtract(const Duration(minutes: 30)),
        ),
      if (s.mcpConfigured)
        Message.fromBlocks(
          id: 'a_mcp',
          role: 'assistant',
          blocks: [
            ToolBlock(
              messageId: 'a_mcp',
              toolName: 'mcp__notes__search',
              arguments: const {'q': 'plan'},
              result: const {'hits': 1},
            ),
            TextBlock(messageId: 'a_mcp', content: '找到一条笔记。'),
          ],
          createdAt: _now.subtract(const Duration(minutes: 20)),
        ),
      Message(id: 'u2', role: 'user', content: '帮我画一只猫', createdAt: _now),
    ];

Map<String, Object?> _snapshot(dynamic config) => {
      'messages': config.messages,
      'tools': config.tools,
      'toolChoice': config.providerRequestOptions?.toolChoice,
      'disableBuiltinWebSearch':
          config.providerRequestOptions?.disableBuiltinWebSearch,
      'boundTools': [for (final t in config.boundTools ?? []) t.name],
      'enabledPluginIds': (config.enabledPluginIds?.toList()?..sort()),
      'presetStreamResponse': config.presetStreamResponse,
      'hasPresetScript': config.presetScript != null,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final update = Platform.environment['AICOVE_UPDATE_GOLDENS'] == '1';
  final goldenDir = Directory(
    'test/features/chat/services/goldens/request_assembly',
  );

  for (final s in _scenarios) {
    test('request copy is unchanged: ${s.name}', () async {
      SharedPreferences.setMockInitialValues({
        if (s.tts)
          'aicove.plugins.tts.config': jsonEncode(TtsConfig(enabled: true).toJson()),
        if (s.webSearch)
          'aicove.plugins.web_search.config': jsonEncode(const WebSearchConfig(
            providers: [
              WebSearchProviderEntry(
                id: 'ws',
                type: WebSearchProviderType.exa,
                apiKey: 'test-key',
              ),
            ],
            replaceModelBuiltinSearch: true,
          ).toJson()),
        if (s.mcpConfigured)
          McpConnectorsConfigNotifier.storageKey: jsonEncode(
            const McpConnectorsConfig(connectors: [
              McpConnector(
                id: 'notes',
                name: 'Notes',
                url: 'https://mcp.invalid',
                tools: [
                  McpToolInfo(
                    name: 'search',
                    description: 'Search notes',
                    inputSchema: {
                      'type': 'object',
                      'properties': {
                        'q': {'type': 'string'},
                      },
                    },
                  ),
                ],
              ),
            ]).toJson(),
          ),
      });
      final root = await Directory.systemTemp.createTemp('request_golden_');
      final oldPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _Paths(root.path);
      TraceStore.instance.debugResetForTest();
      final database = db.AppDatabase.forTesting(
        NativeDatabase(File('${root.path}/test.sqlite')),
      );
      final container = ProviderContainer(overrides: [
        databaseProvider.overrideWithValue(database),
        appSettingsProvider.overrideWith(
          () => _Settings(_settings(mode: s.mode, tools: s.tools)),
        ),
        requestClockProvider.overrideWithValue(() => _now),
        if (s.tts) voicePresetApplicationProvider.overrideWithValue(_Voice()),
        memoryKeeperProvider.overrideWith(
          (ref) => MemoryKeeperService(
            store: ref.read(memoryStoreProvider),
            loadMessages: (_) async => const [],
            compactedBoundaries: (_) async => const {},
            agentFactory: () => throw StateError('memory agent disabled'),
            allowed: (_) async => false,
          ),
        ),
        sillyTavernPresetStoreProvider.overrideWithValue(
          SillyTavernPresetStore(documentsDirectoryResolver: () async => root),
        ),
      ]);
      addTearDown(() async {
        container.dispose();
        await database.close();
        PathProviderPlatform.instance = oldPaths;
        await root.delete(recursive: true);
      });
      await container.read(appSettingsProvider.future);
      await container.read(mcpConnectorsConfigProvider.notifier).ready;
      await container.read(ttsPluginConfigProvider.notifier).ready;
      await container.read(webSearchPluginConfigProvider.notifier).ready;

      String? recipeId;
      if (s.preset) {
        final preset = await container
            .read(sillyTavernPresetStoreProvider)
            .importSource(
              jsonEncode({
                'name': '黄金预设',
                'prompts': [
                  {'identifier': 'main', 'role': 'system', 'content': '主提示。'},
                  {'identifier': 'chatHistory', 'marker': true},
                ],
                'prompt_order': [
                  {
                    'order': [
                      {'identifier': 'main', 'enabled': true},
                      {'identifier': 'chatHistory', 'enabled': true},
                    ],
                  },
                ],
              }),
              sourceFileName: 'golden.json',
            );
        recipeId = preset.id;
      }

      final conv = Conversation(
        id: 'golden_${s.name}',
        title: '理',
        displayName: '理',
        personaPrompt: PersonaPromptCodec.compose(userPrompt: '你是测试角色。'),
        enabledPlugins: s.plugins,
        recipeId: recipeId,
        agentMode: s.agentMode,
        createdAt: _now,
        updatedAt: _now,
        messages: const [],
      );
      final config = await container.read(chatSendServiceProvider)
          .prepareApiConfig(
            conv: conv,
            history: _history(s),
            userText: '帮我画一只猫',
          );

      final actual =
          const JsonEncoder.withIndent('  ').convert(_snapshot(config));
      final file = File('${goldenDir.path}/${s.name}.json');
      if (update) {
        await file.create(recursive: true);
        await file.writeAsString('$actual\n');
      }
      expect(actual, (await file.readAsString()).trimRight());
    });
  }
}
