import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../features/chat/providers2.dart';
import '../../../../features/chat/presentation/widgets/contacts_list_content.dart';
import '../../../../features/chat/presentation/widgets/contacts_sub_header.dart';
import '../../../../features/settings/app_settings.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/shared/widgets/desktop_window_frame.dart';
import '../../../../ui/shared/widgets/settings_drawer_wrapper.dart';

class ContactsPage extends ConsumerStatefulWidget {
  const ContactsPage({super.key});

  @override
  ConsumerState<ContactsPage> createState() => _ContactsPageState();
}

class _ContactsPageState extends ConsumerState<ContactsPage> {
  final TextEditingController _controller = TextEditingController();
  final String _query = '';

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

    return Scaffold(
      appBar: AppBar(
        backgroundColor: colors.headerColor,
        foregroundColor: colors.headerContentColor,
        elevation: 0,
        leadingWidth: 48 + windowControlsLeadingInset,
        titleSpacing: 0, // 移除 title 左侧默认间距
        leading: Padding(
          padding: EdgeInsets.only(left: windowControlsLeadingInset),
          child: IconButton(
            icon: Icon(Icons.menu, color: colors.headerContentColor),
            tooltip: '设置',
            onPressed: _openSettings,
          ),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(borderWidth),
          child: Container(
            height: borderWidth,
            decoration: BoxDecoration(
              color: colors.divider,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.04),
                  offset: const Offset(0, 1),
                  blurRadius: 0,
                ),
              ],
            ),
          ),
        ),
        title: const SizedBox.shrink(),
        centerTitle: false,
        actions: [
          // 加号按钮 - 添加新角色
          MoeG2ClipRRect(
            radius: 8,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () {
                  context.go('/contact/new');
                },
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Icon(Icons.add,
                      color: colors.headerContentColor, size: 26),
                ),
              ),
            ),
          ),
          SizedBox(width: 8 + windowControlsTrailingInset),
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
