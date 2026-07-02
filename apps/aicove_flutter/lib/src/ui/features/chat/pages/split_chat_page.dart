import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../features/chat/providers2.dart';
import '../../../../features/chat/domain/sort_mode.dart';
import '../../../../features/settings/app_settings.dart';
import 'chat_page.dart';
import '../../../../features/chat/presentation/widgets/contacts_list_content.dart';
import '../../../../features/chat/presentation/widgets/contacts_sub_header.dart';
import '../../../../ui/features/character/pages/role_card_page.dart';
import '../../../../features/chat/presentation/widgets/profile_content.dart';
import '../../../../ui/shared/widgets/nav/moe_side_nav.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/widgets/desktop_window_frame.dart';
import '../../../../ui/shared/widgets/settings_drawer_wrapper.dart';
import '../../../../ui/shared/widgets/settings_drawer_panel.dart';

class SplitChatPage extends ConsumerStatefulWidget {
  const SplitChatPage({super.key});

  @override
  ConsumerState<SplitChatPage> createState() => _SplitChatPageState();
}

class _SplitChatPageState extends ConsumerState<SplitChatPage>
    with SingleTickerProviderStateMixin {
  int _currentIndex = 0;
  final GlobalKey<SettingsDrawerWrapperState> _drawerKey = GlobalKey();
  double? _sidebarWidth; // 首次 build 时按窗口宽度 40% 初始化
  final String _searchQuery = '';

  // 淡入淡出动画控制器
  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      vsync: this,
      duration: kAnim,
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

  void _openSettings() {
    _drawerKey.currentState?.open();
  }

  // 根据索引构建页面列表
  List<Widget> _buildPages(SortMode sortMode, bool isAscending) {
    return [
      // 消息（角色列表）- 宽屏模式只更新状态，不跳转路由
      ContactsListContent(
        searchQuery: _searchQuery,
        sortMode: sortMode,
        isAscending: isAscending,
        onContactTap: (conversationId, ref) {
          ref.read(activeConversationIdProvider.notifier).state =
              conversationId;
        },
      ),
      const RoleCardContent(), // 角色卡 - 复用组件
      const ProfileContent(), // 我的 - 复用组件
    ];
  }

  @override
  Widget build(BuildContext context) {
    final sidebarVisible = ref.watch(sidebarVisibleProvider);
    final sortMode = ref.watch(sortModeProvider);
    final isAscending = ref.watch(sortAscendingProvider);
    final windowControlsOnRight = ref.watch(appSettingsProvider).maybeWhen(
          data: (settings) =>
              settings.windowsWindowControlsSide ==
              WindowControlButtonSide.right,
          orElse: () => false,
        );
    final windowControlsLeadingInset =
        macButtonsLeadingInset(windowControlsOnRight);
    final windowControlsTrailingInset =
        macButtonsTrailingInset(windowControlsOnRight);
    final colors = context.moeColors;

    // 首次 build 时按窗口宽度 40% 初始化侧边栏宽度（四六开）
    _sidebarWidth ??= MediaQuery.sizeOf(context).width * 0.4;

    // 内容面板实际宽度（包含侧边导航）
    final contentPanelWidth = sidebarVisible ? _sidebarWidth! : 0.0;

    return SettingsDrawerWrapper(
      key: _drawerKey,
      settingsBuilder: (close) => SettingsDrawerPanel(onClose: close),
      child: Scaffold(
        body: Stack(
          children: [
            // 基础布局：左区（粉色header + 侧边栏|列表）+ 右区（聊天）
            Row(
              children: [
                // 左区整体
                AnimatedContainer(
                  duration: kAnim,
                  curve: Curves.easeInOut,
                  width: sidebarVisible ? _sidebarWidth! : 0,
                  child: sidebarVisible
                      ? Column(
                          children: [
                            // 粉色 header 横跨左区全宽，MomoTalk 贴住左边
                            Container(
                              height: 56 + borderWidth,
                              padding: EdgeInsets.only(
                                left: 16 + windowControlsLeadingInset,
                                right: 8 + windowControlsTrailingInset,
                              ),
                              decoration: BoxDecoration(
                                color: colors.headerColor,
                                border: Border(
                                  bottom: BorderSide(
                                      color: colors.divider,
                                      width: borderWidth),
                                ),
                              ),
                              child: Row(
                                children: [
                                  const Spacer(),
                                  // 加号按钮 - 仅在消息标签页显示
                                  if (_currentIndex == 0)
                                    IconButton(
                                      onPressed: () =>
                                          context.go('/contact/new'),
                                      icon: Icon(Icons.add,
                                          color: colors.headerContentColor,
                                          size: 26),
                                      splashRadius: 20,
                                    ),
                                ],
                              ),
                            ),
                            // 下方：侧边栏 + 内容列表 并排
                            Expanded(
                              child: Row(
                                children: [
                                  // 侧边导航栏（在 header 下方）
                                  MoeSideNav(
                                    currentIndex: _currentIndex,
                                    onTap: _switchTab,
                                    onSettingsTap: _openSettings,
                                    items: const [
                                      SideNavItem(
                                        icon: Icons.chat_bubble_outline,
                                        activeIcon: Icons.chat_bubble,
                                        label: '消息',
                                      ),
                                      SideNavItem(
                                        icon: Icons.style_outlined,
                                        activeIcon: Icons.style,
                                        label: '角色卡',
                                      ),
                                      SideNavItem(
                                        icon: Icons.person_outline,
                                        activeIcon: Icons.person,
                                        label: '我的',
                                      ),
                                    ],
                                  ),
                                  // 内容列表（含未读消息栏）
                                  Expanded(
                                    child: Container(
                                      color: colors.surface,
                                      child: Column(
                                        children: [
                                          // 未读消息栏（仅消息页显示）
                                          if (_currentIndex == 0)
                                            ContactsSubHeader(
                                                searchQuery: _searchQuery),
                                          Expanded(
                                            child: FadeTransition(
                                              opacity: _fadeAnimation,
                                              child: IndexedStack(
                                                index: _currentIndex,
                                                children: _buildPages(
                                                    sortMode, isAscending),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        )
                      : const SizedBox.shrink(),
                ),
                // 右侧聊天区域
                const Expanded(
                  child: ChatPage(showToggleButton: true),
                ),
              ],
            ),
            // 叠加层：透明拖动热区
            if (sidebarVisible)
              Positioned(
                left: contentPanelWidth - 4,
                top: 0,
                bottom: 0,
                width: 8,
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeColumn,
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onHorizontalDragUpdate: (details) {
                      setState(() {
                        _sidebarWidth = (_sidebarWidth! + details.delta.dx)
                            .clamp(200.0, 600.0);
                      });
                    },
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
