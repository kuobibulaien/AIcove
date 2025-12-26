/// 我的收藏页面 - 展示收藏的角色卡片
/// 
/// 功能：以网格形式展示用户收藏的角色
/// 
/// 更新记录：
/// - 2025-12-08: 从 role_card_page.dart 独立为单独文件
/// - 2025-12-07: 在 role_card_page.dart 中创建，使用展开动画跳转
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/widgets/expanding_page_route.dart';
import '../../../../core/widgets/frosted_glass_card.dart';
import '../../../../core/widgets/moe_app_bar.dart';
import '../../../../core/utils/data_image.dart';
import '../../domain/conversation.dart';
import '../../providers2.dart';
import 'character_detail_page.dart';

/// 我的收藏页面
class FavoritesPage extends ConsumerWidget {
  const FavoritesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.moeColors;
    final conversationsAsync = ref.watch(conversationsProvider);

    return Scaffold(
      appBar: MoeAppBar(
        title: '我的角色卡',
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios, color: colors.headerContentColor),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      backgroundColor: colors.surface,
      body: conversationsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载失败: $e')),
        data: (conversations) {
          final favorites = conversations.where((c) => c.isFavorite).toList();
          
          if (favorites.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.favorite_border, size: 64, color: colors.muted),
                  const SizedBox(height: 16),
                  Text('还没有收藏的角色', style: TextStyle(color: colors.textSecondary)),
                  const SizedBox(height: 8),
                  Text(
                    '长按角色卡片可以添加收藏',
                    style: TextStyle(color: colors.muted, fontSize: 13),
                  ),
                ],
              ),
            );
          }

          return GridView.builder(
            padding: const EdgeInsets.all(16),
            physics: const BouncingScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              childAspectRatio: 0.75,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
            ),
            itemCount: favorites.length,
            itemBuilder: (context, index) {
              final conv = favorites[index];
              return Builder(
                builder: (cardContext) {
                  return _FavoriteCard(
                    conversation: conv,
                    onTap: () {
                      Navigator.of(context).pushExpanding(
                        page: CharacterDetailPage(
                          conversationId: conv.id,
                          initialConversation: conv,
                          heroId: conv.id,
                        ),
                        sourceContext: cardContext,
                        sourceRadius: 16,
                      );
                    },
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}

/// 收藏卡片组件
class _FavoriteCard extends StatelessWidget {
  final Conversation conversation;
  final VoidCallback onTap;

  const _FavoriteCard({
    required this.conversation,
    required this.onTap,
  });

  ImageProvider? _getImageProvider() {
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

  @override
  Widget build(BuildContext context) {
    return FrostedGlassCard(
      imageProvider: _getImageProvider(),
      onTap: onTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 底部渐变遮罩
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 80,
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black.withOpacity(0.7),
                  ],
                ),
              ),
            ),
          ),
          // 角色名称
          Positioned(
            left: 12,
            right: 12,
            bottom: 12,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  conversation.displayName,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (conversation.personaPrompt.isNotEmpty)
                  Text(
                    conversation.personaPrompt,
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.white.withOpacity(0.8),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          // 收藏图标
          Positioned(
            top: 8,
            right: 8,
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.3),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.favorite, color: Colors.pinkAccent, size: 16),
            ),
          ),
        ],
      ),
    );
  }
}
