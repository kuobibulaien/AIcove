/// HorizontalRoleCard - 横向角色卡片组件
///
/// 从 role_card_page.dart 提取，显示左图右文风格的角色卡片。
/// 使用 ExpandingPageRoute 实现无缝展开动画。
///
/// 更新记录：
/// - 2025-12-31: 从 role_card_page.dart 提取
library;

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/animations/expanding_page_route.dart';
import '../../../../ui/shared/animations/hero_rect_tweens.dart';
import '../../../../ui/shared/effects/frosted_glass_card.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../core/utils/avatar_helper.dart';
import '../../../../core/utils/blurred_background_service.dart';
import '../../../../core/utils/role_transition_tags.dart';
import '../../../../features/chat/domain/conversation.dart';
import '../../../../features/chat/domain/persona_prompt_codec.dart';
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
  String? _scheduledBlurSource;

  @override
  void initState() {
    super.initState();
    _scheduleBlurEnsure();
  }

  @override
  void didUpdateWidget(covariant HorizontalRoleCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final imageChanged = oldWidget.conversation.id != widget.conversation.id ||
        oldWidget.conversation.characterImage !=
            widget.conversation.characterImage ||
        oldWidget.conversation.avatarUrl != widget.conversation.avatarUrl;
    if (!imageChanged) return;
    _scheduleBlurEnsure();
  }

  String? _getBackgroundSource() {
    return BlurredBackgroundService.pickPreferredSource(
      characterImage: widget.conversation.characterImage,
      avatarUrl: widget.conversation.avatarUrl,
    );
  }

  void _scheduleBlurEnsure() {
    final source = _getBackgroundSource();
    if (source == null || _scheduledBlurSource == source) return;
    _scheduledBlurSource = source;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(
        BlurredBackgroundService.ensureBlur(source).then((provider) {
          if (!mounted) return;
          if (provider == null && _scheduledBlurSource == source) {
            _scheduledBlurSource = null;
          }
        }),
      );
    });
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
    final source = _getBackgroundSource();

    return SizedBox(
      width: widget.cardWidth,
      child: MoeG2ClipRRect(
        radius: MoeSmoothRadii.md,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: _navigateToDetail,
            child: Stack(
              fit: StackFit.expand,
              children: [
                _buildGradientFallback(colors, isDark),
                if (source != null)
                  ValueListenableBuilder<int>(
                    valueListenable: BlurredBackgroundService.ticker,
                    builder: (context, _, __) {
                      final provider =
                          BlurredBackgroundService.getBlurProvider(source);
                      return AnimatedSwitcher(
                        duration: const Duration(milliseconds: 300),
                        child: _buildBlurLayer(source, provider),
                      );
                    },
                  ),

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
                                fontWeight: MoeFontWeights.emphasis,
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
                                createRectTween:
                                    createExpandingAlignedHeroRectTween,
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
                                          fontWeight: MoeFontWeights.normal,
                                          height: 1.4,
                                          color: colors.text
                                              .withValues(alpha: 0.9),
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

  Widget _buildBlurLayer(String source, ImageProvider? provider) {
    final blurAsset = BlurredBackgroundService.deriveBlurAssetPath(source);

    if (blurAsset != null) {
      return SizedBox.expand(
        key: ValueKey('asset:$blurAsset'),
        child: Image.asset(
          blurAsset,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          filterQuality: FilterQuality.medium,
          errorBuilder: (_, __, ___) => provider == null
              ? const SizedBox.shrink(key: ValueKey('empty'))
              : _buildBlurImage(provider, key: ValueKey('file:$source')),
        ),
      );
    }

    if (provider == null) {
      return const SizedBox.shrink(key: ValueKey('empty'));
    }

    return _buildBlurImage(provider, key: ValueKey('file:$source'));
  }

  Widget _buildBlurImage(ImageProvider provider, {required Key key}) {
    return SizedBox.expand(
      key: key,
      child: Image(
        image: provider,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        filterQuality: FilterQuality.medium,
      ),
    );
  }

  Widget _buildGradientFallback(MoeColors colors, bool isDark) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colors.surface,
            colors.primary.withValues(alpha: isDark ? 0.18 : 0.1),
            isDark ? const Color(0xFF161A20) : Colors.white,
          ],
        ),
      ),
    );
  }

  /// 获取简介文本（优先 description，fallback 到 personaPrompt）
  String _getIntroText() {
    final desc = widget.conversation.description;
    if (desc != null && desc.isNotEmpty) return desc;

    final persona =
        PersonaPromptCodec.parse(widget.conversation.personaPrompt).userPrompt;
    if (persona.isNotEmpty) return persona;

    return '暂无简介';
  }

  Widget _buildImage(BuildContext context, {BoxFit fit = BoxFit.cover}) {
    final helper = AvatarHelper(
      avatarUrl: widget.conversation.avatarUrl,
      characterImage: widget.conversation.characterImage,
      displayName: widget.conversation.displayName,
    );
    return helper.buildCharacterWidget(
      fit: fit,
      fallback: Container(
        color: Colors.grey[300],
        child: const Center(
          child: Icon(Icons.person, color: Colors.white, size: 40),
        ),
      ),
    );
  }
}
