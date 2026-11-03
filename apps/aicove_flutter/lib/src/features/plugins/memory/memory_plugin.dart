import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_logger.dart';
import '../../../core/database/database_provider.dart';
import '../../chat/domain/message.dart';
import '../../memory/application/memory_retrieval.dart';
import '../../memory/providers/memory_providers.dart';
import '../../agent_plugins/aicove_plugin.dart';
import '../domain/index.dart';
import 'memory_agent_plugin.dart';

/// 长期记忆插件：只负责在每轮请求前注入该角色的记忆。
///
/// 是否启用由角色的插件选择决定（ADR0035）。不向聊天模型提供任何工具，
/// 记忆的整理只在压缩时由独立的记忆 Agent 完成（ADR0038）。
class MemoryPlugin extends BasePlugin {
  static const _metadata = PluginMetadata(
    id: 'memory',
    name: '长期记忆',
    description: '在聊天时带上核心印象与往事日记；按聊天轮次在后台自动整理',
    version: '3.0.0',
    author: 'AIcove Team',
    icon: Icons.memory,
  );

  MemoryPlugin(this._ref) : super(metadata: _metadata);
  final Ref _ref;

  @override
  bool get enabled => true;

  @override
  AicovePlugin get agentPlugin => memoryAgentPlugin(this);

  /// The role's memory for this request; null without a request owner.
  Future<InjectedMemory?> buildMemory({
    String? userMessage,
    String? conversationId,
    bool resumeBackgroundWork = true,
    List<Message> rawHistory = const [],
  }) async {
    // 缺少请求作用域时失败关闭；活动页面可能已经切到别的角色。
    final ownerId = conversationId?.trim() ?? '';
    if (ownerId.isEmpty) return null;
    // 上次中途退出留下的整理任务，借本次启动后第一次发送在后台续跑。
    // 上下文预览只读，不能借预览启动整理（会请求记忆模型并写库）。
    if (resumeBackgroundWork) {
      _ref.read(memoryKeeperProvider).resumeOnce(ownerId);
    }
    return _ref
        .read(memoryInjectorProvider)
        .build(
          ownerId: ownerId,
          roleLabel: await _roleLabel(ownerId),
          query: buildMemoryQuery(rawHistory, userMessage ?? ''),
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

  Future<String> _roleLabel(String ownerId) async {
    final row = await _ref
        .read(conversationRepositoryProvider)
        .getById(ownerId);
    final name = row?.displayName.trim() ?? '';
    if (name.isNotEmpty) return name;
    final title = row?.title.trim() ?? '';
    return title.isNotEmpty ? title : '当前角色';
  }
}
