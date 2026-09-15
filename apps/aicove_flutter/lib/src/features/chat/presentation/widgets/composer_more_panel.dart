/// Composer 更多面板
///
/// 显示模型选择、相册、拍照、文件等操作入口
library;

import 'package:flutter/material.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/widgets/index.dart';

/// 更多面板操作类型
enum ComposerAction { model, thinking, gallery, camera, file, audio, video }

/// Composer 更多面板
class ComposerMorePanel extends StatelessWidget {
  final ValueChanged<ComposerAction> onAction;

  const ComposerMorePanel({super.key, required this.onAction});

  @override
  Widget build(BuildContext context) {
    final actions = <_MoreActionSpec>[
      _MoreActionSpec(
        icon: Icons.tune,
        label: '模型',
        onTap: () => onAction(ComposerAction.model),
      ),
      _MoreActionSpec(
        icon: Icons.psychology_outlined,
        label: '思考',
        onTap: () => onAction(ComposerAction.thinking),
      ),
      _MoreActionSpec(
        icon: Icons.photo_library_outlined,
        label: '相册',
        onTap: () => onAction(ComposerAction.gallery),
      ),
      _MoreActionSpec(
        icon: Icons.photo_camera_outlined,
        label: '拍照',
        onTap: () => onAction(ComposerAction.camera),
      ),
      _MoreActionSpec(
        icon: Icons.attach_file,
        label: '文件',
        onTap: () => onAction(ComposerAction.file),
      ),
      _MoreActionSpec(
        icon: Icons.audiotrack_outlined,
        label: '音频',
        onTap: () => onAction(ComposerAction.audio),
      ),
      _MoreActionSpec(
        icon: Icons.movie_outlined,
        label: '视频',
        onTap: () => onAction(ComposerAction.video),
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        const horizontalPadding = 12.0;
        const topPadding = 14.0;
        const bottomPadding = 12.0;
        const spacing = 10.0;
        const labelTopGap = 8.0;
        final labelHeight = (MediaQuery.textScalerOf(context).scale(12) * 1.5)
            .ceilToDouble();
        const buttonSide = 64.0; // ~= 1.5 * composer input min height (42)

        final usableWidth = (constraints.maxWidth - horizontalPadding * 2)
            .clamp(0.0, 2000.0)
            .toDouble();
        final columns = usableWidth >= 360 ? 4 : 3;
        final rawItemWidth = columns == 4
            ? (usableWidth - spacing * 3) / 4
            : (usableWidth - spacing * 2) / 3;
        final itemWidth = rawItemWidth.clamp(0.0, 260.0).toDouble();
        final itemHeight = buttonSide + labelTopGap + labelHeight;

        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            horizontalPadding,
            topPadding,
            horizontalPadding,
            bottomPadding,
          ),
          child: Wrap(
            spacing: spacing,
            runSpacing: spacing,
            children: [
              for (final action in actions)
                SizedBox(
                  width: itemWidth,
                  height: itemHeight,
                  child: MoreActionTile(
                    icon: action.icon,
                    label: action.label,
                    onTap: action.onTap,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _MoreActionSpec {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _MoreActionSpec({
    required this.icon,
    required this.label,
    required this.onTap,
  });
}

/// 更多面板操作按钮
class MoreActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const MoreActionTile({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    const radius = 14.0;
    const maxButtonSide = 64.0;
    const minButtonSide = 52.0;
    const labelTopGap = 8.0;
    final labelHeight = (MediaQuery.textScalerOf(context).scale(12) * 1.5)
        .ceilToDouble();

    return LayoutBuilder(
      builder: (context, constraints) {
        final side = constraints.maxWidth.clamp(minButtonSide, maxButtonSide);
        return Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(radius),
            canRequestFocus: false,
            splashFactory: NoSplash.splashFactory,
            splashColor: Colors.transparent,
            highlightColor: Colors.transparent,
            hoverColor: Colors.transparent,
            focusColor: Colors.transparent,
            overlayColor: WidgetStateProperty.all(Colors.transparent),
            child: Column(
              children: [
                SizedBox(
                  width: side,
                  height: side,
                  child: MoeButtonSurface(
                    shareParentSurface: false,
                    radius: radius,
                    child: Center(
                      child: Icon(icon, size: 30, color: colors.accentColor),
                    ),
                  ),
                ),
                const SizedBox(height: labelTopGap),
                SizedBox(
                  height: labelHeight,
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: colors.text,
                      fontWeight: MoeFontWeights.emphasis,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
