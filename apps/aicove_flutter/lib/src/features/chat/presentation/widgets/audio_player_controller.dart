import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import '../../../../core/config.dart';
import '../../../../core/app_logger.dart';

/// 音频播放器状态管理
class AudioPlayerState {
  final bool isPlaying;
  final bool isLoading;
  final bool isReady;
  final Duration position;
  final Duration duration;
  final String? error;

  const AudioPlayerState({
    this.isPlaying = false,
    this.isLoading = false,
    this.isReady = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.error,
  });

  AudioPlayerState copyWith({
    bool? isPlaying,
    bool? isLoading,
    bool? isReady,
    Duration? position,
    Duration? duration,
    String? error,
  }) {
    return AudioPlayerState(
      isPlaying: isPlaying ?? this.isPlaying,
      isLoading: isLoading ?? this.isLoading,
      isReady: isReady ?? this.isReady,
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

/// 全局语音播放协调器
/// 保证同一时间最多只有一个语音条处于播放状态。
/// 当播放下一条语音条时，打断当前正在播放的语音条。
class AudioPlaybackCoordinator {
  static final AudioPlaybackCoordinator shared = AudioPlaybackCoordinator();

  AudioPlayerController? _activeController;
  AudioPlayerController? get activeController => _activeController;

  final StreamController<String> _starts = StreamController<String>.broadcast();

  /// 每次开始播放一条语音时发出它的地址（点播和自动连播都算）。
  Stream<String> get playStarts => _starts.stream;

  /// 本次运行里播放过的语音地址；回复落库晚于播放时据此补记已读。
  final Set<String> heardUrls = <String>{};

  /// 请求播放 [controller]。
  /// 如果当前有其它控制器正在播放，会先打断该控制器。
  void requestPlay(AudioPlayerController controller) {
    if (_activeController == controller) return;
    final previous = _activeController;
    _activeController = controller;
    if (previous != null) {
      unawaited(previous.interrupt());
    }
    heardUrls.add(controller.audioUrl);
    _starts.add(controller.audioUrl);
  }

  /// 释放活跃状态（当控制器暂停、播放完成或销毁时）
  void release(AudioPlayerController controller) {
    if (_activeController == controller) {
      _activeController = null;
    }
  }

  /// 打断并停止所有播放
  Future<void> stopAll() async {
    final active = _activeController;
    _activeController = null;
    if (active != null) {
      await active.interrupt();
    }
  }

  /// 重置协调器状态（主要供测试使用）
  void reset() {
    _activeController = null;
    heardUrls.clear();
  }

  void dispose() {
    unawaited(stopAll());
  }
}

/// 全局语音播放协调器 Provider
final audioPlaybackCoordinatorProvider =
    Provider<AudioPlaybackCoordinator>((ref) {
  return AudioPlaybackCoordinator.shared;
});

/// 音频播放器控制器
class AudioPlayerController extends StateNotifier<AudioPlayerState> {
  final AudioPlaybackBackend _player;
  final String audioUrl;
  final Future<Directory> Function() _temporaryDirectoryProvider;
  final Ref? _ref;
  final AudioPlaybackCoordinator _coordinator;
  KeepAliveLink? _keepAliveLink;
  final List<StreamSubscription<Object?>> _subscriptions =
      <StreamSubscription<Object?>>[];
  bool _completed = false;
  bool _isReady = false; // 标记音频是否已准备就绪
  final bool _autoLoad;
  Future<void>? _playbackCommands;
  int _playbackGeneration = 0;
  Completer<bool>? _playThrough;

  AudioPlayerController(
    this.audioUrl, {
    AudioPlaybackBackend? backend,
    Future<Directory> Function()? temporaryDirectoryProvider,
    Ref? ref,
    AudioPlaybackCoordinator? coordinator,
    bool autoLoad = true,
  }) : _player = backend ?? JustAudioPlaybackBackend(),
       _temporaryDirectoryProvider =
           temporaryDirectoryProvider ?? getTemporaryDirectory,
       // ignore: prefer_initializing_formals
       _ref = ref,
       _coordinator = coordinator ?? AudioPlaybackCoordinator.shared,
       // ignore: prefer_initializing_formals
       _autoLoad = autoLoad,
       super(const AudioPlayerState()) {
    _init();
  }

  void _updateKeepAlive(bool shouldKeepAlive) {
    if (shouldKeepAlive) {
      _keepAliveLink ??= _ref?.keepAlive();
    } else {
      _keepAliveLink?.close();
      _keepAliveLink = null;
    }
  }

  void _init() {
    // 监听播放状态
    _subscriptions.add(
      _player.playerStateStream.listen((playerState) {
        _completed = playerState.processingState == ProcessingState.completed;
        final isPlaying = _completed ? false : playerState.playing;
        if (_completed) {
          _updateKeepAlive(false);
          if (_coordinator.activeController == this) {
            _coordinator.release(this);
          }
          _finishPlayThrough(true);
        }
        if (!mounted) return;
        state = state.copyWith(
          isPlaying: isPlaying,
          isLoading:
              playerState.processingState == ProcessingState.loading ||
              playerState.processingState == ProcessingState.buffering,
        );
      }),
    );

    // 监听总时长（不订阅 positionStream：气泡 UI 不展示实时播放毫秒进度，
    // 而 just_audio 一旦首次访问 positionStream 就会启动 16~200ms 的常驻 Timer.periodic，
    // 即使暂停或未播放也会持续空转唤醒主线程）
    _subscriptions.add(
      _player.durationStream.listen((duration) {
        if (duration != null) {
          if (!mounted) return;
          state = state.copyWith(duration: duration);
        }
      }),
    );

    // 自动加载音频
    _subscriptions.add(
      _player.playbackEventStream.listen(
        (_) {},
        onError: (Object e, StackTrace st) {
          AppLogger.error(
            'AudioPlayer',
            '音频播放流出错',
            metadata: {'error': e.toString()},
          );
          _updateKeepAlive(false);
          _coordinator.release(this);
          _finishPlayThrough(false);
          if (!mounted) return;
          state = state.copyWith(
            isPlaying: false,
            isLoading: false,
            error: '播放出错: $e',
          );
        },
      ),
    );

    if (_autoLoad) {
      _loadAudio();
    }
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

  String _guessFileExtFromBytes(
    List<int> bytes, {
    required String fallbackExt,
  }) {
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
    final cacheDir = Directory(
      '${dir.path}${Platform.pathSeparator}aicove_audio_cache',
    );
    if (!await cacheDir.exists()) {
      await cacheDir.create(recursive: true);
    }

    final file = File(
      '${cacheDir.path}${Platform.pathSeparator}audio_$hash.$ext',
    );
    var shouldRewrite = true;
    if (await file.exists()) {
      try {
        final existingSize = await file.length();
        shouldRewrite = existingSize != bytes.length;
        if (shouldRewrite) {
          AppLogger.warning(
            'AudioPlayer',
            '检测到损坏的语音缓存文件，准备重写',
            metadata: {
              'path': file.path,
              'existingSize': existingSize,
              'expectedSize': bytes.length,
            },
          );
        } else {
          AppLogger.info(
            'AudioPlayer',
            '复用已存在的 data url 语音缓存文件',
            metadata: {'ext': ext, 'size': existingSize, 'path': file.path},
          );
        }
      } on FileSystemException catch (e) {
        shouldRewrite = true;
        AppLogger.warning(
          'AudioPlayer',
          '读取语音缓存文件失败，准备重写',
          metadata: {'path': file.path, 'error': e.toString()},
        );
      }
    }

    if (shouldRewrite) {
      await _writeBytesAtomically(file, bytes);
      AppLogger.info(
        'AudioPlayer',
        '已将 data url 落地为临时文件',
        metadata: {'ext': ext, 'size': bytes.length, 'path': file.path},
      );
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
      state = state.copyWith(isLoading: true, isReady: false, error: null);
      _isReady = false;

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
      state = state.copyWith(isLoading: false, isReady: true);
    } catch (e) {
      AppLogger.error(
        'AudioPlayer',
        '音频加载失败',
        metadata: {'error': e.toString()},
      );
      _isReady = false;
      if (!mounted) return;
      state = state.copyWith(
        isLoading: false,
        isReady: false,
        error: '加载失败: $e',
      );
    }
  }

  Future<void> reload() async {
    await _loadAudio();
  }

  Future<void> _enqueuePlayback(Future<void> Function() command) {
    final previous = _playbackCommands;
    final next = previous == null ? command() : previous.then((_) => command());
    _playbackCommands = next;
    return next.whenComplete(() {
      if (identical(_playbackCommands, next)) _playbackCommands = null;
    });
  }

  Future<void> togglePlayPause() {
    final generation = _playbackGeneration;
    return _enqueuePlayback(() => _togglePlayPause(generation));
  }

  Future<void> _togglePlayPause(int generation) async {
    if (!mounted || generation != _playbackGeneration) return;
    try {
      if (state.error != null) {
        await _loadAudio();
        if (!mounted ||
            generation != _playbackGeneration ||
            state.error != null) {
          return;
        }
      }

      if (state.isPlaying) {
        await _player.pause();
        _updateKeepAlive(false);
        _coordinator.release(this);
        _finishPlayThrough(false);
      } else {
        _coordinator.requestPlay(this);
        _updateKeepAlive(true);

        // 如果音频还没准备好，等待加载完成
        if (!_isReady) {
          await _loadAudio();
          if (!mounted || generation != _playbackGeneration) return;
          if (!_isReady || state.error != null) {
            _updateKeepAlive(false);
            _coordinator.release(this);
            return;
          }
        }

        // just_audio 播完后仍可能保持 playing，先暂停，避免 seek 自动开播。
        if (_completed) await _player.pause();
        if (!mounted || generation != _playbackGeneration) return;

        // 每次点播放都从头开始，包括暂停或被其它语音打断之后。
        await _player.seek(Duration.zero);
        if (!mounted || generation != _playbackGeneration) return;
        _completed = false;
        state = state.copyWith(position: Duration.zero);

        // play 的 Future 到暂停/结束才返回，不能阻塞下一次播放操作。
        unawaited(
          _player.play().catchError((Object error) {
            _reportPlaybackFailure(error, generation);
          }),
        );
      }
    } catch (e) {
      _reportPlaybackFailure(e, generation);
    }
  }

  void _reportPlaybackFailure(Object error, int generation) {
    if (!mounted || generation != _playbackGeneration) return;
    _updateKeepAlive(false);
    _coordinator.release(this);
    _finishPlayThrough(false);
    state = state.copyWith(
      isPlaying: false,
      isLoading: false,
      error: '播放失败: $error',
    );
  }

  /// 从头播放并等到结束：播完返回 true；被暂停、打断或出错返回 false。
  /// 正在播放时只等它播完。
  Future<bool> playToEnd() async {
    final pending = _playThrough ??= Completer<bool>();
    if (!state.isPlaying) {
      await togglePlayPause();
      if (state.error != null || !_isReady) _finishPlayThrough(false);
    }
    return pending.future;
  }

  void _finishPlayThrough(bool completed) {
    final pending = _playThrough;
    _playThrough = null;
    if (pending != null && !pending.isCompleted) pending.complete(completed);
  }

  /// 被下一条语音打断时调用
  Future<void> interrupt() {
    // 立即取消尚在加载/归零的开播请求，再排队完成原生暂停与归零。
    _playbackGeneration++;
    return _enqueuePlayback(_interrupt);
  }

  Future<void> _interrupt() async {
    if (!mounted) return;
    try {
      await _player.pause();
      if (!mounted) return;
      await _player.seek(Duration.zero);
    } catch (e) {
      AppLogger.warning(
        'AudioPlayer',
        '打断语音播放失败',
        metadata: {'error': e.toString()},
      );
    }
    _completed = false;
    _updateKeepAlive(false);
    _coordinator.release(this);
    _finishPlayThrough(false);
    if (mounted) {
      state = state.copyWith(
        isPlaying: false,
        position: Duration.zero,
      );
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
    _playbackGeneration++;
    _updateKeepAlive(false);
    _coordinator.release(this);
    _finishPlayThrough(false);
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
      (ref, audioUrl) {
        final coordinator = ref.watch(audioPlaybackCoordinatorProvider);
        return AudioPlayerController(
          audioUrl,
          ref: ref,
          coordinator: coordinator,
          autoLoad: false,
        );
      },
    );
