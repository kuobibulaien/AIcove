/// 角色卡页面 - 以海报网格形式展示和管理角色
/// 
/// 架构说明（遵循 DRY 原则）：
/// - RoleCardPage: 完整页面（带 AppBar），供窄屏模式使用
/// - RoleCardContent: 内容组件（无 AppBar），供宽屏模式嵌入使用
/// 
/// 更新记录：
/// - 2025-12-08: 重构，抽取 GradientBlurCard 公共组件，FavoritesPage 独立成文件
/// - 2025-12-07: 顶部功能卡片改用展开动画跳转，新增 FavoritesPage 收藏页面
/// - 2025-12-07: 重构角色卡片样式，使用高斯模糊背景 + 缩小居中立绘 + 底部信息
/// - 2025-12-07: 所有组件圆角改用 SmoothClipRRect 实现 iOS 风格平滑圆角
/// - 2025-12-06: 使用 MoeAppBar 替换原有 AppBar 样式
/// - 2025-12-01: 创建角色卡页面，使用网格布局展示角色海报卡片
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/widgets/expanding_page_route.dart';
import '../../../../core/widgets/frosted_glass_card.dart';
import '../../../../core/widgets/gradient_blur_card.dart';
import '../../../../core/widgets/moe_app_bar.dart';
import '../../../../core/widgets/smooth_clip.dart';
import '../../../../core/widgets/moe_toast.dart';
import '../../../../core/utils/data_image.dart';
import '../../../../core/utils/blurred_background_cache.dart';
import '../../../../core/utils/role_transition_tags.dart';
import '../../domain/conversation.dart';
import '../../providers2.dart';
import 'contact_edit_page.dart';
import 'character_detail_page.dart';
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
          // 新建角色按钮
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
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('加载失败: $e')),
      data: (conversations) {
        if (conversations.isEmpty) {
          return _buildEmptyState(colors);
        }

        // 数据分组逻辑
        final favorites = conversations.where((c) => c.isFavorite).toList();
        final recent = List<Conversation>.from(conversations)
          ..sort((a, b) => (b.lastMessageTime ?? b.createdAt)
              .compareTo(a.lastMessageTime ?? a.createdAt));
        final topRecent = recent.take(5).toList(); // 取前5个最近活跃

        return CustomScrollView(
          physics: const BouncingScrollPhysics(),
          slivers: [
            // 0. 顶部功能入口
            SliverToBoxAdapter(
              child: _buildTopFunctionCards(context, favorites.length),
            ),

            // 1. 我的角色卡（收藏的角色）- 只在有收藏时显示
            if (favorites.isNotEmpty)
              SliverToBoxAdapter(
                child: CategorySection(
                  title: '❤️ 我的角色卡',
                  conversations: favorites,
                ),
              ),

            // 2. 官方推荐（最近活跃）
            SliverToBoxAdapter(
              child: CategorySection(
                title: '✨ 官方推荐',
                conversations: topRecent,
              ),
            ),

            // 3. 自由定义（全部角色）
            SliverToBoxAdapter(
              child: CategorySection(
                title: '🎨 自由定义',
                conversations: conversations,
              ),
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
          // 我的角色卡 - 使用 Builder 获取卡片 context 用于展开动画
          Expanded(
            child: Builder(
              builder: (cardContext) => _buildFunctionCard(
                cardContext,
                title: '我的角色卡',
                subtitle: favoritesCount > 0 ? '$favoritesCount 个收藏' : null,
                icon: Icons.favorite,
                color: Colors.pinkAccent,
                onTap: () {
                  if (favoritesCount == 0) {
                    MoeToast.brief(context, '还没有收藏的角色哦~');
                  } else {
                    // 使用展开动画跳转到收藏页面
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
          // 定制角色卡 - 使用 Builder 获取卡片 context 用于展开动画
          Expanded(
            child: Builder(
              builder: (cardContext) => _buildFunctionCard(
                cardContext,
                title: '定制角色卡',
                icon: Icons.auto_awesome_outlined,
                color: Colors.purpleAccent,
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

  /// 使用公共组件 GradientBlurCard 构建功能入口卡片
  Widget _buildFunctionCard(
    BuildContext context, {
    required String title,
    String? subtitle,
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GradientBlurCard(
      title: title,
      subtitle: subtitle,
      icon: icon,
      iconColor: color,
      onTap: onTap,
    );
  }

  Widget _buildEmptyState(MoeColors colors) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.style_outlined, size: 64, color: colors.textSecondary),
          const SizedBox(height: 16),
          Text('暂无角色', style: TextStyle(color: colors.textSecondary)),
          const SizedBox(height: 8),
          Text(
            '点击右上角 + 创建新角色',
            style: TextStyle(color: colors.muted, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

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
                  fontWeight: FontWeight.bold,
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

/// 横向角色卡片 - 左图右文风格 + 背景 Hero 动效
/// 使用 ExpandingPageRoute 实现无缝展开动画
class HorizontalRoleCard extends StatefulWidget {
  final Conversation conversation;
  final double cardWidth;
  final String heroId;

  const HorizontalRoleCard({
    super.key,
    required this.conversation,
    required this.cardWidth,
    required this.heroId,
  });

  @override
  State<HorizontalRoleCard> createState() => _HorizontalRoleCardState();
}

class _HorizontalRoleCardState extends State<HorizontalRoleCard> {
  @override
  void initState() {
    super.initState();
    // 预热模糊背景缓存
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final imageProvider = _getImageProvider();
      if (imageProvider != null && mounted) {
        BlurredBackgroundCache.warm(widget.conversation.id, imageProvider, context);
      }
    });
  }

  /// 获取图片 Provider（用于背景 Hero）
  ImageProvider? _getImageProvider() {
    final charImage = widget.conversation.characterImage;
    if (charImage != null && charImage.isNotEmpty) {
      final charBytes = decodeDataImage(charImage);
      if (charBytes != null) return MemoryImage(charBytes);
      return AssetImage(charImage);
    }

    final avatar = widget.conversation.avatarUrl;
    if (avatar != null && avatar.isNotEmpty) {
      final avatarBytes = decodeDataImage(avatar);
      if (avatarBytes != null) return MemoryImage(avatarBytes);
      if (avatar.startsWith('http')) return NetworkImage(avatar);
      return AssetImage(avatar);
    }
    return null;
  }

  /// 导航到详情页（使用 ExpandingPageRoute 无缝展开）
  void _navigateToDetail() {
    // 使用当前 widget 的 context 获取卡片位置
    final sourceRect = getSourceRect(context);
    Navigator.of(context).push(
      ExpandingPageRoute(
        page: CharacterDetailPage(
          conversationId: widget.conversation.id,
          initialConversation: widget.conversation,
          heroId: widget.heroId,
        ),
        sourceRect: sourceRect,
        sourceRadius: 16,
        targetRadius: 0,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final imageProvider = _getImageProvider();

    return SizedBox(
      width: widget.cardWidth,
      child: SmoothClipRRect(
        radius: 16,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => _navigateToDetail(),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 1. 背景（静态模糊图，无 BackdropFilter）
                if (imageProvider != null)
                  ValueListenableBuilder<int>(
                    valueListenable: BlurredBackgroundCache.ticker,
                    builder: (context, _, __) {
                      final (bgProvider, __) = BlurredBackgroundCache.getOrFallback(
                        widget.conversation.id,
                        imageProvider,
                      );
                      return Image(
                        image: bgProvider,
                        fit: BoxFit.cover,
                        filterQuality: FilterQuality.medium,
                      );
                    },
                  )
                else
                  Container(color: isDark ? const Color(0xFF1E1E1E) : Colors.grey[200]),

                // 2. 轻微玻璃提亮/压暗（和详情页保持一致，避免“外边太透”）
                Container(
                  color: isDark
                      ? Colors.black.withValues(alpha: 0.25)
                      : Colors.white.withValues(alpha: 0.22),
                ),

                // 3. 描边
                Container(
                  foregroundDecoration: SmoothRectDecoration(
                    radius: 16,
                    border: Border.all(
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.18)
                          : Colors.grey.shade400.withValues(alpha: 0.35),
                      width: 1,
                    ),
                  ),
                ),

                // 4. 内容层
                Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // 左侧海报 (flex 4)
                    Expanded(
                      flex: 4,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Center(
                          child: AspectRatio(
                            aspectRatio: 3 / 4,
                            child: Hero(
                              tag: RoleTransitionTags.image(widget.heroId),
                              child: SmoothClipRRect(
                                radius: 12,
                                child: _buildImage(context),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    // 右侧信息区 (flex 6)
                    Expanded(
                      flex: 6,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(0, 16, 16, 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // 名字（带 Hero）
                            Hero(
                              tag: RoleTransitionTags.name(widget.heroId),
                              child: Material(
                                color: Colors.transparent,
                                child: Text(
                                  widget.conversation.displayName,
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold,
                                    color: colors.text,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            // 简介气泡（带 Hero）
                            Expanded(
                              child: Hero(
                                tag: RoleTransitionTags.intro(widget.heroId),
                                child: Material(
                                  color: Colors.transparent,
                                  child: SizedBox(
                                    width: double.infinity,
                                    child: FrostedGlassContainer(
                                      padding: const EdgeInsets.all(12),
                                      child: Text(
                                        widget.conversation.personaPrompt.isNotEmpty
                                            ? widget.conversation.personaPrompt
                                            : (widget.conversation.lastMessage ?? '暂无介绍'),
                                        style: TextStyle(
                                          fontSize: 14,
                                          height: 1.4,
                                          color: colors.text.withValues(alpha: 0.9),
                                        ),
                                        maxLines: 4,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildImage(BuildContext context, {BoxFit fit = BoxFit.cover}) {
    final charImage = widget.conversation.characterImage;
    if (charImage != null && charImage.isNotEmpty) {
      final charBytes = decodeDataImage(charImage);
      if (charBytes != null) return Image.memory(charBytes, fit: fit);
      return Image.asset(charImage, fit: fit,
        errorBuilder: (_, __, ___) => _buildFallback(),
      );
    }

    final avatar = widget.conversation.avatarUrl;
    if (avatar != null && avatar.isNotEmpty) {
      final avatarBytes = decodeDataImage(avatar);
      if (avatarBytes != null) return Image.memory(avatarBytes, fit: fit);
      if (avatar.startsWith('http')) return Image.network(avatar, fit: fit);
      return Image.asset(avatar, fit: fit,
        errorBuilder: (_, __, ___) => _buildFallback(),
      );
    }
    return _buildFallback();
  }

  Widget _buildFallback() {
    return Container(
      color: Colors.grey[300],
      child: const Center(
        child: Icon(Icons.person, color: Colors.white, size: 40),
      ),
    );
  }
}
