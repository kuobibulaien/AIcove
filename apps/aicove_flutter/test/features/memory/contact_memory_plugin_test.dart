import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aicove_flutter/src/core/api/agent_api.dart';
import 'package:aicove_flutter/src/core/api/providers/provider_adapter.dart';
import 'package:aicove_flutter/src/core/app_logger.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_api_runner.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';

import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/core/database/converters/database_converters.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_plugin_context_builder.dart';
import 'package:aicove_flutter/src/features/memory/data/markdown_contact_memory_store.dart';
import 'package:aicove_flutter/src/features/memory/domain/contact_memory_port.dart';
import 'package:aicove_flutter/src/features/memory/providers/contact_memory_provider.dart';
import 'package:aicove_flutter/src/features/plugins/memory/memory_config.dart';
import 'package:aicove_flutter/src/features/plugins/memory/memory_plugin.dart';

class _MemoryToolClient extends AgentApiClient {
  _MemoryToolClient() : super();
  int calls = 0;
  List<Map<String, dynamic>> continuation = [];
  @override
  Future<SendMessageRichResult> sendMessageRich({
    required String agentId,
    required String sessionId,
    required String modelFullId,
    required List<Map<String, dynamic>> messages,
    required String userText,
    double? temperature,
    double? topP,
    String? token,
    Map<String, dynamic>? toolPrefs,
    String? providerApiBase,
    String? providerApiKey,
    Map<String, dynamic>? customConfig,
    ProviderChatRequestOptions? requestOptions,
    List<Map<String, dynamic>>? tools,
    TraceLogger? trace,
    String? turnId,
    int? roundIndex,
    String? traceId,
  }) async {
    calls++;
    if (calls == 1) {
      return const SendMessageRichResult(
        text: '',
        toolResults: [],
        toolCalls: [
          ToolCall(
            id: 'call1',
            name: 'memory_read',
            arguments: {'id': 'a_event'},
          ),
        ],
      );
    }
    continuation = List.of(messages);
    return const SendMessageRichResult(text: '读取完成', toolResults: []);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late db.AppDatabase database;
  late ProviderContainer container;
  late MarkdownContactMemoryStore store;
  late MemoryPlugin plugin;
  final pluginProvider = Provider(
    (ref) => MemoryPlugin(const MemoryConfig(), ref),
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('memory_plugin_');
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    store = MarkdownContactMemoryStore(() async => root);
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        contactMemoryPortProvider.overrideWithValue(store),
      ],
    );
    final now = DateTime.utc(2026, 9, 1);
    for (final id in ['a', 'b']) {
      await container
          .read(conversationRepositoryProvider)
          .upsert(
            ConversationConverter.toCompanion(
              Conversation(
                id: id,
                title: '同名角色',
                displayName: '同名角色',
                createdAt: now,
                updatedAt: now,
              ),
            ),
          );
      await store.save(
        (await store.load(id)).copyWith(
          enabled: true,
          core: '$id 独立偏好',
          events: [
            ContactMemoryEvent(
              id: '${id}_event',
              title: '$id 面试',
              body: '$id 私有往事',
              occurredAt: now,
            ),
          ],
        ),
      );
    }
    plugin = container.read(pluginProvider);
  });
  tearDown(() async {
    container.dispose();
    await database.close();
    await root.delete(recursive: true);
  });

  test('无总结/Embedding 配置也注入 MD；缺 owner 不回退到活动角色', () async {
    final prompt = await plugin.getSystemPrompt(
      userMessage: '你好',
      conversationId: 'a',
      supportsToolCalling: true,
    );
    expect(prompt, contains('a 独立偏好'));
    expect(prompt, isNot(contains('b 独立偏好')));
    expect(await plugin.getSystemPrompt(userMessage: '你好'), isNull);
    expect(plugin.getTools(), isEmpty); // 不提供无作用域的全局工具。
    expect(await plugin.getToolsForConversation(null), isEmpty);
  });

  test('真实收集器绑定请求 A，随后请求 B 不改变 A 工具权限', () async {
    const builder = ChatPluginContextBuilder();
    final aTools = await builder.collectPluginToolsWithRetry([
      plugin,
    ], conversationId: 'a');
    final bTools = await builder.collectPluginToolsWithRetry([
      plugin,
    ], conversationId: 'b');
    expect(aTools.map((t) => t.name), ['memory_search', 'memory_read']);
    final aRead = aTools.singleWhere((t) => t.name == 'memory_read');
    final bRead = bTools.singleWhere((t) => t.name == 'memory_read');
    expect(await aRead.handler({'id': 'a_event'}), contains('a 私有往事'));
    expect(await aRead.handler({'id': 'b_event'}), contains('not_found'));
    expect(await bRead.handler({'id': 'a_event'}), contains('not_found'));
    expect(
      await aRead.handler({'id': 'b_event', 'ownerId': 'b'}),
      contains('invalid_request'),
    );
    expect(
      await aRead.handler({'id': '../b/MEMORY.md'}),
      contains('invalid_request'),
    );
    final schemas = jsonEncode(aTools.map((t) => t.toOpenAISchema()).toList());
    expect(schemas, isNot(contains('ownerId')));
    expect(schemas, isNot(contains('conversationId')));
  });

  test('真实工具循环使用请求绑定的 handler，把本角色正文回传模型', () async {
    final tools = await const ChatPluginContextBuilder()
        .collectPluginToolsWithRetry([plugin], conversationId: 'a');
    final settings = await container.read(appSettingsProvider.future);
    final client = _MemoryToolClient();
    final result =
        await ChatSendApiRunner.withAgentClientFactory(
          agentClientFactory: (_) => client,
        ).executeApiCall(
          config: ApiConfig(
            settings: settings,
            modelFullId: 'openai:test',
            providerApiBase: 'https://unused.invalid',
            customConfig: const {},
            toolPrefs: const {},
            messages: const [
              {'role': 'user', 'content': '回忆往事'},
            ],
            tools: tools.map((t) => t.toOpenAISchema()).toList(),
            boundTools: tools,
          ),
          sessionId: 'deliberately_not_a_contact_id',
          userText: '回忆往事',
          effectivePlugins: const [],
        );
    expect(client.calls, 2);
    expect(result.replyText, '读取完成');
    expect(jsonEncode(client.continuation), contains('a 私有往事'));
    expect(jsonEncode(client.continuation), isNot(contains('b 私有往事')));
  });

  test('切回旧模式后旧闭包禁用，不暴露 MD 正文', () async {
    final tools = await plugin.getToolsForConversation('a');
    await store.save((await store.load('a')).copyWith(enabled: false));
    expect(await tools.last.handler({'id': 'a_event'}), contains('disabled'));
    expect(await plugin.getToolsForConversation('a'), isEmpty);
  });

  test('角色禁用插件或删除后，旧请求闭包拒绝读取', () async {
    final tools = await plugin.getToolsForConversation('a');
    await container.read(conversationRepositoryProvider).softDelete('a', 1, 2);
    expect(await tools.first.handler({}), contains('disabled'));
  });
}
