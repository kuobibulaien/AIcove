import 'dart:convert';
import 'dart:io';

import 'package:aicove_flutter/src/core/database/database.dart'
    hide Provider, Conversation, Message;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/core/services/system_reminder_service.dart';
import 'package:aicove_flutter/src/features/agent_plugins/plugin_request_scope.dart';
import 'package:aicove_flutter/src/features/agent_plugins/plugin_runtime.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/auto_reply_trigger.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/auto_reply_trigger_controller.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/domain/role_agent_mode.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_service.dart';
import 'package:aicove_flutter/src/features/plugins/trigger/trigger_agent_plugin.dart';
import 'package:aicove_flutter/src/features/plugins/domain/handlers/ai_tool.dart';
import 'package:aicove_flutter/src/features/plugins/image/image_config.dart';
import 'package:aicove_flutter/src/features/plugins/prompts/plugin_prompts.dart';
import 'package:aicove_flutter/src/features/plugins/trigger/trigger_config.dart';
import 'package:aicove_flutter/src/features/plugins/trigger/trigger_plugin.dart';
import 'package:aicove_flutter/src/features/plugins/tts/voice_request.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _refProvider = Provider<Ref>((ref) => ref);
final _fireAt = DateTime.now().add(const Duration(days: 1));

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.rootPath);

  final String rootPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => rootPath;

  @override
  Future<String?> getTemporaryPath() async => rootPath;
}

class _ReminderSettings extends AppSettingsNotifier {
  @override
  Future<AppSettings> build() async =>
      mapUiModelsToAppSettings(const {}).copyWith(
        defaultModelName: 'openai:gpt-4o',
        defaultChatModels: ['openai:gpt-4o'],
        providers: const [
          ProviderAuth(
            id: 'openai',
            apiKeys: ['test-key'],
            apiBaseUrl: 'https://api.openai.com/v1',
          ),
        ],
        modelProviderMap: const {'openai:gpt-4o': 'openai'},
        modelConfigs: const {
          'openai:gpt-4o': ModelConfig(chatCapabilities: ['tools']),
        },
        autoReplySettings: const AutoReplySettings(allowAiSetReminders: true),
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late ProviderContainer container;
  late TriggerPlugin plugin;

  setUp(() async {
    final previousPaths = PathProviderPlatform.instance;
    final root = await Directory.systemTemp.createTemp('trigger_scope_test_');
    PathProviderPlatform.instance = _FakePathProviderPlatform(root.path);
    addTearDown(() async {
      PathProviderPlatform.instance = previousPaths;
      await root.delete(recursive: true);
    });
    SharedPreferences.setMockInitialValues({
      'aicove.auto_triggers.v1': jsonEncode([
        for (final owner in ['a', 'b'])
          {
            'id': 'reminder_$owner',
            'title': '喝水 $owner',
            'type': 'fixed',
            'status': 'pending',
            'created_at': DateTime.now().toIso8601String(),
            'next_fire_at': _fireAt.toIso8601String(),
            'conversation_id': 'conv_$owner',
          },
      ]),
    });
    db = AppDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    final at = DateTime.now().millisecondsSinceEpoch;
    for (final owner in ['a', 'b']) {
      await db
          .into(db.conversations)
          .insert(
            ConversationsCompanion.insert(
              id: 'conv_$owner',
              title: owner,
              displayName: owner,
              createdAt: at,
              updatedAt: at,
            ),
          );
      await db
          .into(db.messages)
          .insert(
            MessagesCompanion.insert(
              id: 'user_$owner',
              conversationId: 'conv_$owner',
              role: 'user',
              content: '提醒我喝水',
              createdAt: at,
            ),
          );
    }
    await container.read(autoReplyTriggersProvider.future);
    container.read(activeConversationIdProvider.notifier).state = 'conv_a';
    plugin = TriggerPlugin(const TriggerConfig(), container.read(_refProvider));
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  List<AITool> requestTools({
    String? conversationId = 'conv_a',
    bool supportsToolCalling = true,
  }) {
    final runtime = PluginRuntime.fromPlugins([plugin]);
    final inputs = PluginRequestInputs(
      ref: container.read(_refProvider),
      conversationId: conversationId,
      settings: mapUiModelsToAppSettings(const {}),
      imageConfig: const ImageConfig(),
      voiceRequest: VoiceRequest(ownerId: conversationId ?? ''),
      pluginPrompts: const PluginPrompts(),
      history: const [],
      previousUserMessageTime: null,
      useFastImageRoute: false,
      useStableImageRoute: true,
      supportsToolCalling: supportsToolCalling,
      reminders: const SystemReminderService(),
    );
    final scope = runtime
        .requestScopes(runtime.snapshot(), runtime.selectForRole(null), inputs)
        .single;
    // Switch before collecting tools too: identity belongs to the scope,
    // not to the UI when tools are collected or eventually invoked.
    container.read(activeConversationIdProvider.notifier).state = 'conv_b';
    return scope.tools();
  }

  Future<Map<String, dynamic>> invoke(
    List<AITool> tools,
    String action, [
    Map<String, dynamic> args = const {},
  ]) async =>
      jsonDecode(
            (await tools.singleWhere((t) => t.name == 'reminder').handler({
              'action': action,
              ...args,
            }))!,
          )
          as Map<String, dynamic>;

  List<AutoReplyTrigger> triggers() =>
      container.read(autoReplyTriggersProvider).requireValue;

  test('exposes only reminder with a required action enum', () async {
    final tools = requestTools();
    expect(tools.map((tool) => tool.name), ['reminder']);
    expect(TriggerPlugin.contentTags.toolNames, {'reminder'});
    expect(TriggerPlugin.contentTags.tagSpecs, isEmpty);
    final action = tools.single.parameters['action']!;
    expect(action.required, isTrue);
    expect(action.enumValues, ['create', 'list', 'delete']);
    for (final args in [
      <String, dynamic>{},
      {'action': 'invalid'},
    ]) {
      final response = jsonDecode((await tools.single.handler(args))!);
      expect(response['ok'], isFalse);
    }
    expect(triggers(), hasLength(2));
  });

  test('does not expose tools to models without tool calling', () {
    expect(requestTools(supportsToolCalling: false), isEmpty);
  });

  test('inactive scopes do not expose tools', () {
    final disabled = TriggerPlugin(
      const TriggerConfig(enabled: false),
      container.read(_refProvider),
    );
    expect(
      TriggerRequestScope(disabled, conversationId: 'conv_a').tools(),
      isEmpty,
    );
  });

  test(
    'ordinary chat with only trigger binds reminder without delegation',
    () async {
      final requestContainer = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          appSettingsProvider.overrideWith(_ReminderSettings.new),
        ],
      );
      addTearDown(requestContainer.dispose);
      final now = DateTime.now();
      final config = await requestContainer
          .read(chatSendServiceProvider)
          .prepareApiConfig(
            conv: Conversation(
              id: 'conv_a',
              title: 'a',
              displayName: 'a',
              agentMode: RoleAgentMode.chat,
              enabledPlugins: const ['trigger'],
              createdAt: now,
              updatedAt: now,
              messages: const [],
            ),
            history: [
              Message(
                id: 'request_user',
                role: 'user',
                content: '明天提醒我喝水',
                createdAt: now,
              ),
            ],
            userText: '明天提醒我喝水',
          );
      expect(config.boundTools?.map((tool) => tool.name), ['reminder']);
    },
  );

  test(
    'request list and search stay with the owner after switching roles',
    () async {
      final tools = requestTools();
      for (final args in [
        <String, dynamic>{},
        {'query': '喝水'},
      ]) {
        final response = await invoke(tools, 'list', args);
        expect(response['ok'], isTrue);
        expect((response['result'] as List).map((t) => t['id']), [
          'reminder_a',
        ]);
      }
    },
  );

  test(
    'request create stays with its owner and anchors that user message',
    () async {
      final response = await invoke(requestTools(), 'create', {
        'title': '起床',
        'time': _fireAt.toIso8601String(),
        'prompt': '到点轻声叫我',
      });
      expect(response['ok'], isTrue);
      final created = triggers().singleWhere((t) => t.title == '起床');
      expect(created.conversationId, 'conv_a');
      expect(created.contextLastUserMessageId, 'user_a');
      expect(created.prompt, '到点轻声叫我');
      expect(created.source, TriggerSource.userRequest);
      expect(created.priority, AutoReplyTriggerPriority.high);
      expect(created.manual, isTrue);
    },
  );

  for (final prompt in [null, '', ' \n\t ']) {
    test('create defaults a blank prompt to its title ($prompt)', () async {
      final response = await invoke(requestTools(), 'create', {
        'title': '记得喝水',
        'time': _fireAt.toIso8601String(),
        if (prompt != null) 'prompt': prompt,
      });
      expect(response['ok'], isTrue);
      expect(triggers().singleWhere((t) => t.title == '记得喝水').prompt, '记得喝水');
    });
  }

  test('request deletion by id cannot delete the UI role reminder', () async {
    final tools = requestTools();
    expect(
      (await invoke(tools, 'delete', {'id': 'reminder_b'}))['ok'],
      isFalse,
    );
    expect((await invoke(tools, 'delete', {'id': 'reminder_a'}))['ok'], isTrue);
    expect(triggers().map((t) => t.id), ['reminder_b']);
  });

  test('request deletion by query searches only its owner', () async {
    final response = await invoke(requestTools(), 'delete', {'query': '喝水'});
    expect(response['ok'], isTrue);
    expect(triggers().map((t) => t.id), ['reminder_b']);
  });

  for (final owner in [null, '', '  ']) {
    test('request without an owner fails closed ($owner)', () async {
      final tools = requestTools(conversationId: owner);
      for (final (name, args) in [
        ('list', <String, dynamic>{}),
        ('list', <String, dynamic>{'query': '喝水'}),
        ('delete', <String, dynamic>{'id': 'reminder_b'}),
        ('delete', <String, dynamic>{'query': '喝水 b'}),
        (
          'create',
          <String, dynamic>{'title': '不应创建', 'time': _fireAt.toIso8601String()},
        ),
      ]) {
        expect((await invoke(tools, name, args))['ok'], isFalse, reason: name);
      }
      expect(triggers().map((t) => t.id), ['reminder_a', 'reminder_b']);
    });
  }

  test(
    'legacy no-argument tools keep following the active conversation',
    () async {
      final tools = plugin.getTools();
      container.read(activeConversationIdProvider.notifier).state = 'conv_b';
      final response = await invoke(tools, 'list');
      expect((response['result'] as List).map((t) => t['id']), ['reminder_b']);
    },
  );
}
