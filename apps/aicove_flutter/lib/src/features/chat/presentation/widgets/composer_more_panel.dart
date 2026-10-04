/// Composer 更多面板
///
/// 显示模型、思考、相册、附件与通话入口
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/widgets/index.dart';

/// 更多面板操作类型
enum ComposerAction { model, thinking, gallery, attachment, call }

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
        icon: Icons.attach_file,
        label: '附件',
        onTap: () => onAction(ComposerAction.attachment),
      ),
      _MoreActionSpec(
        icon: Icons.call_outlined,
        label: '通话',
        onTap: () => onAction(ComposerAction.call),
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final height = constraints.maxHeight;

        // Folder-style grid that spans the panel: the outer margin, the row
        // gap and the column gap are one value. The preferred tile side grows
        // with the panel width inside a comfortable band, and the leftover
        // width becomes the gap; at least three columns, wide panels add
        // columns, and large text drops columns so labels still fit.
        final preferredTile = (width * _tileWidthRatio).clamp(
          _preferredTileMin,
          _preferredTileMax,
        );
        final minTile = math.max(
          _minTileSide,
          _moreActionContentHeight(context) + 2 * _tilePadding,
        );
        final fitColumns = math.max(
          1,
          ((width - _minGridGap) / (minTile + _minGridGap)).floor(),
        );
        final columns = math.min(
          math.max(
            _gridColumns,
            ((width - _minGridGap) / (preferredTile + _minGridGap)).floor(),
          ),
          fitColumns,
        );
        final tileSide = math.max(
          minTile,
          math.min(
            preferredTile,
            (width - (columns + 1) * _minGridGap) / columns,
          ),
        );
        final gap = math.max(
          0.0,
          (width - columns * tileSide) / (columns + 1),
        );
        final rows = (actions.length / columns).ceil();

        final grid = Padding(
          padding: EdgeInsets.all(gap),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var row = 0; row < rows; row++)
                Padding(
                  padding: EdgeInsets.only(top: row == 0 ? 0 : gap),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var column = 0; column < columns; column++)
                        Padding(
                          padding: EdgeInsets.only(
                            left: column == 0 ? 0 : gap,
                          ),
                          child: SizedBox.square(
                            dimension: tileSide,
                            child: switch (row * columns + column) {
                              final index when index < actions.length =>
                                MoreActionTile(
                                  icon: actions[index].icon,
                                  label: actions[index].label,
                                  onTap: actions[index].onTap,
                                ),
                              _ => null,
                            },
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        );

        // Scrolling is only an overflow fallback for short panels or very
        // large text, so the tiles keep the global material instead of the
        // moving-surface fill.
        return SingleChildScrollView(
          child: MoeRarelyScrolledRegion(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minWidth: width,
                minHeight: height.isFinite ? height : 0,
              ),
              child: Align(alignment: Alignment.topLeft, child: grid),
            ),
          ),
        );
      },
    );
  }
}

const _gridColumns = 3;
const _minGridGap = 16.0;
const _preferredTileMin = 80.0;
const _preferredTileMax = 90.0;
const _tileWidthRatio = 0.22;
const _minTileSide = 64.0;
const _tilePadding = 8.0;
const _tileRadius = 20.0;
const _iconSize = 26.0;
const _iconLabelGap = 6.0;
const _labelFontSize = 13.0;

double _moreActionLabelHeight(BuildContext context) =>
    (MediaQuery.textScalerOf(context).scale(_labelFontSize) * 1.5)
        .ceilToDouble();

double _moreActionContentHeight(BuildContext context) =>
    _iconSize + _iconLabelGap + _moreActionLabelHeight(context);

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

/// 更多面板操作按钮：图标与名称同在一块正方形材质内。
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

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(_tileRadius),
        canRequestFocus: false,
        splashFactory: NoSplash.splashFactory,
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        hoverColor: Colors.transparent,
        focusColor: Colors.transparent,
        overlayColor: WidgetStateProperty.all(Colors.transparent),
        child: MoeButtonSurface(
          shareParentSurface: false,
          radius: _tileRadius,
          padding: const EdgeInsets.all(_tilePadding),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: _iconSize, color: colors.accentColor),
                const SizedBox(height: _iconLabelGap),
                SizedBox(
                  height: _moreActionLabelHeight(context),
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: _labelFontSize,
                      color: colors.text,
                      fontWeight: MoeFontWeights.emphasis,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
