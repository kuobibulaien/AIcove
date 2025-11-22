import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import '../../../../core/models/message_block.dart';
import '../../../../core/config.dart';
import '../../../../core/models/block_status.dart';

/// 音频播放器状态管理
class AudioPlayerState {
  final bool isPlaying;
  final bool isLoading;
  final Duration position;
  final Duration duration;
  final String? error;

  const AudioPlayerState({
    this.isPlaying = false,
    this.isLoading = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.error,
  });

  AudioPlayerState copyWith({
    bool? isPlaying,
    bool? isLoading,
    Duration? position,
    Duration? duration,
    String? error,
  }) {
    return AudioPlayerState(
      isPlaying: isPlaying ?? this.isPlaying,
      isLoading: isLoading ?? this.isLoading,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      error: error ?? this.error,
    );
  }
}

/// 音频播放器控制器
class AudioPlayerController extends StateNotifier<AudioPlayerState> {
  final AudioPlayer _player;
  final String audioUrl;
  bool _completed = false;

  AudioPlayerController(this.audioUrl)
      : _player = AudioPlayer(),
        super(const AudioPlayerState()) {
    _init();
  }

  void _init() {
    // 监听播放状态
    _player.playerStateStream.listen((playerState) {
      _completed = playerState.processingState == ProcessingState.completed;
      state = state.copyWith(
        isPlaying: _completed ? false : playerState.playing,
        isLoading: playerState.processingState == ProcessingState.loading ||
                   playerState.processingState == ProcessingState.buffering,
      );
    });

    // 监听播放位置
    _player.positionStream.listen((position) {
      state = state.copyWith(position: position);
    });

    // 监听总时长
    _player.durationStream.listen((duration) {
      if (duration != null) {
        state = state.copyWith(duration: duration);
      }
    });

    // 自动加载音频
    _loadAudio();
  }

  Future<void> _loadAudio() async {
    try {
      state = state.copyWith(isLoading: true, error: null);

      // 构建完整URL
      final fullUrl = audioUrl.startsWith('http')
          ? audioUrl
          : '${resolvedApiBase()}$audioUrl';

      await _player.setUrl(fullUrl);
      state = state.copyWith(isLoading: false);
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: '加载失败: $e',
      );
    }
  }

  Future<void> togglePlayPause() async {
    try {
      if (state.isPlaying) {
        await _player.pause();
      } else {
        // 如果上一次已经完整播放结束，再次点击时先把进度重置到开头，保证可以重播
        if (_completed &&
            state.duration > Duration.zero &&
            state.position >= state.duration) {
          await _player.seek(Duration.zero);
          _completed = false;
        }
        await _player.play();
      }
    } catch (e) {
      state = state.copyWith(error: '播放失败: $e');
    }
  }

  Future<void> seek(Duration position) async {
    try {
      await _player.seek(position);
    } catch (e) {
      state = state.copyWith(error: '跳转失败: $e');
    }
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }
}

/// Provider工厂：为每个音频URL创建独立的控制器
final audioPlayerControllerProvider = StateNotifierProvider.family<
    AudioPlayerController, AudioPlayerState, String>(
  (ref, audioUrl) => AudioPlayerController(audioUrl),
);

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
      return _PendingAudioBubble(textColor: textColor);
    }

    final state = ref.watch(audioPlayerControllerProvider(block.url));
    final controller = ref.read(audioPlayerControllerProvider(block.url).notifier);

    // 优先使用 block 中的 durationSeconds，如果没有则尝试使用 state 中的 duration
    final double durationSec = block.durationSeconds ?? 
        (state.duration.inSeconds > 0 ? state.duration.inSeconds.toDouble() : 2.0);
    
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
          _buildPlayButton(state, controller, textColor),
          const SizedBox(width: 8),

          // 音频波形可视化
          Expanded(
            child: _buildWaveform(state, textColor, barCount),
          ),

          const SizedBox(width: 8),

          // 时长显示
          Text(
            '${durationSec.toInt()}"',
            style: TextStyle(
              color: textColor.withOpacity(0.9),
              fontSize: 13,
              fontWeight: FontWeight.w500,
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

    return GestureDetector(
      onTap: controller.togglePlayPause,
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
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1200),
      vsync: this,
    )..repeat();
    
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
    
    return SizedBox(
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
                heightFactor = 0.3 + ((wave + 1) / 2) * 0.7 * _randomSeeds[index % _randomSeeds.length];
              } else {
                // 静止时也保留一点随机高度，看起来像真实的波形
                heightFactor = 0.3 + 0.4 * _randomSeeds[index % _randomSeeds.length];
              }

              return Container(
                width: 3,
                height: height * heightFactor,
                decoration: BoxDecoration(
                  color: widget.color.withOpacity(widget.isPlaying ? 0.9 : 0.6),
                  borderRadius: BorderRadius.circular(1.5),
                ),
              );
            }),
          );
        },
      ),
    );
  }
}

/// 加载中状态的语音条占位
class _PendingAudioBubble extends StatelessWidget {
  final Color textColor;
  const _PendingAudioBubble({required this.textColor});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 100,
      // 移除垂直间距
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
          Text(
            '生成中...',
            style: TextStyle(
              color: textColor.withOpacity(0.8),
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}
