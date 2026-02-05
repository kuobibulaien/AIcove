/// HorizontalRoleCard - 横向角色卡片组件
/// 
/// 从 role_card_page.dart 提取，显示左图右文风格的角色卡片。
/// 使用 ExpandingPageRoute 实现无缝展开动画。
/// 
/// 更新记录：
/// - 2025-12-31: 从 role_card_page.dart 提取
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/animations/expanding_page_route.dart';
import '../../../../ui/shared/effects/frosted_glass_card.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../core/utils/data_image.dart';
import '../../../../core/utils/blurred_background_manager.dart';
import '../../../../core/utils/image_preheat_queue.dart';
import '../../../../core/utils/role_transition_tags.dart';
import '../../../../features/chat/domain/conversation.dart';
import '../pages/character_detail_page.dart';

/// 横向角色卡片 - 左图右文风格 + 背景 Hero 动效
class HorizontalRoleCard extends ConsumerStatefulWidget {
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
  ConsumerState<HorizontalRoleCard> createState() => _HorizontalRoleCardState();
}

class _HorizontalRoleCardState extends ConsumerState<HorizontalRoleCard> {
  ImageProvider? _blurredBackgroundProvider;

  @override
  void initState() {
    super.initState();
    _loadBlurredBackground();
  }

  /// 加载或生成模糊背景
  Future<void> _loadBlurredBackground() async {
    final blurAsset = _deriveBlurAssetPath(widget.conversation.characterImage);
    if (blurAsset != null) {
      try {
        await rootBundle.load(blurAsset);
        if (mounted) {
          setState(() {
            _blurredBackgroundProvider = AssetImage(blurAsset);
          });
        }
        return;
      } catch (_) {
        // 没有预制模糊图，继续走“生成模糊图”的逻辑
      }
    }

    final imageBytes = await _getImageBytes();
    if (imageBytes == null) return;

    final path = await BlurredBackgroundManager.getOrGenerate(imageBytes);
    if (mounted && path != null) {
      setState(() {
        _blurredBackgroundProvider = FileImage(File(path));
      });
    }
  }

  String? _deriveBlurAssetPath(String? originalAssetPath) {
    if (originalAssetPath == null) return null;
    final trimmed = originalAssetPath.trim();
    if (!trimmed.startsWith('assets/')) return null;
    final dot = trimmed.lastIndexOf('.');
    if (dot <= 0) return null;
    return '${trimmed.substring(0, dot)}_blur${trimmed.substring(dot)}';
  }

  /// 获取图片字节（支持 base64 和 asset）
  Future<Uint8List?> _getImageBytes() async {
    final charImage = widget.conversation.characterImage;
    if (charImage != null && charImage.isNotEmpty) {
      final charBytes = decodeDataImage(charImage);
      if (charBytes != null) return charBytes;
      // asset 路径
      if (charImage.startsWith('assets/')) {
        try {
          final data = await rootBundle.load(charImage);
          return data.buffer.asUint8List();
        } catch (_) {}
      }
    }

    final avatar = widget.conversation.avatarUrl;
    if (avatar != null && avatar.isNotEmpty) {
      final avatarBytes = decodeDataImage(avatar);
      if (avatarBytes != null) return avatarBytes;
      if (avatar.startsWith('assets/')) {
        try {
          final data = await rootBundle.load(avatar);
          return data.buffer.asUint8List();
        } catch (_) {}
      }
    }
    return null;
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

  void _preheatDetailPageImages() {
    final provider = _getImageProvider();
    if (provider == null) return;

    // 角色详情页的主图最大宽度约 200（3:4），按这个尺寸预热即可，避免无意义地解码到全屏分辨率。
    ref.read(imagePreheatQueueProvider).enqueueFromContext(
          context,
          provider,
          priority: ImagePreheatPriority.high,
          size: const Size(200, 200 * 4 / 3),
        );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final imageProvider = _getImageProvider();
    final blurredProvider = _blurredBackgroundProvider;

    return SizedBox(
      width: widget.cardWidth,
      child: MoeG2ClipRRect(
        radius: MoeSmoothRadii.md,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTapDown: (_) => _preheatDetailPageImages(),
            onTap: _navigateToDetail,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 1. 背景（优先：预制模糊图 asset / 本地生成模糊图 file；兜底：实时模糊原图）
                if (blurredProvider != null)
                  Image(
                    image: blurredProvider,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    filterQuality: FilterQuality.medium,
                  )
                else if (imageProvider != null)
                  ImageFiltered(
                    imageFilter: ui.ImageFilter.blur(sigmaX: 25, sigmaY: 25),
                    child: Transform.scale(
                      scale: 1.2,
                      child: Image(
                        image: imageProvider,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        filterQuality: FilterQuality.medium,
                      ),
                    ),
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
                  foregroundDecoration: MoeG2Decoration(
                    radius: MoeSmoothRadii.md,
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
                        padding: const EdgeInsets.all(16),
                          child: AspectRatio(
                            aspectRatio: 3 / 4,
                            child: Hero(
                              tag: RoleTransitionTags.image(widget.heroId),
                              child: MoeG2ClipRRect(
                                // 嵌套圆角公式：R_inner = R_outer - Padding
                                // 20 - 16 = 4
                                radius: MoeSmoothRadii.md - 16,
                                child: _buildImage(context),
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
                            // 名字（静态显示，无动画）
                            Text(
                              widget.conversation.displayName,
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w900,
                                color: colors.text,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 8),
                            // 简介气泡（优先显示 description，fallback 到 personaPrompt）
                            Expanded(
                              child: Hero(
                                tag: RoleTransitionTags.intro(widget.heroId),
                                child: Material(
                                  type: MaterialType.transparency,
                                  child: SizedBox(
                                    width: double.infinity,
                                    child: FrostedGlassContainer(
                                      padding: const EdgeInsets.all(12),
                                      child: Text(
                                        _getIntroText(),
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

  /// 获取简介文本（优先 description，fallback 到 personaPrompt）
  String _getIntroText() {
    final desc = widget.conversation.description;
    if (desc != null && desc.isNotEmpty) return desc;

    final persona = widget.conversation.personaPrompt;
    if (persona.isNotEmpty) return persona;

    return '暂无简介';
  }

  Widget _buildImage(BuildContext context, {BoxFit fit = BoxFit.cover}) {
    final charImage = widget.conversation.characterImage;
    if (charImage != null && charImage.isNotEmpty) {
      final charBytes = decodeDataImage(charImage);
      if (charBytes != null) {
        return Image.memory(charBytes, fit: fit, gaplessPlayback: true);
      }
      return Image.asset(
        charImage,
        fit: fit,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => _buildFallback(),
      );
    }

    final avatar = widget.conversation.avatarUrl;
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
