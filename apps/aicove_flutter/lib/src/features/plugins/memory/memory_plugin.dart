import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_logger.dart';
import '../../../core/database/database_provider.dart';
import '../../chat/services/chat_history_store.dart';
import '../../memory/application/memory_retrieval.dart';
import '../../memory/providers/memory_providers.dart';
import '../domain/index.dart';

/// 长期记忆插件：只负责在每轮请求前注入该角色的记忆。
///
/// 是否启用由角色的插件选择决定（ADR0035）。不向聊天模型提供任何工具，
/// 记忆的整理只在压缩时由独立的记忆 Agent 完成（ADR0038）。
class MemoryPlugin extends BasePlugin {
  static const _metadata = PluginMetadata(
    id: 'memory',
    name: '长期记忆',
    description: '在聊天时带上这个角色的长期记忆；压缩时自动整理',
    version: '3.0.0',
    author: 'AIcove Team',
    icon: Icons.memory,
  );

  MemoryPlugin(this._ref) : super(metadata: _metadata);
  final Ref _ref;

  @override
  bool get enabled => true;

  @override
  Future<String?> getSystemPrompt({
    String? userMessage,
    bool supportsToolCalling = false,
    String? conversationId,
  }) async {
    // 缺少请求作用域时失败关闭；活动页面可能已经切到别的角色。
    final ownerId = conversationId?.trim() ?? '';
    if (ownerId.isEmpty) return null;
    // 上次中途退出留下的整理任务，借本次启动后第一次发送在后台续跑。
    _ref.read(memoryKeeperProvider).resumeOnce(ownerId);
    final recent = await _ref
        .read(chatHistoryStoreProvider)
        .loadRecentProjectedMessages(ownerId, limit: 4);
    return _ref
        .read(memoryInjectorProvider)
        .build(
          ownerId: ownerId,
          roleLabel: await _roleLabel(ownerId),
          query: buildMemoryQuery(recent, userMessage ?? ''),
        )
        .timeout(
          const Duration(seconds: 2),
          onTimeout: () {
            AppLogger.warning(
              'MemoryPlugin',
              '读取长期记忆超时，本轮不注入',
              metadata: {'conversationId': ownerId},
            );
            return null;
          },
        );
  }

  @override
  Future<PluginProcessResult> processResponse(String text) async =>
      PluginProcessResult(processedText: text, events: const []);

  Future<String> _roleLabel(String ownerId) async {
    final row = await _ref.read(conversationRepositoryProvider).getById(ownerId);
    final name = row?.displayName.trim() ?? '';
    if (name.isNotEmpty) return name;
    final title = row?.title.trim() ?? '';
    return title.isNotEmpty ? title : '当前角色';
  }
}
