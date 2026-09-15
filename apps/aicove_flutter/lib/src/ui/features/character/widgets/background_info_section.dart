/// BackgroundInfoSection - 角色编辑页：背景信息补充
///
/// 折叠行，展开后可编辑人设提示词与角色专属绘图要求。
library;

import 'package:flutter/material.dart';

import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/theme/tokens.dart';

class BackgroundInfoSection extends StatelessWidget {
  final bool expanded;
  final VoidCallback onToggle;
  final String personaText;
  final String drawingText;
  final VoidCallback onEditPersona;
  final VoidCallback onEditDrawing;

  const BackgroundInfoSection({
    super.key,
    required this.expanded,
    required this.onToggle,
    required this.personaText,
    required this.drawingText,
    required this.onEditPersona,
    required this.onEditDrawing,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final hasPersona = personaText.trim().isNotEmpty;
    final hasDrawing = drawingText.trim().isNotEmpty;

    return MoeSettingsGroup(
      margin: EdgeInsets.zero,
      children: [
        MoeSettingsRow(
          icon: Icons.edit_note,
          label: '背景信息补充',
          subtitle: _statusText(hasPersona, hasDrawing),
          showDivider: expanded,
          trailingType: MoeSettingsRowTrailing.custom,
          trailing: AnimatedRotation(
            turns: expanded ? 0.5 : 0,
            duration: kAnimFast,
            child: Icon(Icons.expand_more, size: 20, color: colors.muted),
          ),
          onTap: onToggle,
        ),
        AnimatedSize(
          duration: kAnimFast,
          curve: Curves.easeOut,
          child: expanded
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _editorRow(
                      colors,
                      label: '人设提示词',
                      text: personaText,
                      placeholder: '详细描述角色的性格、说话方式、行为边界和世界观',
                      onTap: onEditPersona,
                      showDivider: true,
                    ),
                    _editorRow(
                      colors,
                      label: '角色专属绘图要求',
                      text: drawingText,
                      placeholder: '仅本角色：外貌、服装等生图补充要求',
                      onTap: onEditDrawing,
                      showDivider: false,
                    ),
                  ],
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }

  String _statusText(bool hasPersona, bool hasDrawing) {
    if (hasPersona && hasDrawing) return '已填写人设提示词与绘图要求';
    if (hasPersona) return '已填写人设提示词';
    if (hasDrawing) return '已填写绘图要求';
    return '人设提示词与绘图要求，未填写';
  }

  Widget _editorRow(
    MoeColors colors, {
    required String label,
    required String text,
    required String placeholder,
    required VoidCallback onTap,
    required bool showDivider,
  }) {
    final hasContent = text.trim().isNotEmpty;
    return MoeSettingsRow(
      label: label,
      subtitleWidget: Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text(
          hasContent ? text.trim() : placeholder,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 13,
            height: 1.4,
            color: hasContent ? colors.muted : colors.muted.withValues(alpha: 0.7),
          ),
        ),
      ),
      showDivider: showDivider,
      onTap: onTap,
    );
  }
}
