import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../features/settings/app_settings.dart';
import '../../../shared/widgets/moe_avatar.dart';
import '../../../shared/widgets/moe_search_field.dart';
import '../../../shared/widgets/moe_scroll_edge.dart';
import 'profile_page.dart';
import 'account_page.dart';
import 'log_viewer_page.dart';
import '../../backup/pages/data_management_page.dart';
import '../../debug/pages/prompt_node_management_page.dart';
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

/// 窄屏与宽屏左侧共用的设置根页。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: MoeAppBar(
        title: '设置',
        centerTitle: true,
        bottom: MoeSearchField(
          hintText: '搜索',
          padding: SettingsContent.searchPadding,
          onChanged: (value) => setState(() => _query = value),
        ),
        bottomHeight: MoeSearchField.heightFor(
          context,
          padding: SettingsContent.searchPadding,
        ),
      ),
      backgroundColor: MoeSurfaceGroup.contains(context)
          ? Colors.transparent
          : context.moeColors.surface,
      body: SettingsContent(query: _query),
    );
  }
}

/// 设置根目录，复用统一详情导航打开完整子页。
class SettingsContent extends ConsumerStatefulWidget {
  const SettingsContent({super.key, this.query = ''});

  final String query;

  static const searchPadding = EdgeInsets.fromLTRB(
    _SettingsContentState._outerInset,
    4,
    _SettingsContentState._outerInset,
    10,
  );

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
      keywords: '账户 登录 退出 用户名 密码 ID 云同步 服务器',
      icon: Icons.person_rounded,
      color: Color(0xFF007AFF),
      page: AccountPage(),
      root: true,
    ),
    (
      label: '模型',
      keywords: 'API api key 密钥 供应商 默认模型 语言模型',
      icon: Icons.layers_rounded,
      color: Color(0xFF5856D6),
      page: ModelListPage(),
      root: true,
    ),
    (
      label: '通用',
      keywords: '通用设置 界面 辅助回答 快速 回复建议 主题 颜色 深色 浅色 外观 字体 背景 玻璃 材质 跟随系统',
      icon: Icons.tune_rounded,
      color: Color(0xFF32ADE6),
      page: UiSettingsPage(),
      root: true,
    ),
    (
      label: '插件',
      keywords: '绘图 生图 图片 语音 音色 朗读 TTS 记忆 表情包 酒馆 预设 正则 世界书 时间 主动回复',
      icon: Icons.extension_rounded,
      color: Color(0xFFAF52DE),
      page: ChatPluginSettingsPage(),
      root: true,
    ),
    (
      label: '调试',
      keywords: '诊断 网络 超时 消息分段 流式 组件库 工具提示词',
      icon: Icons.terminal_rounded,
      color: Color(0xFFFF9500),
      page: DebugCenterPage(),
      root: true,
    ),
    (
      label: '个人资料',
      keywords: '头像 名字 名称 昵称 我的资料',
      icon: Icons.person_rounded,
      color: Color(0xFF3390EC),
      page: ProfilePage(),
      root: false,
    ),
    (
      label: '日志中心',
      keywords: '调试 日志 异常 错误',
      icon: Icons.article_rounded,
      color: Color(0xFFF59A23),
      page: LogViewerPage(),
      root: false,
    ),
    (
      label: '数据管理',
      keywords: '调试 数据 备份 导入 导出 恢复',
      icon: Icons.storage_rounded,
      color: Color(0xFF30B0C7),
      page: DataManagementPage(),
      root: false,
    ),
    (
      label: '提示词节点',
      keywords: '调试 提示词 节点 agent',
      icon: Icons.account_tree_rounded,
      color: Color(0xFFAF62DE),
      page: PromptNodeManagementPage(),
      root: false,
    ),
  ];

  void _openProfile() => MoeWorkspace.open(context, const ProfilePage());

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(appSettingsProvider).valueOrNull;
    final colors = context.moeColors;
    final name = settings?.userName?.trim();
    final displayName = name == null || name.isEmpty ? '设置个人资料' : name;
    final terms = widget.query.trim().toLowerCase().split(RegExp(r'\s+'));
    final searching = widget.query.trim().isNotEmpty;
    final entries = _entries
        .where(
          (entry) => searching
              ? terms.every(
                  (term) => '${entry.label} ${entry.keywords}'
                      .toLowerCase()
                      .contains(term),
                )
              : entry.root,
        )
        .toList();

    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: moeUnderBarPadding(
        context,
        const EdgeInsets.only(top: 2, bottom: 24),
      ),
      children: [
        if (!searching) ...[
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
                              style: TextStyle(
                                fontSize: 14,
                                color: colors.muted,
                              ),
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
        ],
        if (entries.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: _outerInset),
            child: MoeContentSurface(
              key: const ValueKey('settings-entry-container'),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final entry in entries)
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
        if (entries.isEmpty)
          Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              '没有找到相关设置',
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.muted),
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
