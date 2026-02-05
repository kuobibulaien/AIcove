import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../core/utils/data_image.dart';
import '../../../../core/utils/role_transition_tags.dart';
import '../../../../core/utils/blurred_background_cache.dart';
import '../../../../ui/shared/animations/parallax_slide_page_route.dart';
import '../../../../ui/shared/effects/frosted_glass_card.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../features/chat/domain/conversation.dart';
import 'contact_edit_page.dart';
import '../../../../features/chat/providers2.dart';
import '../../../../ui/shared/widgets/moe_toast.dart';
import '../../../../features/chat/presentation/widgets/contact_edit_dialog.dart';

/// 角色详情页面
/// 
/// 设计说明：
/// - 全局高斯模糊背景（固定不动）
/// - 内容区域作为普通列表整体滚动（像看漫画一样）
/// - 底部悬浮"开始聊天"按钮
/// 
/// 更新记录：
/// - 2025-12-07: 创建角色详情页，使用沉浸式布局
/// - 2025-12-07: 优化为漫画式滚动体验，全局模糊背景固定
class CharacterDetailPage extends ConsumerStatefulWidget {
  final String conversationId;
  final Conversation initialConversation;
  final String heroId;

  const CharacterDetailPage({
    super.key, 
    required this.conversationId,
    required this.initialConversation,
    required this.heroId,
  });

  @override
  ConsumerState<CharacterDetailPage> createState() => _CharacterDetailPageState();
}

class _CharacterDetailPageState extends ConsumerState<CharacterDetailPage> {
  Animation<double>? _routeAnimation;
  bool _blurWarmupScheduled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    final animation = ModalRoute.of(context)?.animation;
    if (_routeAnimation == animation) return;

    _routeAnimation?.removeStatusListener(_onRouteAnimationStatus);
    _routeAnimation = animation;
    _routeAnimation?.addStatusListener(_onRouteAnimationStatus);

    // 某些场景下 animation 可能为空或已结束（如直接展示/热重载）。此时直接安排一次预热。
    if (animation == null || animation.status == AnimationStatus.completed) {
      _scheduleBlurWarmupAfterTransition();
    }
  }

  @override
  void dispose() {
    _routeAnimation?.removeStatusListener(_onRouteAnimationStatus);
    super.dispose();
  }

  void _onRouteAnimationStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      _scheduleBlurWarmupAfterTransition();
    }
  }

  void _scheduleBlurWarmupAfterTransition() {
    if (_blurWarmupScheduled) return;
    _blurWarmupScheduled = true;

    // 关键：不要在转场动画中做“生成模糊图”这种重活。
    // 等动画结束后，下一帧再开始，避免掉帧。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      final blurAsset = _deriveBlurAssetPath(widget.initialConversation.characterImage);
      if (blurAsset != null) return; // 有预制模糊图就不用生成

      final imageProvider = _getImageProvider(widget.initialConversation);
      if (imageProvider == null) return;

      BlurredBackgroundCache.warm(widget.conversationId, imageProvider, context);
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final screenSize = MediaQuery.sizeOf(context);
    final statusBarHeight = MediaQuery.paddingOf(context).top;

    // 监听最新的会话列表，找到当前会话
    final conversationsAsync = ref.watch(conversationsProvider);
    final conversation = conversationsAsync.value?.firstWhere(
      (c) => c.id == widget.conversationId,
      orElse: () => widget.initialConversation,
    ) ?? widget.initialConversation;

    // 获取路由动画（用于按钮淡入淡出）
    final routeAnimation = _routeAnimation ?? ModalRoute.of(context)?.animation;

    return Scaffold(
      backgroundColor: colors.surface,
      body: Stack(
        children: [
          // 1. 背景（静态模糊图，无遮罩/无实时滤镜）
          Positioned.fill(
            child: _buildBackground(context, conversation),
          ),

          // 2. 可滚动内容区（像看漫画一样整体滚动）
          Positioned.fill(
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              child: Column(
                children: [
                  // 顶部安全区 + 导航按钮区域
                  SizedBox(height: statusBarHeight + 16),

                  // 导航按钮行（左返回 + 中间名字 + 右编辑）- 带淡入淡出
                  _buildFadeInWidget(
                    animation: routeAnimation,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          _buildCircleButton(
                            icon: Icons.arrow_back,
                            onTap: () => Navigator.of(context).pop(),
                          ),
                          const SizedBox(width: 12),
                          // 中间名字（静态显示，无动画）
                          Expanded(
                            child: Text(
                              conversation.displayName,
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w900,
                                color: colors.text,
                              ),
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 12),
                          _buildCircleButton(
                            icon: Icons.edit,
                            onTap: () => _navigateToEdit(context, conversation),
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 32),

                  // 角色立绘（居中展示）
                  _buildCharacterImage(context, conversation, screenSize),

                  const SizedBox(height: 32),

                  // 角色信息卡片
                  _buildInfoCard(context, conversation),

                  // 底部留白（给悬浮按钮让位）
                  const SizedBox(height: 120),
                ],
              ),
            ),
          ),

          // 4. 底部悬浮按钮区域 (收藏 + 开始聊天) - 带淡入淡出
          Positioned(
            left: 24,
            right: 24,
            bottom: 32,
            child: _buildFadeInWidget(
              animation: routeAnimation,
              child: _buildBottomButtons(context, conversation),
            ),
          ),
        ],
      ),
    );
  }

  /// 构建淡入淡出包装器
  /// 按钮在动画后半段（50%→100%）淡入，前半段（100%→50%）淡出
  Widget _buildFadeInWidget({
    required Animation<double>? animation,
    required Widget child,
  }) {
    if (animation == null) return child;

    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        // 将动画值 0.5-1.0 映射到 0.0-1.0
        final opacity = ((animation.value - 0.5) * 2).clamp(0.0, 1.0);
        return Opacity(
          opacity: opacity,
          child: child,
        );
      },
    );
  }

  /// 圆形按钮（返回/编辑）
  Widget _buildCircleButton({
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.black38,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          width: 44,
          height: 44,
          alignment: Alignment.center,
          child: Icon(icon, color: Colors.white, size: 22),
        ),
      ),
    );
  }

  /// 背景（使用静态模糊图，无遮罩）
  Widget _buildBackground(BuildContext context, Conversation conversation) {
    final colors = context.moeColors;
    final imageProvider = _getImageProvider(conversation);
    if (imageProvider == null) {
      return Container(color: colors.surface);
    }

    final blurAsset = _deriveBlurAssetPath(conversation.characterImage);

    return Stack(
      fit: StackFit.expand,
      children: [
        Container(color: colors.surface),
        if (blurAsset != null)
          Image.asset(
            blurAsset,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            filterQuality: FilterQuality.medium,
            errorBuilder: (_, __, ___) => _buildGeneratedBackgroundImage(
              context,
              conversation.id,
              imageProvider,
            ),
          )
        else
          _buildGeneratedBackgroundImage(context, conversation.id, imageProvider),
        // 轻微玻璃提亮/压暗（与卡片一致）
        Builder(builder: (context) {
          final isDark = Theme.of(context).brightness == Brightness.dark;
          return Container(
            color: isDark
                ? Colors.black.withValues(alpha: 0.25)
                : Colors.white.withValues(alpha: 0.22),
          );
        }),
      ],
    );
  }

  String? _deriveBlurAssetPath(String? originalAssetPath) {
    if (originalAssetPath == null) return null;
    final trimmed = originalAssetPath.trim();
    if (!trimmed.startsWith('assets/')) return null;
    final dot = trimmed.lastIndexOf('.');
    if (dot <= 0) return null;
    return '${trimmed.substring(0, dot)}_blur${trimmed.substring(dot)}';
  }

  Widget _buildGeneratedBackgroundImage(
    BuildContext context,
    String conversationId,
    ImageProvider imageProvider,
  ) {
    return ValueListenableBuilder<int>(
      valueListenable: BlurredBackgroundCache.ticker,
      builder: (context, _, unused) {
        final (bgProvider, isFallback) = BlurredBackgroundCache.getOrFallback(
          conversationId,
          imageProvider,
        );

        // 兜底策略：如果静态模糊图还没就绪，用“低分辨率放大”模拟模糊感。
        // 这样比实时 ImageFilter.blur 更省 GPU/更不容易在转场时掉帧。
        final displayProvider = isFallback
            ? ResizeImage(
                bgProvider,
                width: 96,
                height: 96,
                policy: ResizeImagePolicy.fit,
              )
            : bgProvider;

        final baseImage = Image(
          image: displayProvider,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          filterQuality: isFallback ? FilterQuality.none : FilterQuality.medium,
        );

        if (isFallback) {
          // 放大一点避免边缘留白
          return Transform.scale(scale: 1.2, child: baseImage);
        }

        return baseImage;
      },
    );
  }

  /// 获取图片 Provider
  ImageProvider? _getImageProvider(Conversation conversation) {
    final charImage = conversation.characterImage;
    if (charImage != null && charImage.isNotEmpty) {
      final charBytes = decodeDataImage(charImage);
      if (charBytes != null) return MemoryImage(charBytes);
      return AssetImage(charImage);
    }

    final avatar = conversation.avatarUrl;
    if (avatar != null && avatar.isNotEmpty) {
      final avatarBytes = decodeDataImage(avatar);
      if (avatarBytes != null) return MemoryImage(avatarBytes);
      if (avatar.startsWith('http')) return NetworkImage(avatar);
      return AssetImage(avatar);
    }
    return null;
  }

  /// 角色立绘展示（将 Hero 移入 AspectRatio 内部，确保 Hero 的内容比例恒定为 3:4，解决形变问题）
  Widget _buildCharacterImage(BuildContext context, Conversation conversation, Size screenSize) {
    return Center(
      child: Container(
        constraints: const BoxConstraints(
          maxWidth: 200,
        ),
        child: AspectRatio(
          aspectRatio: 3 / 4,
          child: Hero(
            tag: RoleTransitionTags.image(widget.heroId),
            child: MoeG2ClipRRect(
              radius: 16,
              child: _buildImageContent(context, conversation, fit: BoxFit.cover),
            ),
          ),
        ),
      ),
    );
  }

  /// 信息卡片区域（简介 + 人格设定）
  Widget _buildInfoCard(BuildContext context, Conversation conversation) {
    final colors = context.moeColors;
    final hasDescription = conversation.description != null && conversation.description!.isNotEmpty;
    final hasPersona = conversation.personaPrompt.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 称呼标签
          if (conversation.addressUser != null && conversation.addressUser!.isNotEmpty) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: MoeG2Decoration(
                radius: 20,
                color: colors.primary.withValues(alpha: 0.1),
                border: Border.all(
                  color: colors.primary.withValues(alpha: 0.2),
                ),
              ),
              child: Text(
                '称呼我为「${conversation.addressUser}」',
                style: TextStyle(
                  color: colors.primary,
                  fontWeight: FontWeight.w500,
                  fontSize: 14,
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],

          // 简介卡片（Hero 动画）
          Hero(
            tag: RoleTransitionTags.intro(widget.heroId),
            child: Material(
              type: MaterialType.transparency,
              child: SizedBox(
                width: double.infinity,
                child: FrostedGlassContainer(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    hasDescription
                        ? conversation.description!
                        : (hasPersona ? conversation.personaPrompt : '暂无简介'),
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.4,
                      color: colors.text.withValues(alpha: 0.9),
                    ),
                    maxLines: hasDescription ? null : 4,
                    overflow: hasDescription ? null : TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
          ),

          // 人格设定区域（仅当有独立简介时才显示提示词）
          if (hasDescription && hasPersona) ...[
            const SizedBox(height: 20),
            // 分隔标题
            Row(
              children: [
                Icon(Icons.auto_awesome, size: 16, color: colors.muted),
                const SizedBox(width: 6),
                Text(
                  '人格设定',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: colors.muted,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            // 提示词内容
            FrostedGlassContainer(
              padding: const EdgeInsets.all(16),
              child: Text(
                conversation.personaPrompt,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  color: colors.text.withValues(alpha: 0.8),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 底部按钮区域（收藏 + 开始聊天）
  Widget _buildBottomButtons(BuildContext context, Conversation conversation) {
    final colors = context.moeColors;
    final isFavorite = conversation.isFavorite;
    
    return Row(
      children: [
        // 收藏按钮
        Material(
          color: isFavorite ? colors.primary : colors.surface,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => _toggleFavorite(context, conversation),
            child: Container(
              width: 56,
              height: 56,
              alignment: Alignment.center,
              child: Icon(
                isFavorite ? Icons.favorite : Icons.favorite_border,
                color: isFavorite ? Colors.white : colors.primary,
                size: 26,
              ),
            ),
          ),
        ),
        
        const SizedBox(width: 16),
        
        // 开始聊天按钮
        Expanded(
          child: MoeG2ClipRRect(
            radius: 28,
            child: SizedBox(
              height: 56,
              child: ElevatedButton.icon(
                onPressed: () => _navigateToChat(context, conversation),
                style: ElevatedButton.styleFrom(
                  backgroundColor: colors.primary,
                  foregroundColor: Colors.white,
                  elevation: 0,
                ),
                icon: const Icon(Icons.chat_bubble_outline),
                label: const Text(
                  '开始聊天',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 切换收藏状态
  Future<void> _toggleFavorite(BuildContext context, Conversation conversation) async {
    final newFavorite = !conversation.isFavorite;
    await ref.read(conversationsProvider.notifier).updateConversationSettings(
      conversation.id,
      isFavorite: newFavorite,
    );
    if (context.mounted) {
      MoeToast.brief(context, newFavorite ? '已添加到我的角色卡 ❤️' : '已从我的角色卡移除');
    }
  }

  Widget _buildImageContent(BuildContext context, Conversation conversation, {BoxFit fit = BoxFit.cover}) {
    final charImage = conversation.characterImage;
    if (charImage != null && charImage.isNotEmpty) {
      final charBytes = decodeDataImage(charImage);
      if (charBytes != null) {
        return Image.memory(charBytes, fit: fit, gaplessPlayback: true);
      }
      return Image.asset(
        charImage,
        fit: fit,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => _buildAvatarFallback(context, conversation, fit),
      );
    }
    return _buildAvatarFallback(context, conversation, fit);
  }

  Widget _buildAvatarFallback(BuildContext context, Conversation conversation, BoxFit fit) {
    final avatar = conversation.avatarUrl;
    if (avatar != null && avatar.isNotEmpty) {
      final avatarBytes = decodeDataImage(avatar);
      if (avatarBytes != null) {
        return Image.memory(avatarBytes, fit: fit, gaplessPlayback: true);
      }
      if (avatar.startsWith('http')) {
        return Image.network(avatar, fit: fit, gaplessPlayback: true);
      }
      return Image.asset(
        avatar,
        fit: fit,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => Container(color: Colors.grey[200]),
      );
    }
    return Container(
      color: Colors.grey[200],
      child: const Center(
        child: Icon(Icons.person, size: 80, color: Colors.grey),
      ),
    );
  }

  void _navigateToChat(BuildContext context, Conversation conversation) {
    // 进入聊天页前先把“当前会话”设好，避免新页面首帧先渲染到默认会话再跳到目标会话
    ref.read(activeConversationIdProvider.notifier).state = conversation.id;
    context.go('/chat/${conversation.id}', extra: conversation);
  }

  Future<void> _navigateToEdit(BuildContext context, Conversation conversation) async {
    final result = await Navigator.of(context).push<ContactEditResult>(
      ParallaxSlidePageRoute(
        page: ContactEditPage(
          conversation: conversation,
          editMode: EditMode.editConversation,
        ),
      ),
    );

    if (result != null) {
      await ref.read(conversationsProvider.notifier).applyContactEdit(
        conversation.id,
        displayName: result.displayName,
        avatarUrl: result.avatarUrl,
        characterImage: result.characterImage,
        addressUser: result.addressUser,
        description: result.description,
        personaPrompt: result.personaPrompt,
      );
      if (context.mounted) {
        MoeToast.brief(context, '已保存角色信息');
      }
    }
  }
}
