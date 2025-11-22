import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/tokens.dart';
import '../../../settings/app_settings.dart';
import '../../../settings/direct_mode.dart' as direct;
// import '../../../settings/provider_state.dart';
import 'package:mygril_flutter/src/features/chat/presentation/pages/model_list_page.dart';
import 'package:mygril_flutter/src/features/settings/preset_management_page.dart';
import 'plugin_settings_page.dart';
import 'auto_reply_settings_page.dart';
import 'message_format_settings_page.dart';
import 'ui_settings_page.dart';
// import 'provider_selector_page.dart';

/// 设置页面 - 带AppBar 的完整页面（小屏使用）
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: colors.headerColor,
        foregroundColor: colors.headerContentColor,
        elevation: 0,
        // 添加底部分割线
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(borderWidth),
          child: Container(
            color: colors.borderLight,
            height: borderWidth,
          ),
        ),
        title: Padding(
          padding: const EdgeInsets.only(left: 12),
          child: Text(
            '设置',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 24,
              color: colors.headerContentColor,
              letterSpacing: 0.8,
            ),
          ),
        ),
        centerTitle: false,
      ),
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
  void dispose() {
    super.dispose();
  }

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
            const SizedBox(height: 8),
            _SectionHeader(title: '常用功能设置', colors: colors),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              minLeadingWidth: 48,
              leading: Icon(Icons.list_alt, color: colors.text, size: 24),
              title: Text('管理模型列表', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: colors.text)),
              trailing: Icon(Icons.chevron_right, color: colors.muted),
              onTap: () {
                Navigator.of(context).push(
                  PageRouteBuilder(
                    pageBuilder: (context, animation, secondaryAnimation) => const ModelListPage(),
                    transitionsBuilder: (context, animation, secondaryAnimation, child) {
                      const begin = Offset(1.0, 0.0);  // 从右侧开始
                      const end = Offset.zero;         // 滑动到当前位置
                      const curve = Curves.easeOut;
                      final tween = Tween(begin: begin, end: end).chain(CurveTween(curve: curve));
                      final offsetAnimation = animation.drive(tween);
                      return SlideTransition(position: offsetAnimation, child: child);
                    },
                    transitionDuration: const Duration(milliseconds: 250),
                  ),
                );
              },
            ),
            Divider(height: 0, thickness: borderWidth, color: colors.divider),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              minLeadingWidth: 48,
              leading: Icon(Icons.person_add_alt_1, color: colors.text, size: 24),
              title: Text('角色预设管理', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: colors.text)),
              trailing: Icon(Icons.chevron_right, color: colors.muted),
              onTap: () {
                Navigator.of(context).push(
                  PageRouteBuilder(
                    pageBuilder: (context, animation, secondaryAnimation) => const PresetManagementPage(),
                    transitionsBuilder: (context, animation, secondaryAnimation, child) {
                      const begin = Offset(1.0, 0.0);
                      const end = Offset.zero;
                      const curve = Curves.easeOut;
                      final tween = Tween(begin: begin, end: end).chain(CurveTween(curve: curve));
                      final offsetAnimation = animation.drive(tween);
                      return SlideTransition(position: offsetAnimation, child: child);
                    },
                    transitionDuration: const Duration(milliseconds: 250),
                  ),
                );
              },
            ),
            Divider(height: 0, thickness: borderWidth, color: colors.divider),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              minLeadingWidth: 48,
              leading: Icon(Icons.extension, color: colors.text, size: 24),
              title: Text('插件设置', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: colors.text)),
              trailing: Icon(Icons.chevron_right, color: colors.muted),
              onTap: () {
                Navigator.of(context).push(
                  PageRouteBuilder(
                    pageBuilder: (context, animation, secondaryAnimation) => const PluginSettingsPage(),
                    transitionsBuilder: (context, animation, secondaryAnimation, child) {
                      const begin = Offset(1.0, 0.0);
                      const end = Offset.zero;
                      const curve = Curves.easeOut;
                      final tween = Tween(begin: begin, end: end).chain(CurveTween(curve: curve));
                      final offsetAnimation = animation.drive(tween);
                      return SlideTransition(position: offsetAnimation, child: child);
                    },
                    transitionDuration: const Duration(milliseconds: 250),
                  ),
                );
              },
            ),
            Divider(height: 0, thickness: borderWidth, color: colors.divider),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              minLeadingWidth: 48,
              leading: Icon(Icons.palette_outlined, color: colors.text, size: 24),
              title: Text('界面设置', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: colors.text)),
              subtitle: Text('消息字体大小等显示设置', style: TextStyle(fontSize: 13, color: colors.muted)),
              trailing: Icon(Icons.chevron_right, color: colors.muted),
              onTap: () {
                Navigator.of(context).push(
                  PageRouteBuilder(
                    pageBuilder: (context, animation, secondaryAnimation) => const UiSettingsPage(),
                    transitionsBuilder: (context, animation, secondaryAnimation, child) {
                      const begin = Offset(1.0, 0.0);
                      const end = Offset.zero;
                      const curve = Curves.easeOut;
                      final tween = Tween(begin: begin, end: end).chain(CurveTween(curve: curve));
                      final offsetAnimation = animation.drive(tween);
                      return SlideTransition(position: offsetAnimation, child: child);
                    },
                    transitionDuration: const Duration(milliseconds: 250),
                  ),
                );
              },
            ),

            const SizedBox(height: 16),
            _SectionHeader(title: '拟人聊天设置', colors: colors),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              minLeadingWidth: 48,
              leading: Icon(Icons.favorite_outline, color: colors.text, size: 24),
              title: Text('主动回复设置', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: colors.text)),
              subtitle: Text('调节AI主动触发频率与免打扰', style: TextStyle(fontSize: 13, color: colors.muted)),
              trailing: Icon(Icons.chevron_right, color: colors.muted),
              onTap: () {
                Navigator.of(context).push(
                  PageRouteBuilder(
                    pageBuilder: (context, animation, secondaryAnimation) => const AutoReplySettingsPage(),
                    transitionsBuilder: (context, animation, secondaryAnimation, child) {
                      const begin = Offset(1.0, 0.0);
                      const end = Offset.zero;
                      const curve = Curves.easeOut;
                      final tween = Tween(begin: begin, end: end).chain(CurveTween(curve: curve));
                      final offsetAnimation = animation.drive(tween);
                      return SlideTransition(position: offsetAnimation, child: child);
                    },
                    transitionDuration: const Duration(milliseconds: 250),
                  ),
                );
              },
            ),
            Divider(height: 0, thickness: borderWidth, color: colors.divider),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              minLeadingWidth: 48,
              leading: Icon(Icons.message, color: colors.text, size: 24),
              title: Text('消息格式设置', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: colors.text)),
              subtitle: Text('分段发送、标点过滤等', style: TextStyle(fontSize: 13, color: colors.muted)),
              trailing: Icon(Icons.chevron_right, color: colors.muted),
              onTap: () {
                Navigator.of(context).push(
                  PageRouteBuilder(
                    pageBuilder: (context, animation, secondaryAnimation) => const MessageFormatSettingsPage(),
                    transitionsBuilder: (context, animation, secondaryAnimation, child) {
                      const begin = Offset(1.0, 0.0);
                      const end = Offset.zero;
                      const curve = Curves.easeOut;
                      final tween = Tween(begin: begin, end: end).chain(CurveTween(curve: curve));
                      final offsetAnimation = animation.drive(tween);
                      return SlideTransition(position: offsetAnimation, child: child);
                    },
                    transitionDuration: const Duration(milliseconds: 250),
                  ),
                );
              },
            ),

            const SizedBox(height: 24),
          ],
        );
      },
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final MoeColors colors;
  const _SectionHeader({required this.title, required this.colors});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Text(title, style: TextStyle(color: colors.textSecondary, fontWeight: FontWeight.w600)),
    );
  }
}
