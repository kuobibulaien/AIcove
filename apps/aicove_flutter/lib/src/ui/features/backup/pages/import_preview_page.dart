import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../../../../features/backup/models/export_format.dart';
import '../../../../features/backup/backup_providers.dart';
import '../../../../features/chat/conversation_providers.dart';
import '../../../shared/effects/smooth_clip.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';

/// 导入预览页面
class ImportPreviewPage extends ConsumerStatefulWidget {
  final File file;
  final ImportPreview preview;

  const ImportPreviewPage({
    super.key,
    required this.file,
    required this.preview,
  });

  @override
  ConsumerState<ImportPreviewPage> createState() => _ImportPreviewPageState();
}

class _ImportPreviewPageState extends ConsumerState<ImportPreviewPage> {
  bool _isImporting = false;

  @override
  void initState() {
    super.initState();
    // 初始化选中所有会话
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(importSelectedConversationsProvider.notifier).selectAll(
            widget.preview.conversations.map((c) => c.id).toList(),
          );
    });
  }

  @override
  Widget build(BuildContext context) {
    final selectedScopes = ref.watch(importScopesProvider);
    final selectedConvIds = ref.watch(importSelectedConversationsProvider);
    final importProgress = ref.watch(importProgressProvider);

    return Scaffold(
      appBar: MoeAppBar(
        title: '导入预览',
        showBackButton: true,
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // 文件信息
                _buildFileInfoCard(context),
                const SizedBox(height: 24),

                // 兼容性警告
                if (!widget.preview.isCompatible) ...[
                  _buildWarningCard(context),
                  const SizedBox(height: 24),
                ],

                // 导入范围选择
                _buildSectionTitle(context, '导入内容'),
                const SizedBox(height: 12),
                _buildScopeSelector(context, selectedScopes),
                const SizedBox(height: 24),

                // 角色列表
                _buildSectionTitle(context, '选择角色'),
                const SizedBox(height: 8),
                _buildSelectAllBar(context, selectedConvIds),
                const SizedBox(height: 8),
                ...widget.preview.conversations.map((conv) {
                  return _buildConversationItem(
                    context,
                    conv,
                    selectedConvIds.contains(conv.id),
                  );
                }),
              ],
            ),
          ),

          // 导入进度或按钮
          if (_isImporting && importProgress != null)
            _buildProgressBar(context, importProgress)
          else
            _buildImportButton(context, selectedConvIds),
        ],
      ),
    );
  }

  Widget _buildFileInfoCard(BuildContext context) {
    final theme = Theme.of(context);
    final preview = widget.preview;

    return MoeSettingsGroup(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: MoeG2Decoration(
                      radius: 10,
                      color: theme.colorScheme.primaryContainer,
                    ),
                    child: Icon(
                      LucideIcons.fileArchive,
                      color: theme.colorScheme.primary,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.file.path.split('/').last.split('\\').last,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: MoeFontWeights.emphasis,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'v${preview.appVersion}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _buildInfoRow(context, '导出时间', _formatDate(preview.exportTime)),
              if (preview.exportDevice != null)
                _buildInfoRow(context, '导出设备', preview.exportDevice!),
              _buildInfoRow(context, '角色数', '${preview.conversations.length}'),
              _buildInfoRow(context, '消息总数', '${preview.totalMessageCount}'),
              if (preview.totalImageCount > 0)
                _buildInfoRow(context, '图片数', '${preview.totalImageCount}'),
              if (preview.totalAudioCount > 0)
                _buildInfoRow(context, '语音数', '${preview.totalAudioCount}'),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildInfoRow(BuildContext context, String label, String value) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
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
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _buildWarningCard(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: MoeG2Decoration(
        radius: 8,
        color: theme.colorScheme.errorContainer,
      ),
      child: Row(
        children: [
          Icon(
            LucideIcons.alertTriangle,
            color: theme.colorScheme.error,
            size: 20,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              widget.preview.incompatibleReason ?? '文件可能不兼容',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(BuildContext context, String title) {
    return Text(
      title,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
            fontWeight: MoeFontWeights.emphasis,
          ),
    );
  }

  Widget _buildScopeSelector(BuildContext context, Set<String> selectedScopes) {
    final availableScopes = widget.preview.includedScopes;

    return MoeSettingsGroup(
      children: [
        if (availableScopes.contains(SyncScope.characterCards))
          _buildScopeItem(
            context,
            SyncScope.characterCards,
            LucideIcons.userCircle,
            selectedScopes.contains(SyncScope.characterCards),
          ),
        if (availableScopes.contains(SyncScope.chatHistory))
          _buildScopeItem(
            context,
            SyncScope.chatHistory,
            LucideIcons.messageSquare,
            selectedScopes.contains(SyncScope.chatHistory),
          ),
        if (availableScopes.contains(SyncScope.characterSettings))
          _buildScopeItem(
            context,
            SyncScope.characterSettings,
            LucideIcons.settings,
            selectedScopes.contains(SyncScope.characterSettings),
          ),
        if (availableScopes.contains(SyncScope.memory))
          _buildScopeItem(
            context,
            SyncScope.memory,
            LucideIcons.brain,
            selectedScopes.contains(SyncScope.memory),
          ),
      ],
    );
  }

  Widget _buildScopeItem(
    BuildContext context,
    String scope,
    IconData icon,
    bool isSelected,
  ) {
    return MoeSettingsRow(
      icon: icon,
      label: SyncScope.getDisplayName(scope),
      trailingType: MoeSettingsRowTrailing.custom,
      trailing: MoeCheckbox(
        value: isSelected,
        onChanged: (value) {
          ref.read(importScopesProvider.notifier).toggle(scope);
        },
      ),
      onTap: () {
        ref.read(importScopesProvider.notifier).toggle(scope);
      },
    );
  }

  Widget _buildSelectAllBar(BuildContext context, Set<String> selectedIds) {
    final allIds = widget.preview.conversations.map((c) => c.id).toList();
    final isAllSelected =
        allIds.isNotEmpty && allIds.every((id) => selectedIds.contains(id));
    final theme = Theme.of(context);

    return Row(
      children: [
        MoeCheckbox(
          value: isAllSelected,
          onChanged: (value) {
            if (value == true) {
              ref.read(importSelectedConversationsProvider.notifier).selectAll(allIds);
            } else {
              ref.read(importSelectedConversationsProvider.notifier).clear();
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
          '已选 ${selectedIds.length}/${allIds.length}',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _buildConversationItem(
    BuildContext context,
    ConversationPreview conv,
    bool isSelected,
  ) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: MoeG2ClipRRect(
        radius: 12,
        child: Material(
          color: theme.cardColor,
          child: InkWell(
            onTap: () {
              ref.read(importSelectedConversationsProvider.notifier).toggle(conv.id);
            },
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  MoeCheckbox(
                    value: isSelected,
                    onChanged: (value) {
                      ref.read(importSelectedConversationsProvider.notifier).toggle(conv.id);
                    },
                  ),
                  const SizedBox(width: 12),
                  CircleAvatar(
                    radius: 20,
                    child: Text(
                      conv.displayName.isNotEmpty ? conv.displayName[0] : '?',
                    ),
                  ),
                  const SizedBox(width: 12),
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
                        const SizedBox(height: 2),
                        Text(
                          '${conv.messageCount} 条消息',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildProgressBar(BuildContext context, ImportProgress progress) {
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
              progress.message ?? '导入中...',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildImportButton(BuildContext context, Set<String> selectedIds) {
    final selectedScopes = ref.watch(importScopesProvider);
    final canImport = selectedIds.isNotEmpty && selectedScopes.isNotEmpty;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: MoePrimaryButton(
          onPressed: canImport ? _startImport : null,
          label: '导入 ${selectedIds.length} 个角色',
        ),
      ),
    );
  }

  Future<void> _startImport() async {
    final selectedIds = ref.read(importSelectedConversationsProvider);
    final selectedScopes = ref.read(importScopesProvider);

    if (selectedIds.isEmpty || selectedScopes.isEmpty) return;

    setState(() => _isImporting = true);

    try {
      final importer = ref.read(conversationImporterProvider);
      final conflictResolutions = ref.read(importConflictResolutionsProvider);

      final result = await importer.import(
        file: widget.file,
        selectedScopes: selectedScopes.toList(),
        selectedConversationIds: selectedIds.toList(),
        conflictResolutions: conflictResolutions,
        onProgress: (progress) {
          ref.read(importProgressProvider.notifier).state = progress;
        },
      );

      if (!mounted) return;

      // 检查是否有冲突需要处理
      if (result.conflicts.isNotEmpty) {
        setState(() => _isImporting = false);
        ref.read(importProgressProvider.notifier).state = null;
        _showConflictDialog(result.conflicts);
        return;
      }

      // 导入成功
      ref.read(importProgressProvider.notifier).state = null;
      setState(() => _isImporting = false);

      // 刷新会话列表
      ref.invalidate(conversationsProvider);

      _showImportSuccess(result);
    } catch (e) {
      if (!mounted) return;

      ref.read(importProgressProvider.notifier).state = null;
      setState(() => _isImporting = false);

      MoeToast.error(context, '导入失败: $e');
    }
  }

  void _showConflictDialog(List<ImportConflict> conflicts) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => _ConflictDialog(
        conflicts: conflicts,
        onResolved: (resolutions) {
          // 保存解决方案并重试
          for (final entry in resolutions.entries) {
            ref
                .read(importConflictResolutionsProvider.notifier)
                .setResolution(entry.key, entry.value);
          }
          _startImport();
        },
      ),
    );
  }

  void _showImportSuccess(ImportResult result) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(LucideIcons.checkCircle, color: Colors.green),
            SizedBox(width: 8),
            Text('导入成功'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('导入角色：${result.conversationIds.length}'),
            Text('导入消息：${result.messagesImported}'),
            if (result.skipped > 0) Text('跳过重复：${result.skipped}'),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () {
              Navigator.of(context).pop();
              // 返回到数据管理页面
              Navigator.of(context).pop();
              Navigator.of(context).pop();
            },
            child: const Text('完成'),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')} '
        '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }
}

/// 冲突解决对话框
class _ConflictDialog extends StatefulWidget {
  final List<ImportConflict> conflicts;
  final void Function(Map<String, ImportConflictResolution>) onResolved;

  const _ConflictDialog({
    required this.conflicts,
    required this.onResolved,
  });

  @override
  State<_ConflictDialog> createState() => _ConflictDialogState();
}

class _ConflictDialogState extends State<_ConflictDialog> {
  late Map<String, ImportConflictResolution> _resolutions;

  @override
  void initState() {
    super.initState();
    _resolutions = {
      for (final c in widget.conflicts) c.id: ImportConflictResolution.createNew,
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: Row(
        children: [
          Icon(
            LucideIcons.alertTriangle,
            color: theme.colorScheme.error,
          ),
          const SizedBox(width: 8),
          const Text('发现重复角色'),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '以下角色已存在于本地，请选择处理方式：',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            ...widget.conflicts.map((conflict) {
              return Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        conflict.name,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: MoeFontWeights.emphasis,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        children: [
                          _buildResolutionChip(
                            context,
                            conflict.id,
                            ImportConflictResolution.createNew,
                            '新建副本',
                          ),
                          _buildResolutionChip(
                            context,
                            conflict.id,
                            ImportConflictResolution.merge,
                            '合并',
                          ),
                          _buildResolutionChip(
                            context,
                            conflict.id,
                            ImportConflictResolution.skip,
                            '跳过',
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            }),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.of(context).pop();
            widget.onResolved(_resolutions);
          },
          child: const Text('继续导入'),
        ),
      ],
    );
  }

  Widget _buildResolutionChip(
    BuildContext context,
    String conflictId,
    ImportConflictResolution resolution,
    String label,
  ) {
    final isSelected = _resolutions[conflictId] == resolution;

    return ChoiceChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (selected) {
        if (selected) {
          setState(() {
            _resolutions[conflictId] = resolution;
          });
        }
      },
    );
  }
}
