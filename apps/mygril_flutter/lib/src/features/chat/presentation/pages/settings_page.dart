// 设置页面 - 重构版
//
// 分组结构（无标题，组间用深色分割线）：
// 1. 模型列表、记忆库
// 2. 自然回复、主动关怀
// 3. 语音设置、绘图设置
// 4. 界面设置
//
// 更新记录：
// - 2025-12-02: 重构分组结构，移除插件设置，TTS独立为语音设置
// - 2025-12-06: 使用 MoeAppBar 替换原有 AppBar 样式
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/tokens.dart';
import '../../../../core/widgets/moe_app_bar.dart';
import '../../../../core/widgets/moe_toast.dart';
import '../../../../core/widgets/parallax_slide_page_route.dart';
import '../../../settings/app_settings.dart';
import 'package:mygril_flutter/src/features/chat/presentation/pages/model_list_page.dart';

import 'auto_reply_settings_page.dart';
import 'memory_plugin_detail_page.dart';
import 'message_format_settings_page.dart';
import 'ui_settings_page.dart';
import 'tts_plugin_detail_page.dart';

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
            // ============ 第一组：模型列表、记忆库 ============
            _buildSettingItem(
              context,
              icon: Icons.list_alt,
              title: '模型列表',
              onTap: () => _navigateTo(context, const ModelListPage()),
            ),
            Divider(height: 0, thickness: borderWidth, color: colors.divider),
            _buildSettingItem(
              context,
              icon: Icons.psychology_outlined,
              title: '记忆库',
              subtitle: '长期记忆设置',
              onTap: () => _navigateTo(context, const MemoryPluginDetailPage()),
            ),

            // ============ 组间分割 ============
            _buildGroupDivider(colors),

            // ============ 第二组：自然回复、主动关怀 ============
            _buildSettingItem(
              context,
              icon: Icons.chat_bubble_outline,
              title: '自然回复',
              subtitle: '模拟真人分段、表情包',
              onTap: () => _navigateTo(context, const MessageFormatSettingsPage()),
            ),
            Divider(height: 0, thickness: borderWidth, color: colors.divider),
            _buildSettingItem(
              context,
              icon: Icons.favorite_outline,
              title: '主动关怀',
              subtitle: '主动回复触发器',
              onTap: () => _navigateTo(context, const AutoReplySettingsPage()),
            ),

            // ============ 组间分割 ============
            _buildGroupDivider(colors),

            // ============ 第三组：语音设置、绘图设置 ============
            _buildSettingItem(
              context,
              icon: Icons.record_voice_over_outlined,
              title: '语音设置',
              subtitle: '音色、朗读',
              onTap: () => _navigateTo(context, const TtsPluginDetailPage()),
            ),
            Divider(height: 0, thickness: borderWidth, color: colors.divider),
            _buildSettingItem(
              context,
              icon: Icons.brush_outlined,
              title: '绘图设置',
              subtitle: '生图模型',
              onTap: () => _showPlaceholder(context, '绘图设置'),
            ),

            // ============ 组间分割 ============
            _buildGroupDivider(colors),

            // ============ 第四组：界面设置 ============
            _buildSettingItem(
              context,
              icon: Icons.palette_outlined,
              title: '界面设置',
              subtitle: '字体、暗色模式',
              onTap: () => _navigateTo(context, const UiSettingsPage()),
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
      minLeadingWidth: 48,
      leading: Icon(icon, color: colors.text, size: 24),
      title: Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: colors.text)),
      subtitle: subtitle != null 
          ? Text(subtitle, style: TextStyle(fontSize: 13, color: colors.muted)) 
          : null,
      trailing: Icon(Icons.chevron_right, color: colors.muted),
      onTap: onTap,
    );
  }

  /// 构建组间分割线（更粗更深）
  Widget _buildGroupDivider(MoeColors colors) {
    return Container(
      height: 8,
      color: colors.surfaceAlt,
    );
  }

  /// 导航到子页面（视差滑动动画）
  void _navigateTo(BuildContext context, Widget page) {
    Navigator.of(context).push(
      ParallaxSlidePageRoute(page: page),
    );
  }

  /// 显示占位提示
  void _showPlaceholder(BuildContext context, String feature) {
    MoeToast.brief(context, '$feature 功能开发中');
  }
}
