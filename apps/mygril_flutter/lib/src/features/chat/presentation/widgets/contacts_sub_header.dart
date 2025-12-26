/// 联系人列表次级标题栏组件
/// 
/// 遵循 DRY 原则：从 ContactsPage 和 SplitChatPage 抽取的公共组件
/// 
/// 包含：
/// - 未读消息计数
/// - 排序模式按钮
/// - 升序/降序切换按钮
/// 
/// 更新记录：
/// - 2025-12-06: 从 ContactsPage/SplitChatPage 抽取，消除代码重复
/// - 2025-12-06: 接入皮肤系统
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/skin_provider.dart';
import '../../../../core/theme/tokens.dart';
import '../../providers2.dart';
import 'momotalk_sort_dialog.dart';

/// 联系人列表次级标题栏
class ContactsSubHeader extends ConsumerWidget {
  /// 搜索关键字（用于过滤计数）
  final String searchQuery;

  const ContactsSubHeader({
    super.key,
    this.searchQuery = '',
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final skin = context.skin;
    final colors = context.moeColors;
    final sortMode = ref.watch(sortModeProvider);
    final isAscending = ref.watch(sortAscendingProvider);
    final listAsync = ref.watch(conversationsProvider);
    
    final count = listAsync.maybeWhen(
      data: (list) {
        final q = searchQuery.trim().toLowerCase();
        if (q.isEmpty) return list.length;
        return list.where((c) => c.displayName.toLowerCase().contains(q)).length;
      },
      orElse: () => 0,
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(
          bottom: BorderSide(color: colors.divider, width: skin.borderWidth),
        ),
      ),
      child: Row(
        children: [
          Text(
            '未读消息 ($count)',
            style: TextStyle(
              color: colors.text,
              fontSize: 15,
              fontWeight: FontWeight.bold,
            ),
          ),
          const Spacer(),
          // 排序模式按钮
          Tooltip(
            message: '排序方式',
            child: GestureDetector(
              onTap: () => _showSortDialog(context, ref, sortMode),
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
                      sortMode == SortMode.latest ? '最新' : '名字',
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
          // 升序/降序切换按钮
          Tooltip(
            message: '切换顺序',
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () {
                  ref.read(sortAscendingProvider.notifier).state = !isAscending;
                },
                borderRadius: BorderRadius.circular(4),
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    border: Border.all(color: colors.divider),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Icon(
                    isAscending ? Icons.arrow_upward : Icons.arrow_downward,
                    size: 16,
                    color: colors.textSecondary,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showSortDialog(BuildContext context, WidgetRef ref, SortMode currentMode) {
    showDialog(
      context: context,
      builder: (context) => MomotalkSortDialog(
        currentMode: currentMode,
        onModeChanged: (mode) {
          ref.read(sortModeProvider.notifier).state = mode;
          // 切换模式时重置排序方向
          ref.read(sortAscendingProvider.notifier).state = mode == SortMode.name;
          Navigator.of(context).pop();
        },
      ),
    );
  }
}
