import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'contacts_page.dart';
import 'settings_page.dart';
import 'profile_page.dart';
import '../widgets/custom_bottom_nav.dart';

/// 主页面 - 包含底部导航栏（仅小屏模式使用）
class MainPage extends ConsumerStatefulWidget {
  const MainPage({super.key});

  @override
  ConsumerState<MainPage> createState() => _MainPageState();
}

class _MainPageState extends ConsumerState<MainPage> {
  int _currentIndex = 0;
  late PageController _pageController;

  // 三个标签页
  final List<Widget> _pages = const [
    ContactsPage(), // 消息（角色列表）
    SettingsPage(), // 设置
    ProfilePage(),  // 我的
  ];

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: _currentIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: PageView(
        controller: _pageController,
        physics: const NeverScrollableScrollPhysics(), // 禁用手势滑动，只允许通过底部导航切换
        children: _pages,
        onPageChanged: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
      ),
      bottomNavigationBar: CustomBottomNav(
        currentIndex: _currentIndex,
        onTap: (index) {
          _pageController.animateToPage(
            index,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
          );
        },
        items: const [
          BottomNavItem(
            icon: Icons.chat_bubble_outline,
            activeIcon: Icons.chat_bubble,
            label: '消息',
          ),
          BottomNavItem(
            icon: Icons.settings_outlined,
            activeIcon: Icons.settings,
            label: '设置',
          ),
          BottomNavItem(
            icon: Icons.person_outline,
            activeIcon: Icons.person,
            label: '我的',
          ),
        ],
      ),
    );
  }
}
