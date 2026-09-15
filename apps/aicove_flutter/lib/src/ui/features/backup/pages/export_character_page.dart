
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:share_plus/share_plus.dart';

import '../../../../features/backup/models/export_format.dart';
import '../../../../features/backup/backup_providers.dart';
import '../../../../features/chat/conversation_providers.dart';
import '../../../../features/chat/domain/conversation.dart';
import '../../../../features/chat/services/chat_history_store.dart';
import '../../../shared/animations/parallax_slide_page_route.dart';
import '../../../shared/effects/smooth_clip.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';
import 'chat_preview_page.dart';

final _exportConversationMessageCountProvider =
    FutureProvider.family<int, String>((ref, conversationId) {
  return ref.read(chatHistoryStoreProvider).loadMessageCount(conversationId);
});

/// 导出角色选择页面
class ExportCharacterPage extends ConsumerStatefulWidget {
  const ExportCharacterPage({super.key});

  @override
  ConsumerState<ExportCharacterPage> createState() => _ExportCharacterPageState();
}

class _ExportCharacterPageState extends ConsumerState<ExportCharacterPage> {
  bool _isExporting = false;

  @override
  Widget build(BuildContext context) {
    final conversationsAsync = ref.watch(conversationsProvider);
    final selectedIds = ref.watch(selectedConversationsProvider);
    final exportProgress = ref.watch(exportProgressProvider);

    return MoePageScaffold(
      appBar: MoeAppBar(
        title: '选择角色',
        showBackButton: true,
      ),
      body: Column(
        children: [
          // 全选栏
          conversationsAsync.when(
            data: (conversations) => _buildSelectAllBar(context, conversations),
            loading: () => const SizedBox.shrink(),
            error: (_, __) => const SizedBox.shrink(),
          ),

          // 角色列表
          Expanded(
            child: conversationsAsync.when(
              data: (conversations) {
                if (conversations.isEmpty) {
                  return const MoeEmptyState(
                    icon: LucideIcons.users,
                    title: '暂无角色',
                    description: '创建角色后才能导出',
                  );
                }
                return ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: conversations.length,
                  itemBuilder: (context, index) {
                    final conv = conversations[index];
                    final isSelected = selectedIds.contains(conv.id);
                    return _buildCharacterItem(context, conv, isSelected);
                  },
                );
              },
              loading: () => const Center(child: MoeLoadingIndicator()),
              error: (e, _) => Center(child: Text('加载失败: $e')),
            ),
          ),

          // 导出进度或按钮
          if (_isExporting && exportProgress != null)
            _buildProgressBar(context, exportProgress)
          else
            _buildExportButton(context, selectedIds),
        ],
      ),
    );
  }

  Widget _buildSelectAllBar(BuildContext context, List<Conversation> conversations) {
    final selectedIds = ref.watch(selectedConversationsProvider);
    final allIds = conversations.map((c) => c.id).toList();
    final isAllSelected = allIds.isNotEmpty && 
        allIds.every((id) => selectedIds.contains(id));
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: theme.dividerColor.withValues(alpha: 0.1),
          ),
        ),
      ),
      child: Row(
        children: [
          MoeCheckbox(
            value: isAllSelected,
            onChanged: (value) {
              if (value == true) {
                ref.read(selectedConversationsProvider.notifier).selectAll(allIds);
              } else {
                ref.read(selectedConversationsProvider.notifier).clear();
              }
            },
          ),
          const SizedBox(width: 8),
          Text(
            '全选',
            style: theme.textTheme.bodyMedium,
          ),
          const Spacer(),
          Text(
            '已选 ${selectedIds.length}/${conversations.length}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCharacterItem(BuildContext context, Conversation conv, bool isSelected) {
    final theme = Theme.of(context);
    final messageCountAsync =
        ref.watch(_exportConversationMessageCountProvider(conv.id));

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: MoeG2ClipRRect(
        radius: 12,
        child: Material(
          color: theme.cardColor,
          child: InkWell(
            onTap: () {
              ref.read(selectedConversationsProvider.notifier).toggle(conv.id);
            },
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  // 复选框
                  MoeCheckbox(
                    value: isSelected,
                    onChanged: (value) {
                      ref.read(selectedConversationsProvider.notifier).toggle(conv.id);
                    },
                  ),
                  const SizedBox(width: 12),

                  // 头像
                  MoeAvatar(
                    name: conv.displayName,
                    avatarUrl: conv.avatarUrl,
                    characterImage: conv.characterImage,
                    size: 48,
                  ),
                  const SizedBox(width: 12),

                  // 名称和消息数
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          conv.displayName,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: MoeFontWeights.emphasis,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          messageCountAsync.when(
                            data: (count) => '$count 条消息',
                            loading: () => '统计消息中...',
                            error: (_, __) => '消息数加载失败',
                          ),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),

                  // 预览按钮
                  IconButton(
                    icon: const Icon(LucideIcons.eye, size: 20),
                    onPressed: () {
                      Navigator.of(context).push(
                        ParallaxSlidePageRoute(
                          page: ChatPreviewPage(conversation: conv),
                        ),
                      );
                    },
                    tooltip: '预览聊天记录',
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildProgressBar(BuildContext context, ExportProgress progress) {
    final theme = Theme.of(context);

    return SafeArea(
      child: Container(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            MoeG2ClipRRect(
              radius: 4,
              child: LinearProgressIndicator(
                value: progress.progress,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              progress.message ?? '导出中...',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildExportButton(BuildContext context, Set<String> selectedIds) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: MoePrimaryButton(
          onPressed: selectedIds.isEmpty ? null : _startExport,
          label: '导出 ${selectedIds.length} 个角色',
        ),
      ),
    );
  }

  Future<void> _startExport() async {
    if (!mounted || _isExporting) return;
    final selectedIds = ref.read(selectedConversationsProvider);
    if (selectedIds.isEmpty) return;

    setState(() => _isExporting = true);

    try {
      final exporter = ref.read(conversationExporterProvider);
      final options = ref.read(exportOptionsProvider);

      final result = await exporter.exportConversations(
        conversationIds: selectedIds.toList(),
        options: options,
        onProgress: (progress) {
          if (!mounted) return;
          ref.read(exportProgressProvider.notifier).state = progress;
        },
      );

      if (!mounted) return;

      // 导出成功
      ref.read(exportProgressProvider.notifier).state = null;
      setState(() => _isExporting = false);

      // 显示成功提示并分享
      _showExportSuccess(result);
    } catch (e) {
      if (!mounted) return;

      ref.read(exportProgressProvider.notifier).state = null;
      setState(() => _isExporting = false);

      MoeToast.error(context, '导出失败: $e');
    }
  }

  void _showExportSuccess(ExportResult result) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(LucideIcons.checkCircle, color: Colors.green),
            SizedBox(width: 8),
            Text('导出成功'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('文件：${result.fileName}'),
            const SizedBox(height: 4),
            Text('角色数：${result.conversationCount}'),
            Text('消息数：${result.messageCount}'),
            Text('文件大小：${_formatSize(result.sizeBytes)}'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('完成'),
          ),
          FilledButton.icon(
            onPressed: () {
              Navigator.of(context).pop();
              Share.shareXFiles([XFile(result.filePath)]);
            },
            icon: const Icon(LucideIcons.share2, size: 18),
            label: const Text('分享'),
          ),
        ],
      ),
    );
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}
