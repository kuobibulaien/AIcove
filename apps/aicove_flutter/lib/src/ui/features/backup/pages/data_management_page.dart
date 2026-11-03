import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/account/providers/account_provider.dart';
import '../../../../features/sync/providers/cloud_sync_provider.dart';
import '../../../shared/animations/parallax_slide_page_route.dart';
import '../../../shared/widgets/index.dart';
import '../../settings/pages/account_page.dart';
import '../../settings/pages/lan_sync_page.dart';
import 'export_scope_page.dart';
import 'import_file_page.dart';

/// 同步与备份：局域网同步（首选）、自建云同步与离线导入导出的统一入口。
class DataManagementPage extends ConsumerWidget {
  const DataManagementPage({super.key});

  static const title = '同步与备份';

  void _open(BuildContext context, Widget page) =>
      Navigator.of(context).push(ParallaxSlidePageRoute(page: page));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connection = ref.watch(accountProvider).connection;
    final cloudEnabled = ref.watch(
      cloudSyncProvider.select((state) => state.enabled),
    );
    final cloudStatus = connection?.hasSession ?? false
        ? (cloudEnabled
              ? '已开启 · ${connection!.user.username}'
              : '默认关闭 · 已登录 ${connection!.user.username}')
        : '默认关闭 · 需自备服务器，支持自定义或 AI 辅助部署';

    return MoePageScaffold(
      extendBodyBehindAppBar: true,
      appBar: const MoeAppBar(title: title, showBackButton: true),
      body: Builder(
        builder: (context) => ListView(
          padding: moeUnderBarPadding(
            context,
            const EdgeInsets.symmetric(vertical: 16),
          ),
          children: [
            MoeSettingsGroup(
              title: '同步',
              margin: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                MoeSettingsRow(
                  icon: Icons.devices_outlined,
                  label: '局域网同步',
                  subtitle: '首选 · 同一 Wi-Fi 或热点下扫码直连，无需服务器',
                  trailingType: MoeSettingsRowTrailing.chevron,
                  onTap: () => _open(context, const LanSyncPage()),
                ),
                MoeSettingsRow(
                  icon: Icons.cloud_sync_outlined,
                  label: '云同步',
                  subtitle: cloudStatus,
                  trailingType: MoeSettingsRowTrailing.chevron,
                  showDivider: false,
                  onTap: () => _open(context, const AccountPage()),
                ),
              ],
            ),
            const SizedBox(height: 24),
            MoeSettingsGroup(
              title: '离线备份',
              margin: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                MoeSettingsRow(
                  icon: Icons.upload_outlined,
                  label: '导出数据',
                  subtitle: '将角色和聊天记录打包为 .zip 文件，可设密码',
                  trailingType: MoeSettingsRowTrailing.chevron,
                  onTap: () => _open(context, const ExportScopePage()),
                ),
                MoeSettingsRow(
                  icon: Icons.download_outlined,
                  label: '导入数据',
                  subtitle: '从 .zip 备份还原，可合并或新建角色',
                  trailingType: MoeSettingsRowTrailing.chevron,
                  showDivider: false,
                  onTap: () => _open(context, const ImportFilePage()),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
