import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../../../../core/database/database_provider.dart';
import '../../../../features/memory/models/memory_entity.dart';
import '../../../shared/effects/smooth_clip.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';

/// 回收站记忆列表 Provider
final trashMemoriesProvider = FutureProvider.autoDispose<List<MemoryEntity>>((ref) async {
  final repository = ref.watch(memoryRepositoryProvider);
  return await repository.getTrash();
});

/// 记忆回收站页面
/// 展示已删除的记忆，支持预览和恢复功能
class MemoryTrashPage extends ConsumerWidget {
  const MemoryTrashPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trashAsync = ref.watch(trashMemoriesProvider);
    final colors = context.moeColors;

    return Scaffold(
      appBar: MoeAppBar(
        title: '记忆回收站',
        showBackButton: true,
      ),
      body: trashAsync.when(
        loading: () => const Center(child: MoeLoadingIndicator()),
        error: (e, _) => Center(
          child: MoeEmptyState(
            icon: LucideIcons.alertCircle,
            title: '加载失败',
            description: e.toString(),
          ),
        ),
        data: (memories) {
          if (memories.isEmpty) {
            return Center(
              child: MoeEmptyState(
                icon: LucideIcons.trash2,
                title: '回收站为空',
                description: '被删除的记忆会在这里保留 7 天',
              ),
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: memories.length,
            separatorBuilder: (_, __) => Divider(
              height: 0.5,
              thickness: 0.5,
              color: colors.borderLight,
            ),
            itemBuilder: (context, index) {
              final memory = memories[index];
              return _MemoryTrashItem(
                memory: memory,
                onRestore: () => _restoreMemory(context, ref, memory),
                onPreview: () => _showPreviewDialog(context, memory),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _restoreMemory(BuildContext context, WidgetRef ref, MemoryEntity memory) async {
    final repository = ref.read(memoryRepositoryProvider);
    
    try {
      await repository.restore(memory.id);
      ref.invalidate(trashMemoriesProvider);
      if (context.mounted) {
        MoeToast.success(context, '记忆已恢复');
      }
    } catch (e) {
      if (context.mounted) {
        MoeToast.error(context, '恢复失败: $e');
      }
    }
  }

  void _showPreviewDialog(BuildContext context, MemoryEntity memory) {
    final theme = Theme.of(context);
    final daysRemaining = memory.purgeAt != null
        ? memory.purgeAt!.difference(DateTime.now()).inDays
        : 0;

    showMeoTalkDialog(
      context: context,
      title: '记忆详情',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: MoeG2Decoration(
              radius: 8,
              color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
            ),
            child: Text(
              memory.content,
              style: theme.textTheme.bodyMedium,
            ),
          ),
          const SizedBox(height: 16),
          _buildInfoRow(context, '创建时间', _formatDateTime(memory.createdAt)),
          const SizedBox(height: 8),
          _buildInfoRow(context, '删除时间', _formatDateTime(memory.deletedAt)),
          const SizedBox(height: 8),
          _buildInfoRow(
            context,
            '剩余时间',
            daysRemaining > 0 ? '$daysRemaining 天后彻底删除' : '即将删除',
            valueColor: daysRemaining <= 1 ? theme.colorScheme.error : null,
          ),
          const SizedBox(height: 8),
          _buildInfoRow(context, '使用次数', '${memory.useCount} 次'),
          const SizedBox(height: 8),
          _buildInfoRow(context, '重要性', memory.importance.toStringAsFixed(2)),
        ],
      ),
      cancelText: '关闭',
      confirmText: null,
    );
  }

  Widget _buildInfoRow(BuildContext context, String label, String value, {Color? valueColor}) {
    final theme = Theme.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        Text(
          value,
          style: theme.textTheme.bodySmall?.copyWith(
            fontWeight: FontWeight.w500,
            color: valueColor,
          ),
        ),
      ],
    );
  }

  String _formatDateTime(DateTime? dt) {
    if (dt == null) return '-';
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}

/// 回收站记忆项
class _MemoryTrashItem extends StatelessWidget {
  final MemoryEntity memory;
  final VoidCallback onRestore;
  final VoidCallback onPreview;

  const _MemoryTrashItem({
    required this.memory,
    required this.onRestore,
    required this.onPreview,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final daysRemaining = memory.purgeAt != null
        ? memory.purgeAt!.difference(DateTime.now()).inDays
        : 0;

    return MoeG2ClipRRect(
      radius: 8,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPreview,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: MoeG2Decoration(
                    radius: 10,
                    color: theme.colorScheme.errorContainer.withValues(alpha: 0.3),
                  ),
                  child: Icon(
                    LucideIcons.brain,
                    color: theme.colorScheme.error,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        memory.content,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        daysRemaining > 0
                            ? '$daysRemaining 天后彻底删除'
                            : '即将删除',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: daysRemaining <= 1
                              ? theme.colorScheme.error
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                MoeSecondaryButton(
                  label: '恢复',
                  icon: LucideIcons.rotateCcw,
                  size: MoeSecondaryButtonSize.sm,
                  onPressed: onRestore,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
