import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../../../../features/backup/models/export_format.dart';
import '../../../shared/animations/parallax_slide_page_route.dart';
import '../../../shared/effects/smooth_clip.dart';
import '../../../shared/widgets/index.dart';
import 'export_scope_page.dart';
import 'import_file_page.dart';
import 'memory_trash_page.dart';

/// 数据管理主页
/// 包含云同步 Scope 设置和离线导入导出入口
class DataManagementPage extends ConsumerWidget {
  const DataManagementPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: MoeAppBar(
        title: '数据管理',
        showBackButton: true,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 离线导入导出区域
          _buildSectionTitle(context, '离线备份'),
          const SizedBox(height: 12),
          _buildExportCard(context),
          const SizedBox(height: 12),
          _buildImportCard(context),

          const SizedBox(height: 32),

          // 云同步服务器设置
          _buildSectionTitle(context, '云同步服务'),
          const SizedBox(height: 8),
          Text(
            '配置云同步服务器（默认离线模式）',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          _buildCloudServerSettings(context, ref),

          const SizedBox(height: 24),

          // 云同步范围
          _buildSectionTitle(context, '同步范围'),
          const SizedBox(height: 8),
          Text(
            '选择哪些数据参与云同步',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          _buildSyncScopeSettings(context, ref),

          const SizedBox(height: 32),

          // 说明
          _buildHelpSection(context),

          const SizedBox(height: 32),

          // 回收站入口
          _buildSectionTitle(context, '数据清理'),
          const SizedBox(height: 12),
          _buildTrashCard(context),
        ],
      ),
    );
  }

  Widget _buildTrashCard(BuildContext context) {
    final theme = Theme.of(context);

    return MoeSettingsGroup(
      margin: EdgeInsets.zero,
      children: [
        MoeListTile(
          leading: Container(
            width: 40,
            height: 40,
            decoration: MoeG2Decoration(
              radius: 10,
              color: theme.colorScheme.errorContainer.withValues(alpha: 0.3),
            ),
            child: Icon(
              LucideIcons.trash2,
              color: theme.colorScheme.error,
              size: 20,
            ),
          ),
          title: const Text('记忆回收站'),
          subtitle: const Text('查看和恢复已删除的记忆'),
          trailing: const Icon(LucideIcons.chevronRight, size: 20),
          onTap: () {
            Navigator.of(context).push(
              ParallaxSlidePageRoute(
                page: const MemoryTrashPage(),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildSectionTitle(BuildContext context, String title) {
    return Text(
      title,
      style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
    );
  }

  Widget _buildExportCard(BuildContext context) {
    final theme = Theme.of(context);

    return MoeSettingsGroup(
      margin: EdgeInsets.zero,
      children: [
        MoeListTile(
          leading: Container(
            width: 40,
            height: 40,
            decoration: MoeG2Decoration(
              radius: 10,
              color: theme.colorScheme.primaryContainer,
            ),
            child: Icon(
              LucideIcons.upload,
              color: theme.colorScheme.primary,
              size: 20,
            ),
          ),
          title: const Text('导出数据'),
          subtitle: const Text('将角色和聊天记录打包为文件'),
          trailing: const Icon(LucideIcons.chevronRight, size: 20),
          onTap: () {
            Navigator.of(context).push(
              ParallaxSlidePageRoute(
                page: const ExportScopePage(),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildImportCard(BuildContext context) {
    final theme = Theme.of(context);

    return MoeSettingsGroup(
      margin: EdgeInsets.zero,
      children: [
        MoeListTile(
          leading: Container(
            width: 40,
            height: 40,
            decoration: MoeG2Decoration(
              radius: 10,
              color: theme.colorScheme.secondaryContainer,
            ),
            child: Icon(
              LucideIcons.download,
              color: theme.colorScheme.secondary,
              size: 20,
            ),
          ),
          title: const Text('导入数据'),
          subtitle: const Text('从 .mygril 文件还原'),
          trailing: const Icon(LucideIcons.chevronRight, size: 20),
          onTap: () {
            Navigator.of(context).push(
              ParallaxSlidePageRoute(
                page: const ImportFilePage(),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildCloudServerSettings(BuildContext context, WidgetRef ref) {
    // TODO: 从数据库读取当前服务器配置
    const bool isOfflineMode = true;
    const String? customServerUrl = null;

    return MoeSettingsGroup(
      margin: EdgeInsets.zero,
      children: [
        // 离线模式开关
        MoeSettingsRow(
          icon: LucideIcons.wifiOff,
          label: '离线模式',
          subtitle: '不使用云同步，仅本地存储',
          trailingType: MoeSettingsRowTrailing.switchControl,
          switchValue: isOfflineMode,
          onSwitchChanged: (value) {
            // TODO: 保存离线模式设置
            MoeToast.show(context, '功能开发中');
          },
        ),
        // 自定义服务器
        MoeSettingsRow(
          icon: LucideIcons.server,
          label: '自定义服务器',
          subtitle: customServerUrl ?? '未配置',
          trailingType: MoeSettingsRowTrailing.chevron,
          enabled: !isOfflineMode,
          onTap: () {
            _showServerConfigDialog(context, ref);
          },
        ),
      ],
    );
  }

  void _showServerConfigDialog(BuildContext context, WidgetRef ref) {
    final controller = TextEditingController();
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('自定义云服务器'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '输入您的云同步服务器地址',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                hintText: 'https://your-server.com/api',
                border: OutlineInputBorder(),
                prefixIcon: Icon(LucideIcons.link),
              ),
              keyboardType: TextInputType.url,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              // TODO: 验证并保存服务器地址
              Navigator.of(context).pop();
              MoeToast.show(context, '功能开发中');
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  Widget _buildSyncScopeSettings(BuildContext context, WidgetRef ref) {
    final scopeItems = [
      (SyncScope.chatHistory, LucideIcons.messageSquare),
      (SyncScope.characterCards, LucideIcons.userCircle),
      (SyncScope.characterSettings, LucideIcons.settings),
      (SyncScope.providersConfig, LucideIcons.server),
      (SyncScope.providersKeys, LucideIcons.key),
      (SyncScope.memory, LucideIcons.brain),
    ];

    return MoeSettingsGroup(
      margin: EdgeInsets.zero,
      children: scopeItems.map((item) {
        final scope = item.$1;
        final icon = item.$2;
        // TODO: 从数据库读取当前启用的 scope
        final isEnabled = scope == SyncScope.chatHistory ||
            scope == SyncScope.characterCards;

        return MoeSettingsRow(
          icon: icon,
          label: SyncScope.getDisplayName(scope),
          subtitle: SyncScope.getDescription(scope),
          trailingType: MoeSettingsRowTrailing.switchControl,
          switchValue: isEnabled,
          onSwitchChanged: (value) {
            // TODO: 保存 scope 设置到数据库
            MoeToast.show(context, '功能开发中');
          },
        );
      }).toList(),
    );
  }

  Widget _buildHelpSection(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: MoeG2Decoration(
        radius: 12,
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                LucideIcons.info,
                size: 16,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Text(
                '说明',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '• 导出的 .mygril 文件可以传输到其他设备\n'
            '• 导入时可以选择合并或新建角色\n'
            '• 云同步需要登录账号才能使用',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}
