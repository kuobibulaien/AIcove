import 'package:aicove_flutter/src/ui/shared/widgets/moe_page_scaffold.dart';
import 'package:flutter/material.dart';

import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/widgets/moe_app_bar.dart';
import '../../../../ui/shared/widgets/list/moe_settings_group.dart';
import '../../../../ui/shared/widgets/list/moe_settings_row.dart';
import '../../../../ui/shared/animations/parallax_slide_page_route.dart';
import '../../../../ui/shared/widgets/moe_scroll_edge.dart';
import 'diagnostic_access_page.dart';
import 'network_diagnostic_page.dart';
import 'stream_monitor_debug_page.dart';
import 'ui_gallery_page.dart';

/// 调试中心「其他」：收纳低频的诊断与开发者工具
class DebugOtherToolsPage extends StatelessWidget {
  const DebugOtherToolsPage({super.key});

  static const title = '其他';

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;

    return MoePageScaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: colors.surface,
      appBar: const MoeAppBar(title: title, showBackButton: true),
      body: Builder(
        builder: (context) => ListView(
          padding: moeUnderBarPadding(
            context,
            const EdgeInsets.symmetric(vertical: 16),
          ),
          children: [
            MoeSettingsGroup(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                MoeSettingsRow(
                  icon: Icons.download_outlined,
                  label: '诊断导出与电脑读取',
                  subtitle: 'Release 可用，一键导出或连接 Agent',
                  trailingType: MoeSettingsRowTrailing.chevron,
                  onTap: () => Navigator.of(context).push(
                    ParallaxSlidePageRoute(page: const DiagnosticAccessPage()),
                  ),
                ),
                MoeSettingsRow(
                  icon: Icons.widgets_outlined,
                  label: 'UI 组件库',
                  subtitle: '查看所有公共组件',
                  trailingType: MoeSettingsRowTrailing.chevron,
                  onTap: () => Navigator.of(
                    context,
                  ).push(ParallaxSlidePageRoute(page: const UiGalleryPage())),
                ),
                MoeSettingsRow(
                  icon: Icons.monitor_heart_outlined,
                  label: '流式监控',
                  subtitle: '查看流式尝试/成功/回退统计',
                  trailingType: MoeSettingsRowTrailing.chevron,
                  onTap: () => Navigator.of(context).push(
                    ParallaxSlidePageRoute(
                      page: const StreamMonitorDebugPage(),
                    ),
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
      ),
    );
  }
}
