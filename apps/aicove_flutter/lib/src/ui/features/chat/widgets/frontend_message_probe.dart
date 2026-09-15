import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../features/observability/frontend_diagnostics_port.dart';
import '../../../../features/observability/frontend_diagnostics_provider.dart';

/// 只记录关联到本轮的首段文字布局；不是 GPU 出帧或用户已读回执。
class FrontendMessageProbe extends ConsumerStatefulWidget {
  const FrontendMessageProbe(
      {super.key,
      required this.messageId,
      required this.hasText,
      required this.child});
  final String messageId;
  final bool hasText;
  final Widget child;

  @override
  ConsumerState<FrontendMessageProbe> createState() =>
      _FrontendMessageProbeState();
}

class _FrontendMessageProbeState extends ConsumerState<FrontendMessageProbe> {
  bool _scheduled = false;
  String? _reportedOperation;

  @override
  Widget build(BuildContext context) {
    final diagnostics = ref.read(frontendDiagnosticsProvider);
    final operation = diagnostics.forMessage(widget.messageId);
    if (widget.hasText &&
        operation != null &&
        !_scheduled &&
        _reportedOperation != operation.operationId) {
      _scheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scheduled = false;
        if (!mounted ||
            !widget.hasText ||
            diagnostics.forMessage(widget.messageId)?.operationId !=
                operation.operationId ||
            !isDiagnosticLayoutVisible(context)) {
          return;
        }
        _reportedOperation = operation.operationId;
        diagnostics.record(operation, FrontendStage.firstTextLayout,
            once: true);
      });
    }
    return widget.child;
  }
}

bool isDiagnosticLayoutVisible(BuildContext context) {
  final lifecycle = WidgetsBinding.instance.lifecycleState;
  if (lifecycle != null && lifecycle != AppLifecycleState.resumed) return false;
  if (ModalRoute.of(context)?.isCurrent == false) return false;
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.attached || !box.hasSize || box.size.isEmpty) {
    return false;
  }
  final bounds = box.localToGlobal(Offset.zero) & box.size;
  final viewport = RenderAbstractViewport.maybeOf(box);
  final viewportBox = viewport is RenderBox ? viewport as RenderBox : null;
  final visible = viewportBox != null && viewportBox.hasSize
      ? viewportBox.localToGlobal(Offset.zero) & viewportBox.size
      : Offset.zero & MediaQuery.sizeOf(context);
  return bounds.overlaps(visible);
}
