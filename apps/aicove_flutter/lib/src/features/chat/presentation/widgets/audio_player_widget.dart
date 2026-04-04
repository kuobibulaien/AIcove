import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../core/models/message_block.dart';
import '../../../../core/config.dart';
import '../../../../core/models/block_status.dart';
import '../../../../core/app_logger.dart';

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

abstract class AudioPlaybackBackend {
  Stream<PlayerState> get playerStateStream;
  Stream<Duration> get positionStream;
  Stream<Duration?> get durationStream;
  Stream<PlaybackEvent> get playbackEventStream;
  Duration get position;

  Future<Duration?> setUrl(String url);
  Future<Duration?> setFilePath(String path);
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> dispose();
}

class JustAudioPlaybackBackend implements AudioPlaybackBackend {
  JustAudioPlaybackBackend() : _player = AudioPlayer();

  final AudioPlayer _player;

  @override
  Stream<PlayerState> get playerStateStream => _player.playerStateStream;

  @override
  Stream<Duration> get positionStream => _player.positionStream;

  @override
  Stream<Duration?> get durationStream => _player.durationStream;

  @override
  Stream<PlaybackEvent> get playbackEventStream => _player.playbackEventStream;

  @override
  Duration get position => _player.position;

  @override
  Future<Duration?> setUrl(String url) => _player.setUrl(url);

  @override
  Future<Duration?> setFilePath(String path) => _player.setFilePath(path);

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> dispose() => _player.dispose();
}

/// 音频播放器控制器
class AudioPlayerController extends StateNotifier<AudioPlayerState> {
  final AudioPlaybackBackend _player;
  final String audioUrl;
  final Future<Directory> Function() _temporaryDirectoryProvider;
  final List<StreamSubscription<Object?>> _subscriptions =
      <StreamSubscription<Object?>>[];
  bool _completed = false;
  bool _isReady = false; // 标记音频是否已准备就绪
  bool _hasStartedPlayback = false;

  AudioPlayerController(
    this.audioUrl, {
    AudioPlaybackBackend? backend,
    Future<Directory> Function()? temporaryDirectoryProvider,
  })  : _player = backend ?? JustAudioPlaybackBackend(),
        _temporaryDirectoryProvider =
            temporaryDirectoryProvider ?? getTemporaryDirectory,
        super(const AudioPlayerState()) {
    _init();
  }

  void _init() {
    // 监听播放状态
    _subscriptions.add(_player.playerStateStream.listen((playerState) {
      _completed = playerState.processingState == ProcessingState.completed;
      if (!mounted) return;
      state = state.copyWith(
        isPlaying: _completed ? false : playerState.playing,
        isLoading: playerState.processingState == ProcessingState.loading ||
            playerState.processingState == ProcessingState.buffering,
      );
    }));

    // 监听播放位置
    _subscriptions.add(_player.positionStream.listen((position) {
      if (!mounted) return;
      state = state.copyWith(position: position);
    }));

    // 监听总时长
    _subscriptions.add(_player.durationStream.listen((duration) {
      if (duration != null) {
        if (!mounted) return;
        state = state.copyWith(duration: duration);
      }
    }));

    // 自动加载音频
    _subscriptions.add(_player.playbackEventStream.listen((_) {},
        onError: (Object e, StackTrace st) {
      AppLogger.error('AudioPlayer', '音频播放流出错', metadata: {
        'error': e.toString(),
      });
      if (!mounted) return;
      state = state.copyWith(
        isPlaying: false,
        isLoading: false,
        error: '播放出错: $e',
      );
    }));

    _loadAudio();
  }

  bool _isHttpUrl(String url) =>
      url.startsWith('http://') || url.startsWith('https://');

  bool _isDataUrl(String url) => url.startsWith('data:');

  bool _isFileUrl(String url) => url.startsWith('file://');

  bool _looksLikeAbsoluteFilePath(String path) {
    if (path.startsWith('/')) return true; // Android/iOS
    return RegExp(r'^[a-zA-Z]:\\\\').hasMatch(path); // Windows
  }

  String _guessFileExtFromMime(String mime) {
    final m = mime.toLowerCase();
    if (m.contains('wav')) return 'wav';
    if (m.contains('ogg')) return 'ogg';
    if (m.contains('opus')) return 'opus';
    if (m.contains('mpeg') || m.contains('mp3')) return 'mp3';
    if (m.contains('aac')) return 'aac';
    if (m.contains('m4a') || m.contains('mp4')) return 'm4a';
    return 'bin';
  }

  String _guessFileExtFromBytes(List<int> bytes,
      {required String fallbackExt}) {
    bool startsWithAscii(String s) {
      if (bytes.length < s.length) return false;
      for (var i = 0; i < s.length; i++) {
        if (bytes[i] != s.codeUnitAt(i)) return false;
      }
      return true;
    }

    if (startsWithAscii('RIFF') &&
        bytes.length >= 12 &&
        String.fromCharCodes(bytes.sublist(8, 12)) == 'WAVE') {
      return 'wav';
    }
    if (startsWithAscii('OggS')) return 'ogg';
    if (bytes.length >= 12 &&
        String.fromCharCodes(bytes.sublist(4, 8)) == 'ftyp') {
      return fallbackExt == 'bin' ? 'm4a' : fallbackExt;
    }
    if (startsWithAscii('ID3')) return 'mp3';
    if (bytes.length >= 2 && bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0) {
      return 'mp3';
    }
    if (bytes.length >= 2 && bytes[0] == 0xFF && (bytes[1] & 0xF6) == 0xF0) {
      return fallbackExt == 'bin' ? 'aac' : fallbackExt;
    }
    return fallbackExt;
  }

  Future<void> _writeBytesAtomically(File file, List<int> bytes) async {
    final tempFile = File(
      '${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    await tempFile.writeAsBytes(bytes, flush: true);
    if (await file.exists()) {
      await file.delete();
    }
    await tempFile.rename(file.path);
  }

  Future<String> _writeDataUrlToTempFile(String dataUrl) async {
    final commaIndex = dataUrl.indexOf(',');
    if (commaIndex <= 'data:'.length) {
      throw Exception('data url 格式不正确');
    }

    final meta = dataUrl.substring('data:'.length, commaIndex);
    final dataPart = dataUrl.substring(commaIndex + 1);

    final parts = meta.split(';');
    final mime = parts.isNotEmpty ? parts.first : 'application/octet-stream';
    final isBase64 = parts.any((p) => p.toLowerCase() == 'base64');
    if (!isBase64) {
      throw Exception('暂不支持非 base64 的 data url');
    }

    final bytes = base64Decode(dataPart);
    if (bytes.isEmpty) {
      throw Exception('音频数据为空');
    }

    final fallbackExt = _guessFileExtFromMime(mime);
    final ext = _guessFileExtFromBytes(bytes, fallbackExt: fallbackExt);
    final hash = md5.convert(utf8.encode(dataUrl)).toString();

    final dir = await _temporaryDirectoryProvider();
    final cacheDir =
        Directory('${dir.path}${Platform.pathSeparator}aicove_audio_cache');
    if (!await cacheDir.exists()) {
      await cacheDir.create(recursive: true);
    }

    final file =
        File('${cacheDir.path}${Platform.pathSeparator}audio_$hash.$ext');
    var shouldRewrite = true;
    if (await file.exists()) {
      try {
        final existingSize = await file.length();
        shouldRewrite = existingSize != bytes.length;
        if (shouldRewrite) {
          AppLogger.warning('AudioPlayer', '检测到损坏的语音缓存文件，准备重写', metadata: {
            'path': file.path,
            'existingSize': existingSize,
            'expectedSize': bytes.length,
          });
        } else {
          AppLogger.info('AudioPlayer', '复用已存在的 data url 语音缓存文件', metadata: {
            'ext': ext,
            'size': existingSize,
            'path': file.path,
          });
        }
      } on FileSystemException catch (e) {
        shouldRewrite = true;
        AppLogger.warning('AudioPlayer', '读取语音缓存文件失败，准备重写', metadata: {
          'path': file.path,
          'error': e.toString(),
        });
      }
    }

    if (shouldRewrite) {
      await _writeBytesAtomically(file, bytes);
      AppLogger.info('AudioPlayer', '已将 data url 落地为临时文件', metadata: {
        'ext': ext,
        'size': bytes.length,
        'path': file.path,
      });
    }

    return file.path;
  }

  Future<String> _resolvePlayableSource(String rawUrl) async {
    if (_isHttpUrl(rawUrl)) return rawUrl;

    if (_isDataUrl(rawUrl)) {
      return _writeDataUrlToTempFile(rawUrl);
    }

    if (_isFileUrl(rawUrl)) {
      return Uri.parse(rawUrl).toFilePath();
    }

    if (_looksLikeAbsoluteFilePath(rawUrl) && await File(rawUrl).exists()) {
      return rawUrl;
    }

    return '${resolvedApiBase()}$rawUrl';
  }

  Future<void> _loadAudio() async {
    try {
      if (!mounted) return;
      state = state.copyWith(isLoading: true, error: null);
      _isReady = false;
      _hasStartedPlayback = false;

      // 构建完整URL
      final resolved = await _resolvePlayableSource(audioUrl);
      if (!mounted) return;

      if (_isHttpUrl(resolved)) {
        await _player.setUrl(resolved);
      } else if (await File(resolved).exists()) {
        await _player.setFilePath(resolved);
      } else {
        await _player.setUrl(resolved);
      }
      if (!mounted) return;

      // 音频加载完成，标记为就绪
      _isReady = true;
      state = state.copyWith(isLoading: false);
    } catch (e) {
      AppLogger.error('AudioPlayer', '音频加载失败', metadata: {
        'error': e.toString(),
      });
      _isReady = false;
      if (!mounted) return;
      state = state.copyWith(
        isLoading: false,
        error: '加载失败: $e',
      );
    }
  }

  Future<void> reload() async {
    await _loadAudio();
  }

  Future<void> togglePlayPause() async {
    try {
      if (state.error != null) {
        await _loadAudio();
        if (state.error != null) return;
      }

      if (state.isPlaying) {
        await _player.pause();
      } else {
        // 如果音频还没准备好，等待加载完成
        if (!_isReady) {
          await _loadAudio();
          if (!_isReady || state.error != null) return;
        }

        // 首次播放或播放完成后重播，都从头开始
        // 这样可以避免首次播放时因为缓冲导致的"吞字"问题
        if (_completed ||
            state.position >= state.duration &&
                state.duration > Duration.zero) {
          await _player.seek(Duration.zero);
          _completed = false;
        }

        // 首次播放时，无条件归零一次。
        // 实机上初始偏移可能只有几十毫秒，100ms 阈值会漏掉这种情况。
        if (!_hasStartedPlayback) {
          await _player.seek(Duration.zero);
        }

        await _player.play();
        _hasStartedPlayback = true;
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
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_player.dispose());
    super.dispose();
  }
}

/// Provider工厂：为每个音频URL创建独立的控制器
final audioPlayerControllerProvider = StateNotifierProvider.autoDispose
    .family<AudioPlayerController, AudioPlayerState, String>(
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
      return _PendingAudioBubble(block: block, textColor: textColor);
    }

    final state = ref.watch(audioPlayerControllerProvider(block.url));
    final controller =
        ref.read(audioPlayerControllerProvider(block.url).notifier);

    // 优先使用 block 中的 durationSeconds，如果没有则尝试使用 state 中的 duration
    final double durationSec = block.durationSeconds ??
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
        child: Icon(
          Icons.refresh_rounded,
          color: color.withValues(alpha: 0.9),
          size: size,
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
      duration: kAnimLong,
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
                heightFactor = 0.3 +
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
                decoration: MoeG2Decoration(
                  radius: 1.5,
                  color: widget.color
                      .withValues(alpha: widget.isPlaying ? 0.9 : 0.6),
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
  final AudioBlock block;
  final Color textColor;
  const _PendingAudioBubble({
    required this.block,
    required this.textColor,
  });

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
