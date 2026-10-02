import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/chat/presentation/widgets/custom_bottom_nav.dart';
import '../../../theme/tokens.dart';
import '../../../shared/widgets/moe_floating_surface.dart';
import '../../../shared/widgets/moe_adaptive_shell.dart';
import '../../character/pages/role_card_page.dart';
import '../../settings/pages/settings_page.dart';
import 'contacts_page.dart';

/// The same primary interface is used on phones and in the left pane.
class MainPage extends ConsumerStatefulWidget {
  const MainPage({super.key});
  @override
  ConsumerState<MainPage> createState() => _MainPageState();
}

class _MainPageState extends ConsumerState<MainPage> {
  final _visited = <int>{0};
  int _currentIndex = 0;

  void _switchTab(int index) {
    if (_currentIndex == index) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _currentIndex = index;
      _visited.add(index);
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final isWide = MoeWorkspace.maybeOf(context)?.isWide == true;
    return MoeFloatingSurface(
      baseline: MoeMaterialBaseline.background,
      // Page backgrounds keep blur and tint without a lens rim at the edges.
      useLiquid: false,
      // Full-screen narrow pages have nothing behind them to blur; a material
      // tint there would repaint the page background as a container color.
      blurEnabled: isWide ? null : false,
      radius: isWide ? telegramPrimaryRadius : 0,
      solidColor: colors.surface,
      border: BorderSide.none,
      shadows: const [],
      child: MoeSurfaceGroup(
        child: Scaffold(
      backgroundColor: Colors.transparent,
          body: IndexedStack(index: _currentIndex, children: [
        const ContactsPage(),
        _visited.contains(1) ? const RoleCardPage() : const SizedBox.shrink(),
        _visited.contains(2) ? const SettingsPage() : const SizedBox.shrink(),
      ]),
      bottomNavigationBar: CustomBottomNav(
        currentIndex: _currentIndex,
        onTap: _switchTab,
        items: const [
          BottomNavItem(
              icon: Icons.chat_bubble_outline_rounded,
              activeIcon: Icons.chat_bubble_rounded,
              label: '聊天'),
          BottomNavItem(
              icon: Icons.people_outline_rounded,
              activeIcon: Icons.people_rounded,
              label: '角色'),
          BottomNavItem(
              icon: Icons.settings_outlined,
              activeIcon: Icons.settings,
              label: '设置'),
        ],
      ),
    )),
    );
  }
}
