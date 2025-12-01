import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../providers2.dart';
import 'settings_page.dart';
import 'package:mygril_flutter/src/features/chat/presentation/widgets/contacts_list_content.dart';
import 'package:mygril_flutter/src/features/chat/presentation/widgets/momotalk_sort_dialog.dart';
import '../../../../core/theme/tokens.dart';

class ContactsPage extends ConsumerStatefulWidget {
  const ContactsPage({super.key});

  @override
  ConsumerState<ContactsPage> createState() => _ContactsPageState();
}

class _ContactsPageState extends ConsumerState<ContactsPage> {
  final TextEditingController _controller = TextEditingController();
  String _query = '';
  SortMode _sortMode = SortMode.latest;
  bool _isAscending = false;

  @override
  void dispose() {
    _controller.dispose();
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
            // Reset order when mode changes? Or keep it? 
            // Usually switching to Name defaults to A-Z (Ascending), 
            // switching to Latest defaults to Newest First (Descending).
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

  @override
  Widget build(BuildContext context) {
    final listAsync = ref.watch(conversationsProvider);
    final colors = context.moeColors;
    final total = listAsync.maybeWhen(
      data: (list) {
        final q = _query.trim().toLowerCase();
        if (q.isEmpty) return list.length;
        return list.where((c) => c.displayName.toLowerCase().contains(q)).length;
      },
      orElse: () => 0,
    );

    return Scaffold(
      drawer: Drawer(
        backgroundColor: colors.surface,
        child: Column(
          children: [
            // Drawer Header - 模仿 Telegram 风格
            UserAccountsDrawerHeader(
              decoration: BoxDecoration(
                color: colors.headerColor,
              ),
              accountName: Text(
                '我的账号',
                style: TextStyle(
                  color: colors.headerContentColor,
                  fontWeight: FontWeight.bold,
                ),
              ),
              accountEmail: Text(
                '点击查看个人信息',
                style: TextStyle(
                  color: colors.headerContentColor.withOpacity(0.8),
                ),
              ),
              currentAccountPicture: CircleAvatar(
                backgroundColor: colors.surface,
                child: Icon(Icons.person, size: 40, color: colors.primary),
              ),
            ),
            // Settings Content
            Expanded(
              child: const SettingsContent(),
            ),
          ],
        ),
      ),
      appBar: AppBar(
        backgroundColor: colors.headerColor,
        foregroundColor: colors.headerContentColor,
        elevation: 0,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(borderWidth),
          child: Container(
            height: borderWidth,
            decoration: BoxDecoration(
              color: colors.divider,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.04),
                  offset: const Offset(0, 1),
                  blurRadius: 0,
                ),
              ],
            ),
          ),
        ),
        title: Padding(
          padding: const EdgeInsets.only(left: 12),
          child: Text(
            'MomoTalk',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 24,
              color: colors.headerContentColor,
              letterSpacing: 0.8,
            ),
          ),
        ),
        centerTitle: false,
        actions: [
          // 加号按钮 - 添加新角色
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
          const SizedBox(width: 8),
        ],
      ),
      backgroundColor: colors.surface,
      body: Column(
        children: [
          // 次级标题栏：未读消息计数 + 排序按钮
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
                Text(
                  '未读消息 ($total)',
                  style: TextStyle(
                    color: colors.text,
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                  ),
                ),
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
          // 角色列表内容
          Expanded(
            child: ContactsListContent(
              searchQuery: _query,
              sortMode: _sortMode,
              isAscending: _isAscending,
            ),
          ),
        ],
      ),
    );
  }
}
