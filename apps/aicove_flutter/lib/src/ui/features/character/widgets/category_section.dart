/// CategorySection - 角色分类区段组件
///
/// 从 role_card_page.dart 提取，显示一个角色分类的横向列表。
///
/// 更新记录：
/// - 2025-12-31: 从 role_card_page.dart 提取
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../ui/theme/tokens.dart';
import '../../../../features/chat/domain/conversation.dart';
import 'horizontal_role_card.dart';

/// 分类区段组件
class CategorySection extends ConsumerWidget {
  final String title;
  final List<Conversation> conversations;

  const CategorySection({
    super.key,
    required this.title,
    required this.conversations,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.moeColors;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 标题栏
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: MoeFontWeights.emphasis,
                  color: colors.text,
                ),
              ),
            ],
          ),
        ),
        // 横向列表 - 使用 LayoutBuilder 获取实际可用宽度
        LayoutBuilder(
          builder: (context, constraints) {
            // 计算卡片宽度：容器宽度 - 左边距(16) - 间距(12) - 露出部分(20)
            final availableWidth = constraints.maxWidth;
            final cardWidth = (availableWidth - 48).clamp(280.0, 400.0);

            return SizedBox(
              height: 200, // 卡片高度
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                itemCount: conversations.length,
                separatorBuilder: (_, __) => const SizedBox(width: 12),
                itemBuilder: (context, index) {
                  final conv = conversations[index];
                  final heroId = '${conv.id}_${title}_$index';
                  return HorizontalRoleCard(
                    key: ValueKey(conv.id),
                    conversation: conv,
                    cardWidth: cardWidth,
                    heroId: heroId,
                  );
                },
              ),
            );
          },
        ),
        const SizedBox(height: 12),
      ],
    );
  }
}
