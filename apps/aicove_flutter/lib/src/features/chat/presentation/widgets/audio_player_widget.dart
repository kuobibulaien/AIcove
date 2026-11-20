export 'audio_player_controller.dart';

import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../core/models/message_block.dart';
import '../../../../core/models/block_status.dart';
import '../../../observability/frontend_diagnostics_port.dart';
import '../../../observability/frontend_diagnostics_provider.dart';
import 'audio_player_controller.dart';

/// 音频播放器组件
class AudioPlayerWidget extends ConsumerWidget {
  final AudioBlock block;
  final Color textColor;

  const AudioPlayerWidget({
    super.key,
    required this.block,
    required this.textColor,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 占位阶段：无 URL 或标记为 pending，则只展示加载态语音条
    final isPending = block.url.isEmpty || block.status == BlockStatus.pending;

    if (isPending) {
      return _PendingAudioBubble(block: block, textColor: textColor);
    }

    final diagnostics = ref.read(frontendDiagnosticsProvider);
    final operation =
        diagnostics.forMessage(block.messageId) ??
        FrontendDiagnosticContext(operationId: 'audio_${block.messageId}');
    diagnostics.bindMessage(block.messageId, operation);
    diagnostics.record(
      operation,
      FrontendStage.audioAvailable,
      messageId: block.messageId,
      once: true,
    );
    ref.listen<AudioPlayerState>(audioPlayerControllerProvider(block.url), (
      previous,
      next,
    ) {
      if (next.error != null && previous?.error != next.error) {
        diagnostics.record(
          operation,
          FrontendStage.audioFailed,
          messageId: block.messageId,
        );
      }
      if (next.isPlaying &&
          !next.isLoading &&
          (previous?.isPlaying != true || previous?.isLoading == true)) {
        diagnostics.record(
          operation,
          FrontendStage.audioPlaying,
          messageId: block.messageId,
        );
      }
    });
    final state = ref.watch(audioPlayerControllerProvider(block.url));
    if (state.isReady && !state.isLoading && state.error == null) {
      diagnostics.record(
        operation,
        FrontendStage.audioReady,
        messageId: block.messageId,
        once: true,
      );
    }
    final controller = ref.read(
      audioPlayerControllerProvider(block.url).notifier,
    );

    // 优先使用 block 中的 durationSeconds，如果没有则尝试使用 state 中的 duration
    final double durationSec =
        block.durationSeconds ??
        (state.duration.inSeconds > 0
            ? state.duration.inSeconds.toDouble()
            : 2.0);

    // 动态宽度计算：
    // 基础宽度 80
    // 每秒增加 8 像素
    // 最大宽度 220
    final double bubbleWidth = (80.0 + (durationSec * 8)).clamp(80.0, 220.0);

    // 根据宽度计算波形条数量，大约每 12px 一个条
    final int barCount = (bubbleWidth / 12).floor().clamp(5, 15);

    return SizedBox(
      width: bubbleWidth,
      // 移除垂直间距，与文本消息高度保持一致 (KISS)
      child: Row(
        children: [
          // 播放/暂停按钮
          _buildPlayButton(state, controller, textColor, () {
            diagnostics.record(
              operation,
              FrontendStage.audioPlayRequested,
              messageId: block.messageId,
            );
          }),
          const SizedBox(width: 8),

          // 音频波形可视化
          Expanded(child: _buildWaveform(state, textColor, barCount)),

          const SizedBox(width: 8),

          // 时长显示
          Text(
            '${durationSec.toInt()}"',
            style: TextStyle(
              color: textColor.withValues(alpha: 0.9),
              fontSize: 13,
              fontWeight: MoeFontWeights.emphasis,
            ),
          ),
        ],
      ),
    );
  }

  /// 构建音频波形可视化
  Widget _buildWaveform(AudioPlayerState state, Color color, int barCount) {
    return _AnimatedWaveform(
      isPlaying: state.isPlaying,
      color: color,
      barCount: barCount,
    );
  }

  Widget _buildPlayButton(
    AudioPlayerState state,
    AudioPlayerController controller,
    Color color,
    VoidCallback onPlaybackIntent,
  ) {
    // 统一按钮和加载指示器的大小，防止状态切换时闪烁 (UI Consistency)
    const double size = 24.0;

    if (state.isLoading) {
      return SizedBox(
        width: size,
        height: size,
        child: Center(
          child: SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
        ),
      );
    }

    if (state.error != null) {
      return GestureDetector(
        onTap: controller.reload,
        behavior: HitTestBehavior.opaque,
        child: Icon(Icons.refresh_rounded, color: color, size: size),
      );
    }

    return GestureDetector(
      onTap: () {
        onPlaybackIntent();
        unawaited(controller.togglePlayPause());
      },
      behavior: HitTestBehavior.opaque,
      child: Icon(
        state.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
        color: color,
        size: size,
      ),
    );
  }
}

/// 动态波形组件
class _AnimatedWaveform extends StatefulWidget {
  final bool isPlaying;
  final Color color;
  final int barCount;

  const _AnimatedWaveform({
    required this.isPlaying,
    required this.color,
    this.barCount = 5,
  });

  @override
  State<_AnimatedWaveform> createState() => _AnimatedWaveformState();
}

class _AnimatedWaveformState extends State<_AnimatedWaveform>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  final List<double> _randomSeeds = [];

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(duration: kAnimLong, vsync: this);
    if (widget.isPlaying) {
      _controller.repeat();
    }

    // 初始化随机种子，让波形看起来更自然
    _generateSeeds();
  }

  @override
  void didUpdateWidget(_AnimatedWaveform oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.barCount != oldWidget.barCount) {
      _generateSeeds();
    }
    if (widget.isPlaying && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.isPlaying && _controller.isAnimating) {
      _controller.stop();
      _controller.value = 0; // 重置位置
    }
  }

  void _generateSeeds() {
    _randomSeeds.clear();
    final random = Random();
    for (int i = 0; i < widget.barCount; i++) {
      _randomSeeds.add(0.3 + random.nextDouble() * 0.7);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 降低波形高度以匹配文本消息高度
    const double height = 20.0;

    return RepaintBoundary(
      child: SizedBox(
        height: height,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            return Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: List.generate(widget.barCount, (index) {
                // 波形动画逻辑
                double heightFactor = 0.4; // 默认静止高度

                if (widget.isPlaying) {
                  // 使用正弦波 + 随机种子产生波动效果
                  final progress = _controller.value;
                  final offset = index / widget.barCount;
                  final wave = sin((progress + offset) * 2 * pi);
                  // 归一化到 0.3 ~ 1.0
                  heightFactor =
                      0.3 +
                      ((wave + 1) / 2) *
                          0.7 *
                          _randomSeeds[index % _randomSeeds.length];
                } else {
                  // 静止时也保留一点随机高度，看起来像真实的波形
                  heightFactor =
                      0.3 + 0.4 * _randomSeeds[index % _randomSeeds.length];
                }

                return Container(
                  width: 3,
                  height: height * heightFactor,
                  decoration: BoxDecoration(
                    borderRadius: const BorderRadius.all(Radius.circular(1.5)),
                    color: widget.color.withValues(
                      alpha: widget.isPlaying ? 0.9 : 0.6,
                    ),
                  ),
                );
              }),
            );
          },
        ),
      ),
    );
  }
}

/// 加载中状态的语音条占位
class _PendingAudioBubble extends StatelessWidget {
  final AudioBlock block;
  final Color textColor;
  const _PendingAudioBubble({required this.block, required this.textColor});

  @override
  Widget build(BuildContext context) {
    final double durationSec = block.durationSeconds ?? 2.0;
    final double bubbleWidth = (80.0 + (durationSec * 8)).clamp(80.0, 220.0);
    final int barCount = (bubbleWidth / 12).floor().clamp(5, 15);

    return SizedBox(
      width: bubbleWidth,
      child: Row(
        children: [
          SizedBox(
            width: 24,
            height: 24,
            child: Center(
              child: SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(textColor),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _AnimatedWaveform(
              isPlaying: false,
              color: textColor,
              barCount: barCount,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '${durationSec.toInt()}"',
            style: TextStyle(
              color: textColor.withValues(alpha: 0.9),
              fontSize: 13,
              fontWeight: MoeFontWeights.emphasis,
            ),
          ),
        ],
      ),
    );
  }
}
