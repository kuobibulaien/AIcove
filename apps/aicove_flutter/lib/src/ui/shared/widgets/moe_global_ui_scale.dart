import 'package:flutter/widgets.dart';

import '../../../features/settings/settings_models.dart';

/// 全局界面缩放容器
///
/// 通过反向 SizedBox + Transform.scale，让缩放后依然铺满视口；
/// 同时把 MediaQuery 的尺寸、安全区与键盘高度换算到缩放后的坐标，
/// 子组件直接读 MediaQuery 即可，不必再自行除以缩放倍数。
/// 用于手动微调不同设备上的整体观感。
class MoeGlobalUiScale extends StatelessWidget {
  final double scale;
  final Widget child;

  const MoeGlobalUiScale({
    super.key,
    required this.scale,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveScale = scale.clamp(kMinUiScaleFactor, kMaxUiScaleFactor);
    if ((effectiveScale - 1.0).abs() < 0.001) {
      return child;
    }

    final media = MediaQuery.of(context);
    final viewport = media.size;
    EdgeInsets toLayout(EdgeInsets insets) => insets / effectiveScale;

    return ClipRect(
      child: OverflowBox(
        alignment: Alignment.topCenter,
        minWidth: 0,
        minHeight: 0,
        maxWidth: double.infinity,
        maxHeight: double.infinity,
        child: Transform.scale(
          scale: effectiveScale,
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: viewport.width / effectiveScale,
            height: viewport.height / effectiveScale,
            // Children lay out in scaled coordinates, so the keyboard and
            // safe-area metrics must be converted too; otherwise a scale below
            // 1 leaves bottom-anchored dialogs partly under the keyboard.
            child: MediaQuery(
              data: media.copyWith(
                size: viewport / effectiveScale,
                padding: toLayout(media.padding),
                viewPadding: toLayout(media.viewPadding),
                viewInsets: toLayout(media.viewInsets),
                systemGestureInsets: toLayout(media.systemGestureInsets),
              ),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}
