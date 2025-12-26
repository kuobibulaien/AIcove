import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../providers2.dart';
import 'chat_page.dart';
import 'package:mygril_flutter/src/features/chat/presentation/widgets/contacts_list_content.dart';
import 'package:mygril_flutter/src/features/chat/presentation/widgets/contacts_sub_header.dart';
import 'role_card_page.dart';
import '../widgets/profile_content.dart';
import '../widgets/custom_bottom_nav.dart';
import '../../../../core/theme/tokens.dart';
import '../../../../core/widgets/settings_drawer_wrapper.dart';
import '../../../../core/widgets/settings_drawer_panel.dart';
import 'package:mygril_flutter/src/features/chat/presentation/widgets/momotalk_sort_dialog.dart';

class SplitChatPage extends ConsumerStatefulWidget {
  const SplitChatPage({super.key});

  @override
  ConsumerState<SplitChatPage> createState() => _SplitChatPageState();
}

class _SplitChatPageState extends ConsumerState<SplitChatPage>
    with SingleTickerProviderStateMixin {
  int _currentIndex = 0;
  final GlobalKey<SettingsDrawerWrapperState> _drawerKey = GlobalKey();
  double _sidebarWidth = 320; // 可调节的侧边栏宽度
  String _searchQuery = '';
  
  // 淡入淡出动画控制器
  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;

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
          ref.read(activeConversationIdProvider.notifier).state = conversationId;
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
    final colors = context.moeColors;

    return SettingsDrawerWrapper(
      key: _drawerKey,
      settingsBuilder: (close) => SettingsDrawerPanel(onClose: close),
      child: Scaffold(
        body: Stack(
        children: [
          // 基础布局：左右并列
          Row(
            children: [
              // 左侧面板 - 带底部导航栏
              AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeInOut,
                width: sidebarVisible ? _sidebarWidth : 0,
                child: sidebarVisible
                    ? Column(
                        children: [
                          // 顶部导航栏
                          Container(
                            height: 56 + borderWidth, // 56dp内容 + 2dp分割线，与右侧AppBar总高度对齐
                            padding: const EdgeInsets.only(left: 4, right: 8),
                            decoration: BoxDecoration(
                              color: colors.headerColor,
                              border: Border(
                                bottom: BorderSide(color: colors.divider, width: borderWidth),
                              ),
                            ),
                            child: Row(
                              children: [
                                // 菜单按钮
                                IconButton(
                                  icon: Icon(Icons.menu, color: colors.headerContentColor),
                                  tooltip: '设置',
                                  onPressed: _openSettings,
                                ),
                                Builder(builder: (context) {
                                  if (_currentIndex == 0) {
                                    // 消息页显示 MomoTalk
                                    return Text(
                                      'MomoTalk',
                                      style: TextStyle(
                                        color: colors.headerContentColor,
                                        fontWeight: FontWeight.w800,
                                        fontSize: 24,
                                        letterSpacing: 0.8,
                                      ),
                                    );
                                  }
                                  return Text(
                                    'MyGril',
                                    style: TextStyle(
                                      color: colors.headerContentColor,
                                      fontWeight: FontWeight.w800,
                                      fontSize: 24,
                                      letterSpacing: 0.8,
                                    ),
                                  );
                                }),
                                const Spacer(),
                                // 加号按钮 - 仅在消息标签页显示
                                if (_currentIndex == 0)
                                  Material(
                                    color: Colors.transparent,
                                    child: InkWell(
                                      onTap: () {
                                        context.go('/contact/new');
                                      },
                                      borderRadius: BorderRadius.circular(8),
                                      child: Container(
                                        padding: const EdgeInsets.all(8),
                                        child: Icon(Icons.add, color: colors.headerContentColor, size: 26),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          // 次级标题栏：未读消息计数 + 排序按钮 (仅在消息页显示)
                          if (_currentIndex == 0)
                            ContactsSubHeader(searchQuery: _searchQuery),
                          // 内容区域 - 使用 FadeTransition + IndexedStack 实现无闪烁切换
                          Expanded(
                            child: Container(
                              color: colors.surface,
                              child: FadeTransition(
                                opacity: _fadeAnimation,
                                child: IndexedStack(
                                  index: _currentIndex,
                                  children: _buildPages(sortMode, isAscending),
                                ),
                              ),
                            ),
                          ),
                          // 底部导航栏
                          CustomBottomNav(
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
          // 叠加层：1px 可见分割线 + 8px 透明拖动热区
          if (sidebarVisible)
            Positioned(
              left: _sidebarWidth - 4, // 4px热区以线为中心覆盖左右
              top: 0,
              bottom: 0,
              width: 8,
              child: MouseRegion(
                cursor: SystemMouseCursors.resizeColumn,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onHorizontalDragUpdate: (details) {
                    setState(() {
                      _sidebarWidth += details.delta.dx;
                      _sidebarWidth = _sidebarWidth.clamp(200.0, 600.0);
                    });
                  },
                  child: Center(
                    child: Container(
                      width: borderWidth, // 视觉1px（0.5逻辑像素）
                      color: colors.divider,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
      ),
    );
  }
}
