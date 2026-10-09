import 'dart:convert';
import 'dart:io';

import 'package:aicove_flutter/src/core/database/converters/database_converters.dart';
import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/features/agent_context/data/silly_tavern_preset_store.dart';
import 'package:aicove_flutter/src/features/agent_context/providers/preset_recipe_provider.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_service.dart';
import 'package:aicove_flutter/src/features/conversation_state/providers/conversation_state_providers.dart';
import 'package:aicove_flutter/src/features/memory/application/memory_keeper_service.dart';
import 'package:aicove_flutter/src/features/memory/providers/memory_providers.dart';
import 'package:aicove_flutter/src/features/observability/trace_store.dart';
import 'package:aicove_flutter/src/features/plugins/plugin_manager.dart';
import 'package:aicove_flutter/src/features/plugins/plugin_providers.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
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
  @override
  Future<AppSettings> build() async =>
      mapUiModelsToAppSettings({'context_window_tokens': 272000});
}

/// ADR0071 验收 4、5：最终请求里有当前变量、没有历史更新块；开关隔离。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late db.AppDatabase database;
  late ProviderContainer container;
  late PathProviderPlatform oldPaths;
  var clock = 0;

  Future<void> message(String id, String role, String text) async {
    clock++;
    await database
        .into(database.messages)
        .insert(
          db.MessagesCompanion.insert(
            id: id,
            conversationId: 'a',
            role: role,
            content: text,
            createdAt: clock,
            status: const Value('sent'),
            rawPayload: Value(
              role == 'assistant' ? jsonEncode({'rawReplyText': text}) : null,
            ),
          ),
        );
  }

  Future<void> bindPreset() async {
    final store = container.read(sillyTavernPresetStoreProvider);
    final preset = await store.importSource(
      jsonEncode({
        'name': 'MVU 预设',
        'prompts': [
          {'identifier': 'main', 'role': 'system', 'content': '主提示：照常聊天。'},
          {
            'identifier': 'rule',
            'role': 'system',
            'content':
                "回复末尾输出 <UpdateVariable>_.set('路径', 旧, 新);</UpdateVariable>",
          },
          {'identifier': 'worldInfoBefore', 'marker': true},
          {'identifier': 'chatHistory', 'marker': true},
        ],
        'prompt_order': [
          {
            'order': [
              {'identifier': 'main', 'enabled': true},
              {'identifier': 'rule', 'enabled': true},
              {'identifier': 'worldInfoBefore', 'enabled': true},
              {'identifier': 'chatHistory', 'enabled': true},
            ],
          },
        ],
      }),
      sourceFileName: 'mvu.json',
    );
    await store.importWorldBook(
      preset.id,
      jsonEncode({
        'name': '书',
        'entries': {
          '0': {
            'uid': 0,
            'comment': '[InitVar]初始变量',
            'disable': true,
            'content': '{"理": {"好感度": [0, "[-30,100]"]}}',
          },
          '1': {
            'uid': 1,
            'comment': '变量输出',
            'constant': true,
            'position': 0,
            'content': '当前变量：{{get_message_variable::stat_data.理.好感度[0]}}',
          },
          '2': {
            'uid': 2,
            'comment': '分段好感',
            'constant': true,
            'position': 0,
            'content': '<% if (true) { %>EJS内容<% } %>',
          },
          '3': {
            'uid': 3,
            'comment': '普通设定',
            'constant': true,
            'position': 0,
            'content': '这里是教堂。',
          },
        },
      }),
      '书.json',
    );
    await (database.update(database.conversations)
          ..where((c) => c.id.equals('a')))
        .write(db.ConversationsCompanion(recipeId: Value(preset.id)));
  }

  Future<String> requestText() async {
    final conv = ConversationConverter.fromDb(
      (await container.read(conversationRepositoryProvider).getById('a'))!,
    );
    final user = Message(
      id: 'u2',
      role: 'user',
      content: '我们去散步吧',
      createdAt: DateTime.now(),
    );
    final sender = container.read(chatSendServiceProvider);
    final history = await sender.prepareHistoryFromStore(
      conv: conv,
      userMsg: user,
    );
    final config = await sender.prepareApiConfig(
      conv: conv,
      history: history,
      userText: user.content,
    );
    return config.messages.map((m) => m['content'].toString()).join('\n');
  }

  setUp(() async {
    clock = 0;
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('mvu_request_');
    oldPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    TraceStore.instance.debugResetForTest();
    database = db.AppDatabase.forTesting(
      NativeDatabase(File('${root.path}/test.sqlite')),
    );
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        appSettingsProvider.overrideWith(_Settings.new),
        pluginManagerProvider.overrideWithValue(PluginManager()),
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
      ],
    );
    await database.customStatement('PRAGMA foreign_keys = ON');
    await database
        .into(database.conversations)
        .insert(
          db.ConversationsCompanion.insert(
            id: 'a',
            title: '理',
            displayName: '理',
            createdAt: 1,
            updatedAt: 1,
          ),
        );
    await bindPreset();
    await message(
      'msg_greeting_a',
      'assistant',
      "早安。<UpdateVariable>_.set('理.好感度', 0, 10);</UpdateVariable>",
    );
    await message('u1', 'user', '早');
    await message(
      'a1',
      'assistant',
      "她笑了。<UpdateVariable>_.add('理.好感度', 5);//被逗笑</UpdateVariable>",
    );
  });

  tearDown(() async {
    await TraceStore.instance.waitForPendingWrites();
    TraceStore.instance.debugResetForTest();
    container.dispose();
    await database.close();
    PathProviderPlatform.instance = oldPaths;
    await root.delete(recursive: true);
  });

  test('开启时：请求里有当前变量，历史更新块被去掉，预设协议示例保留，EJS 条目跳过', () async {
    final text = await requestText();
    expect(text, contains('当前变量：15'));
    expect(text, contains('她笑了。'));
    expect(text, isNot(contains("_.add('理.好感度', 5)")));
    expect(text, isNot(contains("_.set('理.好感度', 0, 10)")));
    expect(
      text,
      contains("<UpdateVariable>_.set('路径', 旧, 新);</UpdateVariable>"),
    );
    expect(text, isNot(contains('EJS内容')));
    expect(text, isNot(contains('[-30,100]')), reason: 'InitVar 条目永不注入');
    expect(text, contains('这里是教堂。'));

    // 落库状态等于对原文的重放结果。
    final view = await container.read(conversationStatePortProvider).read('a');
    expect(view.active, isTrue);
    expect(view.mvu!.statData, {
      '理': {
        '好感度': [15, '[-30,100]'],
      },
    });
  });

  test('关闭时：MVU 专属条目不进请求，历史更新块照样去掉', () async {
    await (database.update(
      database.conversations,
    )..where((c) => c.id.equals('a'))).write(
      const db.ConversationsCompanion(enabledPlugins: Value('["memory"]')),
    );
    final text = await requestText();
    expect(text, isNot(contains('当前变量')));
    expect(text, isNot(contains('<UpdateVariable>')));
    expect(text, contains('主提示：照常聊天。'));
    expect(text, contains('这里是教堂。'));
    expect(text, isNot(contains("_.add('理.好感度', 5)")));
    final rows = await database
        .customSelect('SELECT COUNT(*) AS n FROM message_states')
        .getSingle();
    expect(rows.read<int>('n'), 0, reason: '关闭时不初始化、不解析');
  });
}
