import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/plugins/mcp/mcp_connector.dart';
import '../../../../features/plugins/mcp/mcp_connector_providers.dart';
import '../../../../ui/shared/animations/parallax_slide_page_route.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/theme/tokens.dart';
import 'mcp_connector_detail_page.dart';

/// MCP 连接器列表：接入用户自己的远程 MCP 服务，为角色提供外部工具。
class McpConnectorsPage extends ConsumerWidget {
  const McpConnectorsPage({super.key});

  static const title = 'MCP 连接器';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.moeColors;
    final connectors = ref.watch(mcpConnectorsConfigProvider).connectors;

    return MoePageScaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: colors.surface,
      appBar: const MoeAppBar(title: title, showBackButton: true),
      body: MoeSettingsContent(
        child: Builder(
          builder: (context) => ListView(
            padding: moeUnderBarPadding(
              context,
              MoeSettingsLayout.verticalListPadding,
            ),
            children: [
              MoeSettingsGroup(
                title: '连接器',
                children: [
                  for (final connector in connectors)
                    MoeSettingsRow(
                      key: ValueKey('mcp-connector-${connector.id}'),
                      icon: Icons.hub_outlined,
                      label: connector.displayName,
                      labelColor: connector.isUsable ? null : colors.muted,
                      subtitle: connector.url.trim().isEmpty
                          ? null
                          : connector.url.trim(),
                      trailingType: MoeSettingsRowTrailing.text,
                      detailText: _status(connector),
                      onTap: () => _open(context, connector.id),
                    ),
                  MoeSettingsRow(
                    key: const ValueKey('mcp-connector-add'),
                    icon: Icons.add,
                    iconColor: colors.primary,
                    label: '添加连接器',
                    labelColor: colors.primary,
                    trailingType: MoeSettingsRowTrailing.none,
                    showDivider: false,
                    onTap: () => _add(context, ref),
                  ),
                ],
              ),
              const SizedBox(height: MoeSettingsLayout.sectionGap),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  '添加后需在角色的「管理开启的插件」里单独开启。',
                  style: TextStyle(
                    color: colors.textSecondary,
                    fontSize: 13,
                    height: 1.5,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _status(McpConnector connector) {
    if (!connector.enabled) return '已停用';
    if (!connector.hasValidUrl) return '未填写地址';
    if (connector.tools.isEmpty) return '尚未连接';
    return '${connector.activeTools.length} 个工具';
  }

  static void _open(BuildContext context, String id) {
    Navigator.of(context).push(
      ParallaxSlidePageRoute(page: McpConnectorDetailPage(connectorId: id)),
    );
  }

  static Future<void> _add(BuildContext context, WidgetRef ref) async {
    final connector = McpConnector.create();
    try {
      await ref
          .read(mcpConnectorsConfigProvider.notifier)
          .saveConnector(connector);
    } catch (e) {
      if (context.mounted) MoeToast.error(context, '$e');
      return;
    }
    if (context.mounted) _open(context, connector.id);
  }
}
