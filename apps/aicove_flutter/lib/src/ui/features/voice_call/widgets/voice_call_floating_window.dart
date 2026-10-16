import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../../features/voice_call/application/active_voice_call.dart';
import '../../../../features/voice_call/application/voice_call_session.dart';
import '../../../../core/models/message_block.dart';

/// 窄屏通话切回聊天后浮在聊天页上的小窗：正中是话筒开关状态，下面是通话时长。
/// 可拖动，点一下回到通话。放在一个铺满的 Stack 层里使用。
class VoiceCallFloatingWindow extends StatefulWidget {
  const VoiceCallFloatingWindow({
    super.key,
    required this.call,
    required this.onTap,
    this.topInset = 0,
  });

  final ActiveVoiceCall call;
  final VoidCallback onTap;

  /// 顶栏等遮挡的高度，初始位置和拖动都不进这块。
  final double topInset;

  static const Size size = Size(68, 84);
  static const double _margin = 12;

  @override
  State<VoiceCallFloatingWindow> createState() =>
      _VoiceCallFloatingWindowState();
}

class _VoiceCallFloatingWindowState extends State<VoiceCallFloatingWindow> {
  /// 拖动后的位置；没拖过时贴在右上角。
  Offset? _offset;

  Offset _clamp(Offset offset, BoxConstraints box) {
    const size = VoiceCallFloatingWindow.size;
    const margin = VoiceCallFloatingWindow._margin;
    final maxX = box.maxWidth - size.width - margin;
    final maxY = box.maxHeight - size.height - margin;
    final minY = widget.topInset + margin;
    return Offset(
      offset.dx.clamp(margin, maxX < margin ? margin : maxX),
      offset.dy.clamp(minY, maxY < minY ? minY : maxY),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final offset = _clamp(
          _offset ??
              Offset(
                box.maxWidth - VoiceCallFloatingWindow.size.width,
                widget.topInset + 8,
              ),
          box,
        );
        return Stack(
          children: [
            Positioned(
              left: offset.dx,
              top: offset.dy,
              child: GestureDetector(
                key: const ValueKey('voice-call-floating-window'),
                onTap: widget.onTap,
                onPanUpdate: (details) => setState(
                  () => _offset = _clamp(offset + details.delta, box),
                ),
                // 自带文字样式，不依赖承载页面是否有 Material 祖先。
                child: Material(
                  type: MaterialType.transparency,
                  child: _FloatingCard(call: widget.call),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _FloatingCard extends StatelessWidget {
  const _FloatingCard({required this.call});

  final ActiveVoiceCall call;

  @override
  Widget build(BuildContext context) {
    final speaking = call.phase == VoiceCallPhase.speaking;
    return Semantics(
      button: true,
      label: '通话中，点击返回通话',
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.22),
              blurRadius: 14,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              width: VoiceCallFloatingWindow.size.width,
              height: VoiceCallFloatingWindow.size.height,
              color: (speaking ? const Color(0xFF1F7A6B) : Colors.black)
                  .withValues(alpha: 0.55),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // 话筒照常开着（说话和打字都进通话），这里只显示开关状态。
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withValues(alpha: 0.14),
                    ),
                    child: Icon(
                      call.muted ? Icons.mic_off_rounded : Icons.mic_rounded,
                      key: const ValueKey('voice-call-floating-mic'),
                      size: 22,
                      color: Colors.white.withValues(
                        alpha: call.muted ? 0.6 : 0.95,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  ValueListenableBuilder<Duration>(
                    valueListenable: call.elapsed,
                    builder: (context, elapsed, _) => Text(
                      formatCallDuration(elapsed),
                      style: const TextStyle(
                        fontSize: 11,
                        color: Colors.white,
                        fontFeatures: [ui.FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
