import 'package:flutter/material.dart';

import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/widgets/moe_app_bar.dart';
import '../../../../ui/shared/widgets/list/moe_settings_group.dart';
import '../../../../ui/shared/widgets/list/moe_settings_row.dart';
import '../../../../ui/shared/animations/parallax_slide_page_route.dart';
import '../../settings/pages/log_viewer_page.dart';
import 'ui_gallery_page.dart';
import 'tool_prompts_page.dart';

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
                showDivider: false,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
