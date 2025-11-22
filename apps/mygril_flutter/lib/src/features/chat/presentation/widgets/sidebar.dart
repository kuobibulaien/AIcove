import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers2.dart';
import '../../domain/conversation.dart';
import '../../../../core/theme/tokens.dart';
import 'character_list_item.dart';

class Sidebar extends ConsumerWidget {
  final ValueChanged<Conversation> onTap;
  const Sidebar({super.key, required this.onTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final listAsync = ref.watch(conversationsProvider);
    return Container(
      width: 320,
      color: moeSurface,
      child: Column(
        children: [
          // MoeTalk 顶部导航栏样�?          Container(
            height: 64,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [moeHeaderGradientStart, moeHeaderGradientEnd],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: Row(
              children: [
                const Text(
                  'MyGril',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 22,
                    letterSpacing: 0.5,
                  ),
                ),
                const Spacer(),
                // 加号按钮 - 添加新角�?                Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () async {
                      final id = await ref.read(conversationsProvider.notifier).createNew();
                      ref.read(activeConversationIdProvider.notifier).state = id;
                    },
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      child: const Icon(Icons.add, color: Colors.white, size: 26),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: listAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('加载失败: $e')),
              data: (list) {
                if (list.isEmpty) {
                  return const Center(
                    child: Text(
                      '暂无会话',
                      style: TextStyle(color: moeMuted, fontSize: 14),
                    ),
                  );
                }
                // 隐藏滚动条但保留滚动功能
                return ScrollConfiguration(
                  behavior: ScrollConfiguration.of(context).copyWith(
                    scrollbars: false,
                  ),
                  child: ListView.builder(
                    padding: EdgeInsets.zero, // 去除默认内边距，贴靠分割�?                    itemCount: list.length,
                    itemBuilder: (context, index) {
                      final c = list[index];
                      final activeId = ref.watch(activeConversationIdProvider);
                      final isActive = c.id == activeId;

                      return CharacterListItem(
                        conversation: c,
                        isActive: isActive,
                        onTap: () => onTap(c),
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
