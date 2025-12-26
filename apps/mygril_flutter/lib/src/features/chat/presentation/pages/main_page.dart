import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'contacts_page.dart';
import 'role_card_page.dart';
import 'profile_page.dart';
import '../widgets/custom_bottom_nav.dart';
import '../../../../core/widgets/settings_drawer_wrapper.dart';
import '../../../../core/widgets/settings_drawer_panel.dart';
import '../../../../core/theme/tokens.dart';

/// 主页面 - 包含底部导航栏（仅小屏模式使用）
class MainPage extends ConsumerStatefulWidget {
  const MainPage({super.key});

  @override
  ConsumerState<MainPage> createState() => _MainPageState();
}

class _MainPageState extends ConsumerState<MainPage>
    with SingleTickerProviderStateMixin {
  int _currentIndex = 0;
  
  // 淡入淡出动画控制器
  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;

  // 三个标签页
  final List<Widget> _pages = const [
    ContactsPage(), // 消息（角色列表）
    RoleCardPage(), // 角色卡
    ProfilePage(),  // 我的
  ];

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _fadeController, curve: Curves.easeOut),
    );
    _fadeController.value = 1.0; // 初始状态为完全显示
  }

  @override
  void dispose() {
    _fadeController.dispose();
    super.dispose();
  }
  
  /// 切换标签页 - 先淡出再切换再淡入
  void _switchTab(int index) {
    if (index == _currentIndex) return;
    
    // 先淡出
    _fadeController.reverse().then((_) {
      // 切换页面
      setState(() {
        _currentIndex = index;
      });
      // 再淡入
      _fadeController.forward();
    });
  }

  @override
  Widget build(BuildContext context) {
    return SettingsDrawerWrapper(
      settingsBuilder: (close) => SettingsDrawerPanel(onClose: close),
      child: Scaffold(
        // 使用 FadeTransition + IndexedStack 实现无闪烁切换
        body: FadeTransition(
          opacity: _fadeAnimation,
          child: IndexedStack(
            index: _currentIndex,
            children: _pages,
          ),
        ),
        bottomNavigationBar: CustomBottomNav(
          currentIndex: _currentIndex,
          onTap: _switchTab,
          items: const [
            BottomNavItem(
              icon: Icons.chat_bubble_outline,
              activeIcon: Icons.chat_bubble,
              label: '消息',
            ),
            BottomNavItem(
              icon: Icons.style_outlined,
              activeIcon: Icons.style,
              label: '角色卡',
            ),
            BottomNavItem(
              icon: Icons.person_outline,
              activeIcon: Icons.person,
              label: '我的',
            ),
          ],
        ),
      ),
    );
  }
}
