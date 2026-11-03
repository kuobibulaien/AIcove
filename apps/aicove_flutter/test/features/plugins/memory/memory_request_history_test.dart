import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/features/agent_plugins/plugin_request_context.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_history_store.dart';
import 'package:aicove_flutter/src/features/memory/domain/memory_item.dart';
import 'package:aicove_flutter/src/features/memory/domain/memory_ports.dart';
import 'package:aicove_flutter/src/features/memory/providers/memory_providers.dart';
import 'package:aicove_flutter/src/features/plugins/memory/memory_agent_plugin.dart';
import 'package:aicove_flutter/src/features/plugins/memory/memory_plugin.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final _refProvider = Provider<Ref>((ref) => ref);

class _Retriever implements MemoryRetriever {
  final queries = <String>[];

  @override
  Future<List<MemoryItem>> retrieve(
    String ownerId,
    String query, {
    int limit = 6,
  }) async {
    queries.add(query);
    return [];
  }
}

Message _message(String id, String text) =>
    Message(id: id, role: 'user', content: text, createdAt: DateTime(2026));

void main() {
  test('重放旧锚点只用本次裁切 Raw 历史，不读取最新投影或后续对话', () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    await database.customStatement(
      "INSERT INTO conversations(id,title,display_name,created_at,updated_at) "
      "VALUES('a','角色','角色',1,1)",
    );
    final retriever = _Retriever();
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        memoryRetrieverProvider.overrideWithValue(retriever),
        chatHistoryStoreProvider.overrideWith(
          (_) => throw StateError('记忆检索不得重新加载聊天历史'),
        ),
      ],
    );
    addTearDown(container.dispose);
    final scope = MemoryRequestScope(
      MemoryPlugin(container.read(_refProvider)),
    );
    final all = [
      _message('before-topic', '上一个话题污染'),
      _message('topic', '去海边'),
      _message('anchor', '看日落'),
      _message('after-anchor', '后续对话污染'),
    ];
    await scope.prompt(
      PluginRequestContext(
        userMessage: '看日落',
        supportsToolCalling: false,
        conversationId: 'a',
        readOnly: true,
        rawHistory: all.sublist(1, 3),
      ),
    );
    expect(retriever.queries, ['去海边\n看日落']);

    // Existing callers with no request history do not regain access to latest DB
    // messages; only their explicit current input contributes to retrieval.
    await scope.prompt(
      const PluginRequestContext(
        userMessage: '现在的问题',
        supportsToolCalling: false,
        conversationId: 'a',
        readOnly: true,
      ),
    );
    expect(retriever.queries.last, '现在的问题');
  });
}
