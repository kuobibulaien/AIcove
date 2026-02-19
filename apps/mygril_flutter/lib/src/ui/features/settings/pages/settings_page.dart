// 设置页面 - 重构版
//
// 分组结构（无标题，组间用深色分割线）：
// 1. 渠道列表
// 2. 界面设置
// 3. 聊天插件
//
// 更新记录：
// - 2025-12-02: 重构分组结构，移除插件设置，TTS独立为语音设置
// - 2025-12-06: 使用 MoeAppBar 替换原有 AppBar 样式
// - 2026-01-15: 整合聊天相关设置到"聊天插件"页面
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/widgets/moe_app_bar.dart';
import '../../../../ui/shared/animations/parallax_slide_page_route.dart';
import '../../../../features/settings/app_settings.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/model_list_page.dart';

import 'chat_plugin_settings_page.dart';
import 'ui_settings_page.dart';
import '../../backup/pages/data_management_page.dart';

/// 设置页面 - 带AppBar 的完整页面（小屏使用）
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;

    return Scaffold(
      appBar: const MoeAppBar(title: '设置'),
      backgroundColor: colors.surface,
      body: const SettingsContent(),
    );
  }
}

/// 设置内容 - 可复用的设置UI组件（无 AppBar，可嵌入其他布局）
class SettingsContent extends ConsumerStatefulWidget {
  const SettingsContent({super.key});

  @override
  ConsumerState<SettingsContent> createState() => _SettingsContentState();
}

class _SettingsContentState extends ConsumerState<SettingsContent> {
  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(appSettingsProvider);
    final colors = context.moeColors;

    return settingsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('加载设置失败: $e')),
      data: (settings) {
        return ListView(
          children: [
            // ============ 渠道列表 ============
            _buildSettingItem(
              context,
              icon: Icons.list_alt,
              title: '渠道列表',
              subtitle: '管理所有类型的渠道商',
              onTap: () => _navigateTo(context, const ModelListPage()),
            ),

            // ============ 组间分割 ============
            _buildGroupDivider(colors),

            // ============ 界面设置 ============
            _buildSettingItem(
              context,
              icon: Icons.palette_outlined,
              title: '界面设置',
              subtitle: '字体、暗色模式',
              onTap: () => _navigateTo(context, const UiSettingsPage()),
            ),

            // ============ 组间分割 ============
            _buildGroupDivider(colors),

            // ============ 聊天插件 ============
            _buildSettingItem(
              context,
              icon: Icons.extension_outlined,
              title: '聊天插件',
              subtitle: '记忆、语音、表情包等',
              onTap: () => _navigateTo(context, const ChatPluginSettingsPage()),
            ),

            // ============ 组间分割 ============
            _buildGroupDivider(colors),

            // ============ 数据管理 ============
            _buildSettingItem(
              context,
              icon: Icons.cloud_sync_outlined,
              title: '数据管理',
              subtitle: '备份、导入导出、云同步',
              onTap: () => _navigateTo(context, const DataManagementPage()),
            ),

            const SizedBox(height: 24),
          ],
        );
      },
    );
  }

  /// 构建设置项
  Widget _buildSettingItem(
    BuildContext context, {
    required IconData icon,
    required String title,
    String? subtitle,
    required VoidCallback onTap,
  }) {
    final colors = context.moeColors;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      minLeadingWidth: 24,
      horizontalTitleGap: 12,
      leading: Icon(icon, color: colors.text, size: 24),
      title: Text(title, style: TextStyle(fontSize: 15, fontWeight: MoeFontWeights.emphasis, color: colors.text)),
      subtitle: subtitle != null 
          ? Text(subtitle, style: TextStyle(fontSize: 13, color: colors.muted)) 
          : null,
      trailing: Icon(Icons.chevron_right, color: colors.muted),
      onTap: onTap,
    );
  }

  /// 构建分割线（与联系人卡片一致的全宽分割线）
  Widget _buildGroupDivider(MoeColors colors) {
    return Divider(
      height: borderWidth,
      thickness: borderWidth,
      color: colors.borderLight,
    );
  }

  /// 导航到子页面（视差滑动动画）
  void _navigateTo(BuildContext context, Widget page) {
    Navigator.of(context).push(
      ParallaxSlidePageRoute(page: page),
    );
  }
}
