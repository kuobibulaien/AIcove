import 'package:aicove_flutter/src/ui/shared/widgets/moe_page_scaffold.dart';
import 'package:flutter/material.dart';

import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/widgets/moe_app_bar.dart';
import '../../../../ui/shared/widgets/list/moe_settings_group.dart';
import '../../../../ui/shared/widgets/list/moe_settings_row.dart';
import '../../../../ui/shared/animations/parallax_slide_page_route.dart';
import '../../settings/pages/log_viewer_page.dart';
import 'contact_context_page.dart';
import '../../backup/pages/data_management_page.dart';
import 'enhanced_dialogue_page.dart';
import 'call_flow_management_page.dart';
import 'message_segmentation_debug_page.dart';
import 'debug_other_tools_page.dart';
import '../../../../ui/shared/widgets/moe_scroll_edge.dart';

/// 调试中心 - 整合日志、联系人上下文、同步备份，低频工具收进「其他」
class DebugCenterPage extends StatelessWidget {
  const DebugCenterPage({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;

    return MoePageScaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: colors.surface,
      appBar: const MoeAppBar(title: '调试中心', showBackButton: true),
      body: Builder(
        builder: (context) => ListView(
          padding: moeUnderBarPadding(
            context,
            EdgeInsets.symmetric(vertical: 16),
          ),
          children: [
            MoeSettingsGroup(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                MoeSettingsRow(
                  icon: Icons.article_outlined,
                  label: '日志中心',
                  subtitle: '前端响应、模型对话、应用异常',
                  trailingType: MoeSettingsRowTrailing.chevron,
                  onTap: () => Navigator.of(
                    context,
                  ).push(ParallaxSlidePageRoute(page: const LogViewerPage())),
                ),
                MoeSettingsRow(
                  icon: Icons.account_tree_outlined,
                  label: ContactContextListPage.title,
                  subtitle: '查看某个联系人发给模型的完整上下文',
                  trailingType: MoeSettingsRowTrailing.chevron,
                  onTap: () => Navigator.of(context).push(
                    ParallaxSlidePageRoute(
                      page: const ContactContextListPage(),
                    ),
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
                    ParallaxSlidePageRoute(
                      page: const CallFlowManagementPage(),
                    ),
                  ),
                ),
                MoeSettingsRow(
                  icon: Icons.segment_outlined,
                  label: '消息分段',
                  subtitle: '配置流式分段逐条展示延迟',
                  trailingType: MoeSettingsRowTrailing.chevron,
                  onTap: () => Navigator.of(context).push(
                    ParallaxSlidePageRoute(
                      page: const MessageSegmentationDebugPage(),
                    ),
                  ),
                ),
                MoeSettingsRow(
                  icon: Icons.cloud_sync_outlined,
                  label: DataManagementPage.title,
                  subtitle: '云同步账号、局域网同步、离线导入导出',
                  trailingType: MoeSettingsRowTrailing.chevron,
                  onTap: () => Navigator.of(context).push(
                    ParallaxSlidePageRoute(page: const DataManagementPage()),
                  ),
                ),
                MoeSettingsRow(
                  icon: Icons.more_horiz,
                  label: DebugOtherToolsPage.title,
                  subtitle: '诊断导出、UI 组件库、流式监控、网络诊断',
                  trailingType: MoeSettingsRowTrailing.chevron,
                  onTap: () => Navigator.of(context).push(
                    ParallaxSlidePageRoute(page: const DebugOtherToolsPage()),
                  ),
                  showDivider: false,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
