import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/account/providers/account_provider.dart';
import '../../../shared/animations/parallax_slide_page_route.dart';
import '../../../shared/widgets/index.dart';
import '../../settings/pages/account_page.dart';
import '../../settings/pages/lan_sync_page.dart';
import 'export_scope_page.dart';
import 'import_file_page.dart';

/// 同步与备份：云同步账号、局域网同步与离线导入导出的统一入口。
class DataManagementPage extends ConsumerWidget {
  const DataManagementPage({super.key});

  static const title = '同步与备份';

  void _open(BuildContext context, Widget page) =>
      Navigator.of(context).push(ParallaxSlidePageRoute(page: page));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connection = ref.watch(accountProvider).connection;
    final cloudStatus = connection?.hasSession ?? false
        ? '已登录：${connection!.user.username}'
        : '登录账号后在多台设备间同步';

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
                  icon: Icons.cloud_sync_outlined,
                  label: '云同步',
                  subtitle: cloudStatus,
                  trailingType: MoeSettingsRowTrailing.chevron,
                  onTap: () => _open(context, const AccountPage()),
                ),
                MoeSettingsRow(
                  icon: Icons.devices_outlined,
                  label: '局域网同步',
                  subtitle: '同一网络内设备扫码配对直连',
                  trailingType: MoeSettingsRowTrailing.chevron,
                  showDivider: false,
                  onTap: () => _open(context, const LanSyncPage()),
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
                  subtitle: '将角色和聊天记录打包为 .aicove 文件',
                  trailingType: MoeSettingsRowTrailing.chevron,
                  onTap: () => _open(context, const ExportScopePage()),
                ),
                MoeSettingsRow(
                  icon: Icons.download_outlined,
                  label: '导入数据',
                  subtitle: '从 .aicove 文件还原，可合并或新建角色',
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
