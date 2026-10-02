import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../features/settings/app_settings.dart';
import '../../../shared/widgets/moe_avatar.dart';
import '../../../shared/widgets/moe_scroll_edge.dart';
import 'profile_page.dart';
import 'account_page.dart';
import '../../../shared/widgets/moe_floating_surface.dart';

import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/shared/widgets/moe_app_bar.dart';
import '../../../../ui/shared/widgets/moe_adaptive_shell.dart';
import '../../../../ui/shared/widgets/moe_content_surface.dart';
import '../../../../ui/shared/widgets/list/moe_settings_row.dart';
import '../../debug/pages/debug_center_page.dart';
import 'chat_plugin_settings_page.dart';
import 'model_list_page.dart';
import 'ui_settings_page.dart';
import 'lan_sync_page.dart';

/// 窄屏与宽屏左侧共用的设置根页。
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: const MoeAppBar(title: '设置', centerTitle: true),
      backgroundColor: MoeSurfaceGroup.contains(context)
          ? Colors.transparent
          : context.moeColors.surface,
      body: const SettingsContent(),
    );
  }
}

/// 设置根目录，复用统一详情导航打开完整子页。
class SettingsContent extends ConsumerStatefulWidget {
  const SettingsContent({super.key});

  @override
  ConsumerState<SettingsContent> createState() => _SettingsContentState();
}

class _SettingsContentState extends ConsumerState<SettingsContent> {
  // Size text, touch targets and whitespace independently of display density.
  static const double _outerInset = 12;
  static const double _innerInset = 16;

  static const _entries = [
    (
      label: '账号',
      icon: Icons.person_rounded,
      color: Color(0xFF007AFF),
      page: AccountPage(),
    ),
    (
      label: '模型',
      icon: Icons.layers_rounded,
      color: Color(0xFF5856D6),
      page: ModelListPage(),
    ),
    (
      label: '通用',
      icon: Icons.tune_rounded,
      color: Color(0xFF32ADE6),
      page: UiSettingsPage(),
    ),
    (
      label: '插件',
      icon: Icons.extension_rounded,
      color: Color(0xFFAF52DE),
      page: ChatPluginSettingsPage(),
    ),
    (
      label: '局域网同步',
      icon: Icons.devices_rounded,
      color: Color(0xFF34C759),
      page: LanSyncPage(),
    ),
    (
      label: '调试',
      icon: Icons.terminal_rounded,
      color: Color(0xFFFF9500),
      page: DebugCenterPage(),
    ),
  ];

  void _openProfile() => MoeWorkspace.open(context, const ProfilePage());

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(appSettingsProvider).valueOrNull;
    final colors = context.moeColors;
    final name = settings?.userName?.trim();
    final displayName = name == null || name.isEmpty ? '设置个人资料' : name;

    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: moeUnderBarPadding(
        context,
        const EdgeInsets.only(top: 2, bottom: 24),
      ),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(_outerInset, 0, _outerInset, 16),
          // Preserve the current theme while lifting the profile off the backdrop.
          child: MoeContentSurface(
            key: const ValueKey('settings-profile-card'),
            child: InkWell(
              onTap: _openProfile,
              child: Padding(
                padding: const EdgeInsets.all(_innerInset),
                child: Row(
                  children: [
                    MoeAvatar(
                      name: displayName,
                      avatarUrl: settings?.userAvatar,
                      size: 56,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: MoeFontWeights.emphasis,
                              color: colors.text,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            '编辑头像和名字',
                            style: TextStyle(fontSize: 14, color: colors.muted),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      Icons.chevron_right,
                      color: colors.muted.withValues(alpha: 0.55),
                      size: 20,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: _outerInset),
          child: MoeContentSurface(
            key: const ValueKey('settings-entry-container'),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final entry in _entries)
                  _buildEntry(
                    context,
                    icon: entry.icon,
                    color: entry.color,
                    label: entry.label,
                    page: entry.page,
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildEntry(
    BuildContext context, {
    required IconData icon,
    required Color color,
    required String label,
    required Widget page,
  }) {
    return MoeSettingsRow(
      label: label,
      showDivider: false,
      trailingType: MoeSettingsRowTrailing.custom,
      trailing: Icon(
        Icons.chevron_right,
        size: 20,
        color: context.moeColors.muted.withValues(alpha: 0.55),
      ),
      labelStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.normal),
      iconContainerWidth: 30,
      iconWidget: Container(
        width: 30,
        height: 30,
        decoration: MoeG2Decoration(radius: 7, color: color),
        child: Icon(icon, color: Colors.white, size: 19),
      ),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: _innerInset,
        vertical: 11,
      ),
      onTap: () => MoeWorkspace.open(context, page),
    );
  }
}
