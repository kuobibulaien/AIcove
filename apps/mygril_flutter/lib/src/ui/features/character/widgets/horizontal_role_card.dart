/// HorizontalRoleCard - 横向角色卡片组件
/// 
/// 从 role_card_page.dart 提取，显示左图右文风格的角色卡片。
/// 使用 ExpandingPageRoute 实现无缝展开动画。
/// 
/// 更新记录：
/// - 2025-12-31: 从 role_card_page.dart 提取
library;

import 'package:flutter/material.dart';

import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/animations/expanding_page_route.dart';
import '../../../../ui/shared/effects/frosted_glass_card.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../core/utils/data_image.dart';
import '../../../../core/utils/blurred_background_cache.dart';
import '../../../../core/utils/role_transition_tags.dart';
import '../../../../features/chat/domain/conversation.dart';
import '../pages/character_detail_page.dart';

/// 横向角色卡片 - 左图右文风格 + 背景 Hero 动效
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
            onTap: _navigateToDetail,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 1. 背景（静态模糊图，无 BackdropFilter）
                if (imageProvider != null)
                  ValueListenableBuilder<int>(
                    valueListenable: BlurredBackgroundCache.ticker,
                    builder: (context, _, unused) {
                      final (bgProvider, _) = BlurredBackgroundCache.getOrFallback(
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

                // 2. 轻微玻璃提亮/压暗
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
      return Image.asset(
        charImage,
        fit: fit,
        errorBuilder: (_, __, ___) => _buildFallback(),
      );
    }

    final avatar = widget.conversation.avatarUrl;
    if (avatar != null && avatar.isNotEmpty) {
      final avatarBytes = decodeDataImage(avatar);
      if (avatarBytes != null) return Image.memory(avatarBytes, fit: fit);
      if (avatar.startsWith('http')) return Image.network(avatar, fit: fit);
      return Image.asset(
        avatar,
        fit: fit,
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
