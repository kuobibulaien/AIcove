/// 角色卡页面 - 以海报网格形式展示和管理角色
/// 
/// 架构说明（遵循 DRY 原则）：
/// - RoleCardPage: 完整页面（带 AppBar），供窄屏模式使用
/// - RoleCardContent: 内容组件（无 AppBar），供宽屏模式嵌入使用
/// 
/// 重构记录：
/// - 2025-12-31: 拆分为多个组件文件，主页面精简至约180行
///   - 提取 CategorySection 分类区段组件
///   - 提取 HorizontalRoleCard 横向角色卡片组件
/// - 2025-12-08: 重构，抽取 GradientBlurCard 公共组件，FavoritesPage 独立成文件
/// - 2025-12-07: 顶部功能卡片改用展开动画跳转，新增 FavoritesPage 收藏页面
/// - 2025-12-07: 重构角色卡片样式，使用高斯模糊背景 + 缩小居中立绘 + 底部信息
/// - 2025-12-07: 所有组件圆角改用 SmoothClipRRect 实现 iOS 风格平滑圆角
/// - 2025-12-06: 使用 MoeAppBar 替换原有 AppBar 样式
/// - 2025-12-01: 创建角色卡页面，使用网格布局展示角色海报卡片
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/animations/expanding_page_route.dart';
import '../../../../ui/shared/effects/gradient_blur_card.dart';
import '../../../../ui/shared/widgets/moe_app_bar.dart';
import '../../../../ui/shared/widgets/moe_toast.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../features/chat/domain/conversation.dart';
import '../../../../features/chat/providers2.dart';
import '../widgets/category_section.dart';
import 'contact_edit_page.dart';
import 'favorites_page.dart';

/// 角色卡页面 - 带 AppBar 的完整页面（窄屏使用）
class RoleCardPage extends StatelessWidget {
  const RoleCardPage({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;

    return Scaffold(
      appBar: MoeAppBar(
        title: '发现',
        actions: [
          // 搜索按钮
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () => context.go('/contact/new'),
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding: const EdgeInsets.all(8),
                child: Icon(Icons.search, color: colors.headerContentColor, size: 26),
              ),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      backgroundColor: colors.surface,
      body: const RoleCardContent(),
    );
  }
}

/// 角色卡内容 - 分类横向列表布局
class RoleCardContent extends ConsumerWidget {
  const RoleCardContent({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.moeColors;
    final conversationsAsync = ref.watch(conversationsProvider);

    return conversationsAsync.when(
      loading: () => const Center(child: MoeLoadingIndicator()),
      error: (e, _) => Center(
        child: MoeEmptyState(
          icon: Icons.error_outline,
          title: '加载失败',
          description: '$e',
        ),
      ),
      data: (conversations) {
        if (conversations.isEmpty) {
          return _buildEmptyState(colors);
        }

        // 数据分组逻辑
        final favorites = conversations.where((c) => c.isFavorite).toList();
        final recent = List<Conversation>.from(conversations)
          ..sort((a, b) => (b.lastMessageTime ?? b.createdAt).compareTo(a.lastMessageTime ?? a.createdAt));
        final topRecent = recent.take(5).toList();

        return CustomScrollView(
          physics: const BouncingScrollPhysics(),
          slivers: [
            // 顶部功能入口
            SliverToBoxAdapter(
              child: _buildTopFunctionCards(context, favorites.length),
            ),

            // 我的角色卡（收藏的角色）
            if (favorites.isNotEmpty)
              SliverToBoxAdapter(
                child: CategorySection(title: '❤️ 我的角色卡', conversations: favorites),
              ),

            // 官方推荐（最近活跃）
            SliverToBoxAdapter(
              child: CategorySection(title: '✨ 官方推荐', conversations: topRecent),
            ),

            // 自由定义（全部角色）
            SliverToBoxAdapter(
              child: CategorySection(title: '🎨 自由定义', conversations: conversations),
            ),

            // 底部留白
            const SliverToBoxAdapter(child: SizedBox(height: 80)),
          ],
        );
      },
    );
  }

  Widget _buildTopFunctionCards(BuildContext context, int favoritesCount) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Row(
        children: [
          // 我的角色卡
          Expanded(
            child: Builder(
              builder: (cardContext) => GradientBlurCard(
                title: '我的角色卡',
                subtitle: favoritesCount > 0 ? '$favoritesCount 个收藏' : null,
                icon: Icons.favorite,
                iconColor: Colors.pinkAccent,
                onTap: () {
                  if (favoritesCount == 0) {
                    MoeToast.brief(context, '还没有收藏的角色哦~');
                  } else {
                    Navigator.of(context).pushExpanding(
                      page: const FavoritesPage(),
                      sourceContext: cardContext,
                      sourceRadius: 16,
                    );
                  }
                },
              ),
            ),
          ),
          const SizedBox(width: 12),
          // 定制角色卡
          Expanded(
            child: Builder(
              builder: (cardContext) => GradientBlurCard(
                title: '定制角色卡',
                icon: Icons.auto_awesome_outlined,
                iconColor: Colors.purpleAccent,
                onTap: () {
                  final now = DateTime.now();
                  Navigator.of(context).pushExpanding(
                    page: ContactEditPage(
                      conversation: Conversation(
                        id: 'new_${now.millisecondsSinceEpoch}',
                        title: '',
                        displayName: '',
                        createdAt: now,
                        updatedAt: now,
                      ),
                      isNew: true,
                    ),
                    sourceContext: cardContext,
                    sourceRadius: 16,
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(MoeColors colors) {
    return Center(
      child: MoeEmptyState(
        icon: Icons.style_outlined,
        title: '暂无角色',
        description: '点击右上角 + 创建新角色',
      ),
    );
  }
}
