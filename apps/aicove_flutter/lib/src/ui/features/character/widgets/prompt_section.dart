/// PromptSection - 角色编辑页：提示词 + 描述只读展示区
///
/// 从 ContactEditPage 拆分，负责提示词预览和描述只读展示。
/// 两者共用类似的卡片布局，通过 ReadonlyEditCard 统一样式。
library;

import 'package:flutter/material.dart';

import '../../../../ui/shared/effects/frosted_glass_card.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/theme/tokens.dart';

/// 只读展示卡片 + 编辑入口（描述、提示词等复用）
class ReadonlyEditCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String content;
  final String placeholder;
  final VoidCallback onEdit;

  const ReadonlyEditCard({
    super.key,
    required this.icon,
    required this.title,
    required this.content,
    required this.placeholder,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final hasContent = content.trim().isNotEmpty;

    return FrostedGlassContainer(
      borderRadius: 16,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: colors.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: MoeFontWeights.emphasis,
                    color: colors.text,
                  ),
                ),
              ),
              GestureDetector(
                onTap: onEdit,
                child: Container(
                  width: 32,
                  height: 32,
                  decoration: MoeG2Decoration(
                    radius: 8,
                    color: colors.primary.withValues(alpha: 0.1),
                  ),
                  child: Icon(
                    Icons.edit_outlined,
                    size: 16,
                    color: colors.primary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          GestureDetector(
            onTap: onEdit,
            child: SizedBox(
              width: double.infinity,
              child: Text(
                hasContent ? content : placeholder,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.5,
                  color: hasContent
                      ? colors.text.withValues(alpha: 0.85)
                      : colors.muted,
                ),
                maxLines: 6,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 提示词专用展示区（放大 + 内部可滑动）
class PromptPreviewCard extends StatelessWidget {
  final TextEditingController personaCtrl;
  final VoidCallback onEdit;

  const PromptPreviewCard({
    super.key,
    required this.personaCtrl,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final hasContent = personaCtrl.text.trim().isNotEmpty;

    return FrostedGlassContainer(
      borderRadius: 16,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.auto_awesome, size: 18, color: colors.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '提示词',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: MoeFontWeights.emphasis,
                    color: colors.text,
                  ),
                ),
              ),
              GestureDetector(
                onTap: onEdit,
                child: Container(
                  width: 32,
                  height: 32,
                  decoration: MoeG2Decoration(
                    radius: 8,
                    color: colors.primary.withValues(alpha: 0.1),
                  ),
                  child: Icon(
                    Icons.edit_outlined,
                    size: 16,
                    color: colors.primary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // 可滑动提示词预览区
          GestureDetector(
            onTap: onEdit,
            child: Container(
              height: 320,
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: MoeG2Decoration(
                radius: 10,
                color: colors.surfaceAlt.withValues(alpha: 0.2),
              ),
              child: hasContent
                  ? Scrollbar(
                      child: SingleChildScrollView(
                        physics: const BouncingScrollPhysics(),
                        child: Text(
                          personaCtrl.text,
                          style: TextStyle(
                            fontSize: 14,
                            height: 1.6,
                            color: colors.text.withValues(alpha: 0.85),
                          ),
                        ),
                      ),
                    )
                  : Center(
                      child: Text(
                        '暂无角色提示词',
                        style: TextStyle(
                          fontSize: 14,
                          color: colors.muted,
                        ),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
