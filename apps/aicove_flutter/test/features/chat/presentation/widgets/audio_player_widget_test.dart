import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aicove_flutter/src/features/chat/presentation/widgets/audio_player_widget.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';

class _FakeAudioPlaybackBackend implements AudioPlaybackBackend {
  _FakeAudioPlaybackBackend({
    Duration? duration,
    this.initialPosition = Duration.zero,
  })  : _duration = duration,
        _position = initialPosition;

  final Duration initialPosition;
  final _playerStateController = StreamController<PlayerState>.broadcast();
  final _positionController = StreamController<Duration>.broadcast();
  final _durationController = StreamController<Duration?>.broadcast();
  final _playbackEventController = StreamController<PlaybackEvent>.broadcast();

  final List<String> setUrlCalls = <String>[];
  final List<String> setFilePathCalls = <String>[];
  final List<Duration> seekCalls = <Duration>[];
  int playCalls = 0;
  int pauseCalls = 0;
  final Duration? _duration;
  Duration _position;

  @override
  Stream<PlayerState> get playerStateStream => _playerStateController.stream;

  @override
  Stream<Duration> get positionStream => _positionController.stream;

  @override
  Stream<Duration?> get durationStream => _durationController.stream;

  @override
  Stream<PlaybackEvent> get playbackEventStream =>
      _playbackEventController.stream;

  @override
  Duration get position => _position;

  @override
  Future<Duration?> setFilePath(String path) async {
    setFilePathCalls.add(path);
    _emitReady();
    return _duration;
  }

  @override
  Future<Duration?> setUrl(String url) async {
    setUrlCalls.add(url);
    _emitReady();
    return _duration;
  }

  @override
  Future<void> play() async {
    playCalls += 1;
    _playerStateController.add(
      PlayerState(true, ProcessingState.ready),
    );
  }

  @override
  Future<void> pause() async {
    pauseCalls += 1;
    _playerStateController.add(
      PlayerState(false, ProcessingState.ready),
    );
  }

  @override
  Future<void> seek(Duration position) async {
    seekCalls.add(position);
    _position = position;
    _positionController.add(position);
    _playerStateController.add(
      PlayerState(false, ProcessingState.ready),
    );
  }

  void emitCompleted() {
    final completedPosition = _duration ?? Duration.zero;
    _position = completedPosition;
    _positionController.add(completedPosition);
    _playerStateController.add(
      PlayerState(false, ProcessingState.completed),
    );
    _playbackEventController.add(
      PlaybackEvent(
        processingState: ProcessingState.completed,
        duration: _duration,
        updatePosition: completedPosition,
      ),
    );
  }

  void _emitReady() {
    _durationController.add(_duration);
    _positionController.add(_position);
    _playerStateController.add(
      PlayerState(false, ProcessingState.ready),
    );
    _playbackEventController.add(
      PlaybackEvent(
        processingState: ProcessingState.ready,
        duration: _duration,
        updatePosition: _position,
      ),
    );
  }

  @override
  Future<void> dispose() async {
    await _playerStateController.close();
    await _positionController.close();
    await _durationController.close();
    await _playbackEventController.close();
  }
}

Future<void> _settleAsync() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

Future<void> _waitUntil(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final sw = Stopwatch()..start();
  while (!predicate()) {
    if (sw.elapsed > timeout) {
      throw TimeoutException('Condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

List<int> _buildWavBytes() {
  const payload = <int>[0x00, 0x00, 0x10, 0x10];
  final dataSize = payload.length;
  final fileSize = 36 + dataSize;
  return <int>[
    0x52,
    0x49,
    0x46,
    0x46,
    fileSize & 0xff,
    (fileSize >> 8) & 0xff,
    (fileSize >> 16) & 0xff,
    (fileSize >> 24) & 0xff,
    0x57,
    0x41,
    0x56,
    0x45,
    0x66,
    0x6d,
    0x74,
    0x20,
    16,
    0,
    0,
    0,
    1,
    0,
    1,
    0,
    0x40,
    0x1f,
    0,
    0,
    0x80,
    0x3e,
    0,
    0,
    2,
    0,
    16,
    0,
    0x64,
    0x61,
    0x74,
    0x61,
    dataSize & 0xff,
    (dataSize >> 8) & 0xff,
    (dataSize >> 16) & 0xff,
    (dataSize >> 24) & 0xff,
    ...payload,
  ];
}

String _buildDataUrl(String mimeType, List<int> bytes) {
  return 'data:$mimeType;base64,${base64Encode(bytes)}';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AudioPlayerController', () {
    test('播放完成后不应立即 pause+seek 回卷，应在下次播放时再从头开始', () async {
      final backend = _FakeAudioPlaybackBackend(
        duration: const Duration(seconds: 2),
      );
      final controller = AudioPlayerController(
        'https://example.com/audio.mp3',
        backend: backend,
        temporaryDirectoryProvider: () async => Directory.systemTemp,
      );
      addTearDown(controller.dispose);

      await _waitUntil(() => backend.setUrlCalls.isNotEmpty);

      await controller.togglePlayPause();
      expect(backend.seekCalls, <Duration>[Duration.zero]);
      backend.seekCalls.clear();
      backend.playCalls = 0;

      backend.emitCompleted();
      await _settleAsync();

      expect(backend.pauseCalls, 0);
      expect(backend.seekCalls, isEmpty);

      await controller.togglePlayPause();

      expect(backend.seekCalls, <Duration>[Duration.zero]);
      expect(backend.playCalls, 1);
    });

    test('首次播放即使只有轻微初始偏移，也应先 seek 到 0 秒', () async {
      final backend = _FakeAudioPlaybackBackend(
        initialPosition: const Duration(milliseconds: 20),
      );
      final controller = AudioPlayerController(
        'https://example.com/audio.mp3',
        backend: backend,
        temporaryDirectoryProvider: () async => Directory.systemTemp,
      );
      addTearDown(controller.dispose);

      await _waitUntil(() => backend.setUrlCalls.isNotEmpty);

      await controller.togglePlayPause();

      expect(backend.seekCalls, <Duration>[Duration.zero]);
      expect(backend.playCalls, 1);
    });

    test('data url 缓存文件损坏时，reload 应重写完整音频文件', () async {
      final tempDir = await Directory.systemTemp.createTemp('audio_cache_test');
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final backend = _FakeAudioPlaybackBackend();
      final bytes = _buildWavBytes();
      final controller = AudioPlayerController(
        _buildDataUrl('audio/wav', bytes),
        backend: backend,
        temporaryDirectoryProvider: () async => tempDir,
      );
      addTearDown(controller.dispose);

      await _waitUntil(() => backend.setFilePathCalls.isNotEmpty);

      final cachedPath = backend.setFilePathCalls.single;
      final cachedFile = File(cachedPath);
      expect(await cachedFile.length(), bytes.length);

      await cachedFile.writeAsBytes(const <int>[1, 2, 3], flush: true);
      expect(await cachedFile.length(), 3);

      await controller.reload();
      await _settleAsync();

      expect(backend.setFilePathCalls, hasLength(2));
      expect(await cachedFile.length(), bytes.length);
      expect(await cachedFile.readAsBytes(), bytes);
    });

    test('audio/mp4 data url 应落地为 m4a 文件，避免平台按 bin 解码', () async {
      final tempDir = await Directory.systemTemp.createTemp('audio_ext_test');
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final backend = _FakeAudioPlaybackBackend();
      final mp4LikeBytes = <int>[
        0,
        0,
        0,
        20,
        0x66,
        0x74,
        0x79,
        0x70,
        0x4d,
        0x34,
        0x41,
        0x20,
        0,
        0,
        0,
        0,
        0x4d,
        0x34,
        0x41,
        0x20,
      ];
      final controller = AudioPlayerController(
        _buildDataUrl('audio/mp4', mp4LikeBytes),
        backend: backend,
        temporaryDirectoryProvider: () async => tempDir,
      );
      addTearDown(controller.dispose);

      await _waitUntil(() => backend.setFilePathCalls.isNotEmpty);

      expect(backend.setFilePathCalls.single, endsWith('.m4a'));
    });
  });
}
