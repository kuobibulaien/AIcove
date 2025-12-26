import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../providers2.dart';
import 'package:mygril_flutter/src/features/chat/presentation/widgets/contacts_list_content.dart';
import 'package:mygril_flutter/src/features/chat/presentation/widgets/contacts_sub_header.dart';
import 'package:mygril_flutter/src/features/chat/presentation/widgets/momotalk_sort_dialog.dart';
import '../../../../core/theme/tokens.dart';
import '../../../../core/widgets/settings_drawer_wrapper.dart';

class ContactsPage extends ConsumerStatefulWidget {
  const ContactsPage({super.key});

  @override
  ConsumerState<ContactsPage> createState() => _ContactsPageState();
}

class _ContactsPageState extends ConsumerState<ContactsPage> {
  final TextEditingController _controller = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _openSettings() {
    SettingsDrawerController.of(context)?.open();
  }

  @override
  Widget build(BuildContext context) {
    final sortMode = ref.watch(sortModeProvider);
    final isAscending = ref.watch(sortAscendingProvider);
    final colors = context.moeColors;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: colors.headerColor,
          foregroundColor: colors.headerContentColor,
          elevation: 0,
          leadingWidth: 48, // 减少 leading 区域宽度，与宽屏模式对齐
          titleSpacing: 0, // 移除 title 左侧默认间距
          leading: IconButton(
            icon: Icon(Icons.menu, color: colors.headerContentColor),
            tooltip: '设置',
            onPressed: _openSettings,
          ),
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
          title: Text(
            'MomoTalk',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 24,
              color: colors.headerContentColor,
              letterSpacing: 0.8,
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
          ContactsSubHeader(searchQuery: _query),
          // 角色列表内容
          Expanded(
            child: ContactsListContent(
              searchQuery: _query,
              sortMode: sortMode,
              isAscending: isAscending,
            ),
          ),
        ],
      ),
    );
  }
}
