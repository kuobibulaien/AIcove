/// 双击气泡后的全屏看文字页：大字号显示整条消息，长按选字用系统工具栏复制。
/// 没有选区时轻点任意处关闭；有选区时轻点只收起选区。
library;

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../../../ui/theme/tokens.dart';

Future<void> showMessageTextViewer(BuildContext context, String text) {
  return Navigator.of(context).push(
    PageRouteBuilder<void>(
      opaque: true,
      transitionDuration: const Duration(milliseconds: 180),
      reverseTransitionDuration: const Duration(milliseconds: 150),
      pageBuilder: (context, _, _) => MessageTextViewer(text: text),
      transitionsBuilder: (context, animation, _, child) =>
          FadeTransition(opacity: animation, child: child),
    ),
  );
}

class MessageTextViewer extends StatefulWidget {
  const MessageTextViewer({super.key, required this.text});

  final String text;

  @override
  State<MessageTextViewer> createState() => _MessageTextViewerState();
}

class _MessageTextViewerState extends State<MessageTextViewer> {
  bool _hasSelection = false;
  int? _pointer;
  Offset _downPosition = Offset.zero;
  Timer? _pressTimer;

  void _handlePointerDown(PointerDownEvent event) {
    // 右键等非主键按下不算轻点。
    _pointer = (event.buttons & kPrimaryButton) != 0 ? event.pointer : null;
    _downPosition = event.position;
    _pressTimer?.cancel();
    // 按满长按时长就不算轻点了。
    _pressTimer = Timer(kLongPressTimeout, () => _pointer = null);
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (event.pointer == _pointer &&
        (event.position - _downPosition).distance > kTouchSlop) {
      _pointer = null;
    }
  }

  // 本监听先于选择区的手势收到抬起事件，此时选区还是轻点之前的状态。
  void _handlePointerUp(PointerUpEvent event) {
    if (event.pointer != _pointer) return;
    _pointer = null;
    _pressTimer?.cancel();
    if (!_hasSelection) Navigator.of(context).maybePop();
  }

  @override
  void dispose() {
    _pressTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    return Scaffold(
      backgroundColor: colors.surface,
      body: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _handlePointerDown,
        onPointerMove: _handlePointerMove,
        onPointerUp: _handlePointerUp,
        child: SafeArea(
          child: SizedBox.expand(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 28,
                  vertical: 48,
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  // 选择区放在滚动区里面：反过来包会触发 Scrollable 的选区断言。
                  child: SelectionArea(
                    onSelectionChanged: (content) =>
                        _hasSelection = content?.plainText.isNotEmpty ?? false,
                    child: Text(
                      widget.text,
                      key: const ValueKey('message_text_viewer_text'),
                      style: TextStyle(
                        color: colors.text,
                        fontSize: 24,
                        height: 1.6,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
