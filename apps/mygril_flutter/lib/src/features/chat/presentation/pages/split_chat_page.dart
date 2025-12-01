import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../providers2.dart';
import 'chat_page.dart';
import 'package:mygril_flutter/src/features/chat/presentation/widgets/contacts_list_content.dart';
import 'role_card_page.dart';
import 'settings_page.dart';
import '../widgets/profile_content.dart';
import '../widgets/custom_bottom_nav.dart';
import '../../../../core/theme/tokens.dart';
import 'package:mygril_flutter/src/features/chat/presentation/widgets/momotalk_sort_dialog.dart';

class SplitChatPage extends ConsumerStatefulWidget {
  const SplitChatPage({super.key});

  @override
  ConsumerState<SplitChatPage> createState() => _SplitChatPageState();
}

class _SplitChatPageState extends ConsumerState<SplitChatPage> {
  int _currentIndex = 0;
  late PageController _pageController;
  double _sidebarWidth = 320; // 可调节的侧边栏宽度
  String _searchQuery = '';
  SortMode _sortMode = SortMode.latest;
  bool _isAscending = false;

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

  void _showSortDialog() {
    showDialog(
      context: context,
      builder: (context) => MomotalkSortDialog(
        currentMode: _sortMode,
        onModeChanged: (mode) {
          setState(() {
            _sortMode = mode;
            if (mode == SortMode.name) {
              _isAscending = true;
            } else {
              _isAscending = false;
            }
          });
          Navigator.of(context).pop();
        },
      ),
    );
  }

  void _toggleSortOrder() {
    setState(() {
      _isAscending = !_isAscending;
    });
  }

  // 根据索引构建页面列表
  List<Widget> _buildPages() {
    return [
      // 消息（角色列表）- 宽屏模式只更新状态，不跳转路由
      ContactsListContent(
        searchQuery: _searchQuery,
        sortMode: _sortMode,
        isAscending: _isAscending,
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
    final colors = context.moeColors;

    return Scaffold(
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
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            decoration: BoxDecoration(
                              color: colors.headerColor,
                              border: Border(
                                bottom: BorderSide(color: colors.divider, width: borderWidth),
                              ),
                            ),
                            child: Row(
                              children: [
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
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                              decoration: BoxDecoration(
                                color: colors.surface,
                                border: Border(
                                  bottom: BorderSide(color: colors.divider, width: borderWidth),
                                ),
                              ),
                              child: Row(
                                children: [
                                  Builder(builder: (context) {
                                    final listAsync = ref.watch(conversationsProvider);
                                    final count = listAsync.maybeWhen(
                                      data: (list) {
                                        final q = _searchQuery.trim().toLowerCase();
                                        if (q.isEmpty) return list.length;
                                        return list
                                            .where((c) => c.displayName.toLowerCase().contains(q))
                                            .length;
                                      },
                                      orElse: () => 0,
                                    );
                                    return Text(
                                      '未读消息 ($count)',
                                      style: TextStyle(
                                        color: colors.text,
                                        fontSize: 15,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    );
                                  }),
                                  const Spacer(),
                                  // "排序模式" 按钮
                                  Tooltip(
                                    message: '排序方式',
                                    child: GestureDetector(
                                      onTap: _showSortDialog,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                        decoration: BoxDecoration(
                                          color: colors.surface,
                                          border: Border.all(color: colors.divider),
                                          borderRadius: BorderRadius.circular(4),
                                          boxShadow: [
                                            BoxShadow(
                                              color: Colors.black.withOpacity(0.02),
                                              offset: const Offset(0, 1),
                                              blurRadius: 1,
                                            ),
                                          ],
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text(
                                              _sortMode == SortMode.latest ? '最新' : '名字',
                                              style: TextStyle(
                                                color: colors.text,
                                                fontSize: 13,
                                                fontWeight: FontWeight.w500,
                                              ),
                                            ),
                                            const SizedBox(width: 4),
                                            Icon(
                                              Icons.arrow_drop_down,
                                              size: 16,
                                              color: colors.textSecondary,
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  // 升序/降序 切换按钮
                                  Tooltip(
                                    message: '切换顺序',
                                    child: Material(
                                      color: Colors.transparent,
                                      child: InkWell(
                                        onTap: _toggleSortOrder,
                                        borderRadius: BorderRadius.circular(4),
                                        child: Container(
                                          padding: const EdgeInsets.all(4),
                                          decoration: BoxDecoration(
                                            border: Border.all(color: colors.divider),
                                            borderRadius: BorderRadius.circular(4),
                                          ),
                                          child: Icon(
                                            _isAscending ? Icons.arrow_upward : Icons.arrow_downward,
                                            size: 16,
                                            color: colors.textSecondary,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          // 内容区域
                          Expanded(
                            child: Container(
                              // 左栏背景色（移除原先的右侧边框，由独立分割线绘制）
                              color: colors.surface,
                              child: PageView(
                                controller: _pageController,
                                physics: const NeverScrollableScrollPhysics(), // 禁用手势滑动
                                onPageChanged: (index) {
                                  setState(() {
                                    _currentIndex = index;
                                  });
                                },
                                children: _buildPages(),
                              ),
                            ),
                          ),
                          // 底部导航栏
                          CustomBottomNav(
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
    );
  }
}
