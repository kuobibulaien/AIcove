import 'dart:convert';

import 'package:aicove_flutter/src/core/database/database.dart' hide Provider;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/core/services/system_reminder_service.dart';
import 'package:aicove_flutter/src/features/agent_plugins/plugin_request_scope.dart';
import 'package:aicove_flutter/src/features/agent_plugins/plugin_runtime.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/auto_reply_trigger.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/auto_reply_trigger_controller.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
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
import 'package:shared_preferences/shared_preferences.dart';

final _refProvider = Provider<Ref>((ref) => ref);
final _fireAt = DateTime.now().add(const Duration(days: 1));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late ProviderContainer container;
  late TriggerPlugin plugin;

  setUp(() async {
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

  List<AITool> requestTools({String? conversationId = 'conv_a'}) {
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
      supportsToolCalling: true,
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
    String name, [
    Map<String, dynamic> args = const {},
  ]) async =>
      jsonDecode(
            (await tools.singleWhere((t) => t.name == name).handler(args))!,
          )
          as Map<String, dynamic>;

  List<AutoReplyTrigger> triggers() =>
      container.read(autoReplyTriggersProvider).requireValue;

  test(
    'request list and search stay with the owner after switching roles',
    () async {
      final tools = requestTools();
      for (final name in ['list_reminders', 'search_reminders']) {
        final response = await invoke(tools, name, {'query': '喝水'});
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
      final response = await invoke(requestTools(), 'create_reminder', {
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
      final response = await invoke(requestTools(), 'create_reminder', {
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
      (await invoke(tools, 'delete_reminder', {'id': 'reminder_b'}))['ok'],
      isFalse,
    );
    expect(
      (await invoke(tools, 'delete_reminder', {'id': 'reminder_a'}))['ok'],
      isTrue,
    );
    expect(triggers().map((t) => t.id), ['reminder_b']);
  });

  test('request deletion by query searches only its owner', () async {
    final response = await invoke(requestTools(), 'delete_reminder', {
      'query': '喝水',
    });
    expect(response['ok'], isTrue);
    expect(triggers().map((t) => t.id), ['reminder_b']);
  });

  for (final owner in [null, '', '  ']) {
    test('request without an owner fails closed ($owner)', () async {
      final tools = requestTools(conversationId: owner);
      for (final (name, args) in [
        ('list_reminders', <String, dynamic>{}),
        ('search_reminders', <String, dynamic>{'query': '喝水'}),
        ('delete_reminder', <String, dynamic>{'id': 'reminder_b'}),
        ('delete_reminder', <String, dynamic>{'query': '喝水 b'}),
        (
          'create_reminder',
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
      final response = await invoke(tools, 'list_reminders');
      expect((response['result'] as List).map((t) => t['id']), ['reminder_b']);
    },
  );
}
