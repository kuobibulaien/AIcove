import 'package:flutter/material.dart';

import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/widgets/moe_app_bar.dart';
import '../../../../ui/shared/widgets/list/moe_settings_group.dart';
import '../../../../ui/shared/widgets/list/moe_settings_row.dart';
import '../../../../ui/shared/animations/parallax_slide_page_route.dart';
import '../../settings/pages/log_viewer_page.dart';
import 'ui_gallery_page.dart';
import 'tool_prompts_page.dart';
import 'enhanced_dialogue_page.dart';
import 'network_diagnostic_page.dart';
import 'call_flow_management_page.dart';
import 'message_segmentation_debug_page.dart';
import 'stream_monitor_debug_page.dart';

/// 调试中心 - 整合日志、组件库、工具提示词管理
class DebugCenterPage extends StatelessWidget {
  const DebugCenterPage({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;

    return Scaffold(
      backgroundColor: colors.surface,
      appBar: const MoeAppBar(title: '调试中心', showBackButton: true),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 16),
        children: [
          MoeSettingsGroup(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              MoeSettingsRow(
                icon: Icons.article_outlined,
                label: '日志中心',
                subtitle: 'API 日志、系统日志',
                trailingType: MoeSettingsRowTrailing.chevron,
                onTap: () => Navigator.of(context).push(
                  ParallaxSlidePageRoute(page: const LogViewerPage()),
                ),
              ),
              MoeSettingsRow(
                icon: Icons.widgets_outlined,
                label: 'UI 组件库',
                subtitle: '查看所有公共组件',
                trailingType: MoeSettingsRowTrailing.chevron,
                onTap: () => Navigator.of(context).push(
                  ParallaxSlidePageRoute(page: const UiGalleryPage()),
                ),
              ),
              MoeSettingsRow(
                icon: Icons.code_outlined,
                label: '工具提示词管理',
                subtitle: '查看和编辑插件注入 AI 的提示词',
                trailingType: MoeSettingsRowTrailing.chevron,
                onTap: () => Navigator.of(context).push(
                  ParallaxSlidePageRoute(page: const ToolPromptsPage()),
                ),
              ),
              MoeSettingsRow(
                icon: Icons.auto_awesome_outlined,
                label: '增强对话',
                subtitle: '配置增强生成（系统提示词 / 第一条用户消息 / 最近轮数）',
                trailingType: MoeSettingsRowTrailing.chevron,
                onTap: () => Navigator.of(context).push(
                  ParallaxSlidePageRoute(page: const EnhancedDialoguePage()),
                ),
              ),
              MoeSettingsRow(
                icon: Icons.route_outlined,
                label: '调用超时管理',
                subtitle: '配置模型与工具超时，生图路径切换已移到绘图设置',
                trailingType: MoeSettingsRowTrailing.chevron,
                onTap: () => Navigator.of(context).push(
                  ParallaxSlidePageRoute(page: const CallFlowManagementPage()),
                ),
              ),
              MoeSettingsRow(
                icon: Icons.segment_outlined,
                label: '消息分段',
                subtitle: '配置流式分段逐条展示延迟',
                trailingType: MoeSettingsRowTrailing.chevron,
                onTap: () => Navigator.of(context).push(
                  ParallaxSlidePageRoute(
                      page: const MessageSegmentationDebugPage()),
                ),
              ),
              MoeSettingsRow(
                icon: Icons.monitor_heart_outlined,
                label: '流式监控',
                subtitle: '查看流式尝试/成功/回退统计',
                trailingType: MoeSettingsRowTrailing.chevron,
                onTap: () => Navigator.of(context).push(
                  ParallaxSlidePageRoute(page: const StreamMonitorDebugPage()),
                ),
              ),
              MoeSettingsRow(
                icon: Icons.network_check_outlined,
                label: '网络诊断',
                subtitle: '测试 URL 连通性（内置简易 curl）',
                trailingType: MoeSettingsRowTrailing.chevron,
                onTap: () => Navigator.of(context).push(
                  ParallaxSlidePageRoute(page: const NetworkDiagnosticPage()),
                ),
                showDivider: false,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
