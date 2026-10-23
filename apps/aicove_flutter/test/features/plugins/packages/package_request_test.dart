// E group (batch 2 plan §5): an installed declarative package reaches the
// request through the normal plugin path only when the role enables it.
import 'dart:convert';
import 'dart:io';
import 'extension_test_support.dart';
import 'package:aicove_flutter/src/features/chat/domain/role_agent_mode.dart';

import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/features/agent_context/data/silly_tavern_preset_store.dart';
import 'package:aicove_flutter/src/features/agent_context/providers/preset_recipe_provider.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/domain/persona_prompt_codec.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_backend_service.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_service.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/features/memory/application/memory_keeper_service.dart';
import 'package:aicove_flutter/src/features/memory/providers/memory_providers.dart';
import 'package:aicove_flutter/src/features/observability/trace_store.dart';
import 'package:aicove_flutter/src/features/plugins/packages/aicove_package.dart';
import 'package:aicove_flutter/src/features/plugins/packages/package_providers.dart';
import 'package:aicove_flutter/src/features/plugins/packages/package_store.dart';
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

final _now = DateTime.utc(2026, 10, 12, 10, 5, 30);
const _model = 'openai:gpt-4o';

AppSettings _settings() =>
    mapUiModelsToAppSettings({'context_window_tokens': 272000}).copyWith(
      defaultModelName: _model,
      defaultChatModels: const [_model],
      modelConfigs: {
        _model: ModelConfig(chatCapabilities: const ['tools']),
      },
      modelTypes: const {_model: 'chat'},
      providers: const [
        ProviderAuth(
          id: 'openai',
          apiKeys: ['test-key'],
          apiBaseUrl: 'https://api.openai.com/v1',
        ),
      ],
      modelProviderMap: const {_model: 'openai', 'gpt-4o': 'openai'},
    );

const _prompt = '说话时带一点诗意。';
const _tool = 'read_skill_demo';

Map<String, List<int>> _packageFiles() => {
  AicovePackage.manifestName: utf8.encode(
    jsonEncode({
      'schema': 1,
      'id': 'demo',
      'name': '示例包',
      'version': '1.0.0',
      'contents': [
        {'type': 'prompt', 'text': _prompt},
        {
          'type': 'tags',
          'tags': [
            {'name': 'mood'},
          ],
        },
        {'type': 'skill', 'name': 'guide', 'file': 'guide.md'},
      ],
    }),
  ),
  'guide.md': utf8.encode('# 写诗指南\n押韵。'),
};

final _history = [
  Message(
    id: 'u1',
    role: 'user',
    content: '早上好',
    createdAt: _now.subtract(const Duration(hours: 1)),
  ),
  Message(
    id: 'a1',
    role: 'assistant',
    content: '早呀<mood>开心</mood>今天也写诗吧',
    createdAt: _now.subtract(const Duration(minutes: 59)),
  ),
  Message(id: 'u2', role: 'user', content: '写一首', createdAt: _now),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;
  late List<Override> overrides;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final root = await Directory.systemTemp.createTemp('package_request_');
    final oldPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    TraceStore.instance.debugResetForTest();
    final database = db.AppDatabase.forTesting(
      NativeDatabase(File('${root.path}/test.sqlite')),
    );
    overrides = [
        databaseProvider.overrideWithValue(database),
        appSettingsProvider.overrideWith(() => _Settings(_settings())),
        requestClockProvider.overrideWithValue(() => _now),
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
        packageStoreProvider.overrideWith(
          (ref) => PackageStore(Directory('${root.path}/packages')),
        ),
      ];
    container = ProviderContainer(overrides: overrides);
    addTearDown(() async {
      container.dispose();
      await database.close();
      PathProviderPlatform.instance = oldPaths;
      await root.delete(recursive: true);
    });
    await container.read(appSettingsProvider.future);
    await container
        .read(aicovePackagesProvider.notifier)
        .importFiles(_packageFiles());
  });

  Conversation conversation(List<String>? plugins) => Conversation(
        id: 'pkg_role',
        title: '理',
        displayName: '理',
        personaPrompt: PersonaPromptCodec.compose(userPrompt: '你是测试角色。'),
        enabledPlugins: plugins,
        createdAt: _now,
        updatedAt: _now,
        messages: const [],
      );

  Future<ApiConfig> prepare(List<String>? plugins) =>
      container.read(chatSendServiceProvider).prepareApiConfig(
            conv: conversation(plugins),
            history: _history,
            userText: '写一首',
          );

  String messagesOf(ApiConfig config) => jsonEncode(config.messages);
  List<String> toolsOf(ApiConfig config) => [
    for (final tool in config.tools ?? const [])
      (tool['function'] as Map)['name'] as String,
  ];

  test(
    'an enabled package contributes its prompt, tags and skill tool',
    () async {
      final config = await prepare(['pkg:demo']);

      expect(messagesOf(config), contains(_prompt));
      expect(messagesOf(config), contains('<mood>开心</mood>'));
      // delegate_task is built in for every chat run (ADR0088).
      expect(toolsOf(config), [_tool, 'delegate_task', 'steer_task', 'read_tool_result']);
      final tool = config.boundTools!.singleWhere((t) => t.name == _tool);
      expect(await tool.handler({'name': 'guide'}), '# 写诗指南\n押韵。');
    },
  );

  test(
    '"all plugins" does not include a package; its context is stripped',
    () async {
      final config = await prepare(null);

      expect(messagesOf(config), isNot(contains(_prompt)));
      expect(messagesOf(config), isNot(contains('<mood>')));
      expect(messagesOf(config), contains('今天也写诗吧'));
      expect(toolsOf(config), isNot(contains(_tool)));
    },
  );

  test('a fresh container sees packages already on disk in its first request',
      () async {
    // The background isolate builds a new container for every task; the
    // first assembly must wait for the package list to load from disk.
    final fresh = ProviderContainer(overrides: overrides);
    addTearDown(fresh.dispose);
    final config = await fresh.read(chatSendServiceProvider).prepareApiConfig(
          conv: conversation(['pkg:demo']),
          history: _history,
          userText: '写一首',
        );

    expect(jsonEncode(config.messages), contains(_prompt));
  });

  test('after delete the next request has none of its content', () async {
    await container.read(aicovePackagesProvider.notifier).delete('demo');
    final config = await prepare(['pkg:demo']);

    expect(messagesOf(config), isNot(contains(_prompt)));
    expect(toolsOf(config), isNot(contains(_tool)));
    expect(
      config.boundTools?.map((t) => t.name) ?? const [],
      isNot(contains(_tool)),
    );
  });

  test(
    'script prompts stay on chat; execution tools only reach tool-mode roles and revoke next run',
    () async {
      await container
          .read(aicovePackagesProvider.notifier)
          .importFiles(scriptFiles(scriptSource));
      Future<ApiConfig> request({bool toolMode = false, bool enabled = true}) =>
          container
              .read(chatSendServiceProvider)
              .prepareApiConfig(
                conv: conversation(enabled ? ['pkg:demo'] : []).copyWith(
                  agentMode: toolMode ? RoleAgentMode.tool : RoleAgentMode.chat,
                ),
                history: _history,
                userText: 'compute',
              );
      final chat = await request();
      expect(messagesOf(chat), contains('script-prompt'));
      expect(toolsOf(chat), isNot(contains('pkg_4_demo_answer')));
      expect(
        chat.boundTools?.map((t) => t.name) ?? [],
        isNot(contains('pkg_4_demo_answer')),
      );
      final tool = await request(toolMode: true);
      expect(toolsOf(tool), contains('codemode'));
      expect(toolsOf(tool), isNot(contains('pkg_4_demo_answer')));
      expect(jsonEncode(tool.tools), contains('pkg_4_demo_answer'));
      expect(
        tool.boundTools!.map((t) => t.name),
        contains('pkg_4_demo_answer'),
      );
      expect(toolsOf(tool), isNot(contains('delegate_task')));
      final off = await request(toolMode: true, enabled: false);
      expect(toolsOf(off), isNot(contains('pkg_4_demo_answer')));
      expect(
        off.boundTools!.map((t) => t.name),
        isNot(contains('pkg_4_demo_answer')),
      );
      expect(jsonEncode(off.tools), isNot(contains('pkg_4_demo_answer')));
      expect(messagesOf(off), isNot(contains('script-prompt')));
      // A prior run's bound handler keeps its snapshot.
      final output = await tool.boundTools!
          .singleWhere((t) => t.name == 'pkg_4_demo_answer')
          .invoke({'value': 4});
      expect(output.text, contains('12'));
    },
  );
}
