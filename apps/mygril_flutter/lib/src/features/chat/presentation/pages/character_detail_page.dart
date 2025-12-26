import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/theme/tokens.dart';
import '../../../../core/utils/data_image.dart';
import '../../../../core/utils/role_transition_tags.dart';
import '../../../../core/utils/blurred_background_cache.dart';
import '../../../../core/widgets/frosted_glass_card.dart';
import '../../domain/conversation.dart';
import 'contact_edit_page.dart';
import '../../providers2.dart';
import '../../../../core/widgets/moe_toast.dart';
import '../widgets/contact_edit_dialog.dart';

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
class CharacterDetailPage extends ConsumerWidget {
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
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.moeColors;
    final screenSize = MediaQuery.of(context).size;
    final statusBarHeight = MediaQuery.of(context).padding.top;
    
    // 监听最新的会话列表，找到当前会话
    final conversationsAsync = ref.watch(conversationsProvider);
    final conversation = conversationsAsync.value?.firstWhere(
      (c) => c.id == conversationId, 
      orElse: () => initialConversation,
    ) ?? initialConversation;

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
                  
                  // 导航按钮行（左返回 + 中间名字 + 右编辑）
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        _buildCircleButton(
                          icon: Icons.arrow_back,
                          onTap: () => Navigator.of(context).pop(),
                        ),
                        const SizedBox(width: 12),
                        // 中间名字（Hero 落点）
                        Expanded(
                          child: Hero(
                            tag: RoleTransitionTags.name(heroId),
                            child: Material(
                              color: Colors.transparent,
                              child: Text(
                                conversation.displayName,
                                style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                  color: colors.text,
                                ),
                                textAlign: TextAlign.center,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        _buildCircleButton(
                          icon: Icons.edit,
                          onTap: () => _navigateToEdit(context, ref, conversation),
                        ),
                      ],
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

          // 4. 底部悬浮按钮区域 (收藏 + 开始聊天)
          Positioned(
            left: 24,
            right: 24,
            bottom: 32,
            child: _buildBottomButtons(context, ref, conversation),
          ),
        ],
      ),
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
    return Stack(
      fit: StackFit.expand,
      children: [
        Container(color: colors.surface),
        ValueListenableBuilder<int>(
          valueListenable: BlurredBackgroundCache.ticker,
          builder: (context, _, __) {
            final (bgProvider, __) = BlurredBackgroundCache.getOrFallback(
              conversation.id,
              imageProvider,
            );
            return Image(
              image: bgProvider,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              filterQuality: FilterQuality.medium,
            );
          },
        ),
        // 轻微玻璃提亮/压暗（与卡片一致）
        Container(
          color: isDark
              ? Colors.black.withValues(alpha: 0.25)
              : Colors.white.withValues(alpha: 0.22),
        ),
      ],
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

  /// 角色立绘展示（无阴影）
  Widget _buildCharacterImage(BuildContext context, Conversation conversation, Size screenSize) {
    final maxHeight = screenSize.height * 0.5;

    return Hero(
      tag: RoleTransitionTags.image(heroId),
      child: Container(
        constraints: BoxConstraints(
          maxWidth: screenSize.width * 0.75,
          maxHeight: maxHeight,
        ),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
        ),
        child: _buildImageContent(context, conversation, fit: BoxFit.contain),
      ),
    );
  }

  /// 简介框（独立 Hero，无阴影）
  Widget _buildInfoCard(BuildContext context, Conversation conversation) {
    final colors = context.moeColors;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Hero(
        tag: RoleTransitionTags.intro(heroId),
        child: Material(
          color: Colors.transparent,
          child: FrostedGlassContainer(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 称呼标签
                if (conversation.addressUser != null && conversation.addressUser!.isNotEmpty) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: colors.primary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(20),
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
                // 简介内容
                Text(
                  conversation.personaPrompt.isNotEmpty
                      ? conversation.personaPrompt
                      : '这个角色还没有设定详细的简介哦~\n点击右上角编辑按钮来完善 TA 的故事吧',
                  style: TextStyle(
                    fontSize: 15,
                    height: 1.6,
                    color: colors.text.withValues(alpha: 0.9),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 底部按钮区域（收藏 + 开始聊天）
  Widget _buildBottomButtons(BuildContext context, WidgetRef ref, Conversation conversation) {
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
            onTap: () => _toggleFavorite(context, ref, conversation),
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
          child: SizedBox(
            height: 56,
            child: ElevatedButton.icon(
              onPressed: () => _navigateToChat(context, conversation),
              style: ElevatedButton.styleFrom(
                backgroundColor: colors.primary,
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(28),
                ),
              ),
              icon: const Icon(Icons.chat_bubble_outline),
              label: const Text(
                '开始聊天',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 切换收藏状态
  Future<void> _toggleFavorite(BuildContext context, WidgetRef ref, Conversation conversation) async {
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
        return Image.memory(charBytes, fit: fit);
      }
      return Image.asset(
        charImage,
        fit: fit,
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
        return Image.memory(avatarBytes, fit: fit);
      }
      if (avatar.startsWith('http')) {
        return Image.network(avatar, fit: fit);
      }
      return Image.asset(
        avatar,
        fit: fit,
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
    context.go('/chat/${conversation.id}');
  }

  Future<void> _navigateToEdit(BuildContext context, WidgetRef ref, Conversation conversation) async {
    final result = await Navigator.of(context).push<ContactEditResult>(
      MaterialPageRoute(
        builder: (context) => ContactEditPage(conversation: conversation),
      ),
    );

    if (result != null) {
      await ref.read(conversationsProvider.notifier).applyContactEdit(
        conversation.id,
        displayName: result.displayName,
        avatarUrl: result.avatarUrl,
        characterImage: result.characterImage,
        addressUser: result.addressUser,
        personaPrompt: result.personaPrompt,
      );
      if (context.mounted) {
        MoeToast.brief(context, '已保存角色信息');
      }
    }
  }
}
