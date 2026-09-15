import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/audio_player_widget.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/message_bubble.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
import 'package:aicove_flutter/src/ui/theme/skin_provider.dart';
import 'package:aicove_flutter/src/ui/theme/skins/moetalk_skin.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/core/models/block_status.dart';
import 'package:aicove_flutter/src/core/models/message_block.dart';
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

  void emitLoading() {
    _playerStateController.add(
      PlayerState(false, ProcessingState.loading),
    );
  }

  void emitError(Object error) {
    _playbackEventController.addError(error);
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

class _FakeAppSettingsNotifier extends AppSettingsNotifier {
  _FakeAppSettingsNotifier(this._settings);

  final AppSettings _settings;

  @override
  Future<AppSettings> build() async => _settings;
}

void _expectNoButtonMaterialInAudioSubtree() {
  for (final type in <Type>[
    MoeButtonSurface,
    MoeFloatingSurface,
    BackdropFilter,
  ]) {
    expect(
      find.descendant(
        of: find.byType(AudioPlayerWidget),
        matching: find.byType(type),
      ),
      findsNothing,
    );
  }
}

Widget _buildPlayerHost({
  required AudioBlock block,
  required Color textColor,
  required AudioPlaybackBackend backend,
  required bool dark,
  required MoeSurfaceMaterial material,
}) {
  final colors = dark ? MoeColors.dark() : MoeColors.light();
  return ProviderScope(
    overrides: [
      audioPlayerControllerProvider.overrideWith(
        (ref, url) => AudioPlayerController(url, backend: backend),
      ),
    ],
    child: MaterialApp(
      theme: ThemeData(
        brightness: dark ? Brightness.dark : Brightness.light,
        extensions: <ThemeExtension<dynamic>>[colors],
      ),
      home: MoeGlassTheme(
        enabled: material != MoeSurfaceMaterial.solid,
        useLiquidGlass: material == MoeSurfaceMaterial.liquid,
        blurSigma: 16,
        child: Scaffold(
          body: Center(
            child: AudioPlayerWidget(block: block, textColor: textColor),
          ),
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('重生成语音替换URL后使用新控制器和新时长，旧控制器释放', (tester) async {
    final oldBackend = _FakeAudioPlaybackBackend(duration: const Duration(seconds: 8));
    final newBackend = _FakeAudioPlaybackBackend(duration: const Duration(seconds: 3));
    final controllers = <String, AudioPlayerController>{};
    final block = ValueNotifier<AudioBlock>(AudioBlock(id: 'audio', messageId: 'm',
        url: 'https://example.invalid/old.wav', text: '原文', durationSeconds: 8));
    addTearDown(block.dispose);
    await tester.pumpWidget(ProviderScope(overrides: [
      audioPlayerControllerProvider.overrideWith((ref, url) {
        return controllers[url] = AudioPlayerController(url,
            backend: url.endsWith('old.wav') ? oldBackend : newBackend);
      }),
    ], child: MaterialApp(home: Scaffold(body: ValueListenableBuilder<AudioBlock>(
        valueListenable: block, builder: (context, value, child) => AudioPlayerWidget(
          key: const ValueKey('same-bubble'), block: value, textColor: Colors.black))))));
    await tester.pumpAndSettle();
    expect(find.text('8"'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.play_arrow_rounded));
    await tester.pump();
    expect(oldBackend.playCalls, 1);
    block.value = AudioBlock(id: 'audio', messageId: 'm',
        url: 'https://example.invalid/new.wav', text: '原文');
    await tester.pumpAndSettle();
    expect(find.text('3"'), findsOneWidget);
    expect(find.text('8"'), findsNothing);
    expect(controllers['https://example.invalid/old.wav']!.mounted, false);
    expect(newBackend.setUrlCalls, ['https://example.invalid/new.wav']);
    await tester.tap(find.byIcon(Icons.play_arrow_rounded));
    await tester.pump();
    expect(newBackend.playCalls, 1);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  for (final width in <double>[390, 1200]) {
    testWidgets('流中语音原位回填后立即可点击播放（${width}px）', (tester) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final backend = _FakeAudioPlaybackBackend(
        duration: const Duration(seconds: 2),
      );
      final block = ValueNotifier<AudioBlock>(AudioBlock(
        messageId: 'stream_audio',
        url: '',
        text: '流中语音',
        status: BlockStatus.pending,
      ));
      addTearDown(block.dispose);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          audioPlayerControllerProvider.overrideWith((ref, url) {
            return AudioPlayerController(url, backend: backend);
          }),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                ValueListenableBuilder<AudioBlock>(
                  valueListenable: block,
                  builder: (context, value, child) => AudioPlayerWidget(
                    key: const ValueKey('stream_audio'),
                    block: value,
                    textColor: Colors.black,
                  ),
                ),
                const Text('生成中...'),
              ],
            ),
          ),
        ),
      ));
      expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
      expect(backend.setUrlCalls, isEmpty);

      block.value = AudioBlock(
        messageId: 'stream_audio',
        url: 'https://example.com/audio.mp3',
        text: '流中语音',
        status: BlockStatus.success,
      );
      await tester.pump();
      await tester.pump();
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
      await tester.tap(find.byIcon(Icons.play_arrow_rounded));
      await tester.pump();
      expect(backend.playCalls, 1);
      expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
      expect(find.text('生成中...'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }

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

  group('语音气泡播放图标不接材质', () {
    const audioUrl = 'https://example.com/voice.mp3';
    const customColor = Color(0xFF345678);

    tearDown(() => MoeLiquidGlassService.setMockState());

    AudioBlock readyBlock() => AudioBlock(
      messageId: 'm',
      url: audioUrl,
      text: '语音',
      durationSeconds: 3,
      status: BlockStatus.success,
    );

    for (final dark in <bool>[false, true]) {
      for (final material in MoeSurfaceMaterial.values) {
        for (final width in <double>[360, 1000]) {
          testWidgets(
            '播放图标无独立材质且用传入颜色 ${material.label}/${dark ? '深色' : '浅色'}/${width.toInt()}px',
            (tester) async {
              tester.view.physicalSize = Size(width, 400);
              tester.view.devicePixelRatio = 1;
              addTearDown(tester.view.resetPhysicalSize);
              addTearDown(tester.view.resetDevicePixelRatio);
              MoeLiquidGlassService.setMockState(available: false);
              final backend = _FakeAudioPlaybackBackend(
                duration: const Duration(seconds: 3),
              );
              await tester.pumpWidget(
                _buildPlayerHost(
                  block: readyBlock(),
                  textColor: customColor,
                  backend: backend,
                  dark: dark,
                  material: material,
                ),
              );
              await tester.pump();
              await tester.pump();
              _expectNoButtonMaterialInAudioSubtree();
              final iconFinder = find.byIcon(Icons.play_arrow_rounded);
              expect(iconFinder, findsOneWidget);
              expect(tester.widget<Icon>(iconFinder).color, customColor);
              expect(tester.getSize(iconFinder), const Size(24, 24));
            },
          );
        }
      }
    }

    testWidgets('点击 24x24 框边角可播放、再点击暂停，图标随状态切换', (tester) async {
      tester.view.physicalSize = const Size(360, 400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      MoeLiquidGlassService.setMockState(available: false);
      final backend = _FakeAudioPlaybackBackend(
        duration: const Duration(seconds: 3),
      );
      await tester.pumpWidget(
        _buildPlayerHost(
          block: readyBlock(),
          textColor: Colors.white,
          backend: backend,
          dark: true,
          material: MoeSurfaceMaterial.frosted,
        ),
      );
      await tester.pump();
      await tester.pump();

      final playFinder = find.byIcon(Icons.play_arrow_rounded);
      expect(tester.widget<Icon>(playFinder).color, Colors.white);
      final playRect = tester.getRect(playFinder);
      await tester.tapAt(playRect.topLeft + const Offset(1, 1));
      await tester.pump();
      await tester.pump();
      expect(backend.playCalls, 1);

      final pauseFinder = find.byIcon(Icons.pause_rounded);
      expect(pauseFinder, findsOneWidget);
      expect(tester.widget<Icon>(pauseFinder).color, Colors.white);
      final pauseRect = tester.getRect(pauseFinder);
      await tester.tapAt(pauseRect.topLeft + const Offset(1, 1));
      await tester.pump();
      await tester.pump();
      expect(backend.pauseCalls, 1);
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
      _expectNoButtonMaterialInAudioSubtree();
    });

    testWidgets('加载态为 24x24 占位且无材质', (tester) async {
      MoeLiquidGlassService.setMockState(available: false);
      final backend = _FakeAudioPlaybackBackend(
        duration: const Duration(seconds: 3),
      );
      await tester.pumpWidget(
        _buildPlayerHost(
          block: readyBlock(),
          textColor: customColor,
          backend: backend,
          dark: false,
          material: MoeSurfaceMaterial.frosted,
        ),
      );
      await tester.pump();
      await tester.pump();
      backend.emitLoading();
      await tester.pump();
      await tester.pump();
      expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
      expect(
        find.descendant(
          of: find.byType(AudioPlayerWidget),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(AudioPlayerWidget),
          matching: find.byWidgetPredicate(
            (w) => w is SizedBox && w.width == 24 && w.height == 24,
          ),
        ),
        findsOneWidget,
      );
      _expectNoButtonMaterialInAudioSubtree();
    });

    testWidgets('错误态重试图标 24x24 同色，点击触发 reload', (tester) async {
      MoeLiquidGlassService.setMockState(available: false);
      final backend = _FakeAudioPlaybackBackend(
        duration: const Duration(seconds: 3),
      );
      await tester.pumpWidget(
        _buildPlayerHost(
          block: readyBlock(),
          textColor: customColor,
          backend: backend,
          dark: false,
          material: MoeSurfaceMaterial.frosted,
        ),
      );
      await tester.pump();
      await tester.pump();
      backend.emitError(StateError('boom'));
      await tester.pump();
      await tester.pump();
      final refreshFinder = find.byIcon(Icons.refresh_rounded);
      expect(refreshFinder, findsOneWidget);
      expect(tester.widget<Icon>(refreshFinder).color, customColor);
      expect(tester.getSize(refreshFinder), const Size(24, 24));
      _expectNoButtonMaterialInAudioSubtree();
      final callsBefore = backend.setUrlCalls.length;
      await tester.tap(refreshFinder);
      await tester.pump();
      await tester.pump();
      expect(backend.setUrlCalls.length, greaterThan(callsBefore));
    });

    testWidgets('pending 无 URL 占位同样无材质', (tester) async {
      MoeLiquidGlassService.setMockState(available: false);
      await tester.pumpWidget(
        _buildPlayerHost(
          block: AudioBlock(
            messageId: 'm',
            url: '',
            text: '语音',
            durationSeconds: 3,
            status: BlockStatus.pending,
          ),
          textColor: customColor,
          backend: _FakeAudioPlaybackBackend(),
          dark: false,
          material: MoeSurfaceMaterial.frosted,
        ),
      );
      await tester.pump();
      expect(
        find.descendant(
          of: find.byType(AudioPlayerWidget),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(AudioPlayerWidget),
          matching: find.byWidgetPredicate(
            (w) => w is SizedBox && w.width == 24 && w.height == 24,
          ),
        ),
        findsOneWidget,
      );
      _expectNoButtonMaterialInAudioSubtree();
    });
  });

  group('语音气泡一体图标预览', () {
    const capture = bool.fromEnvironment('WRITE_AUDIO_BUBBLE_PREVIEW');

    setUpAll(() async {
      if (!capture) return;
      for (final entry in <String, String>{
        'AudioBubblePreview': '/System/Library/Fonts/STHeiti Medium.ttc',
        'MaterialIcons':
            '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      }.entries) {
        final loader = FontLoader(entry.key)
          ..addFont(File(entry.value).readAsBytes().then(ByteData.sublistView));
        await loader.load();
      }
    });

    tearDown(() => MoeLiquidGlassService.setMockState());

    Message voiceMessage(String id, String role, String url, double secs) =>
        Message.fromBlocks(
          id: id,
          role: role,
          blocks: <MessageBlock>[
            AudioBlock(
              messageId: id,
              url: url,
              text: '语音消息',
              durationSeconds: secs,
              status: BlockStatus.success,
            ),
          ],
        );

    for (final dark in <bool>[false, true]) {
      for (final width in <double>[360, 1000]) {
        testWidgets(
          '气泡内图标 ${width.toInt()}px ${dark ? '深色' : '浅色'}',
          (tester) async {
            tester.view.physicalSize = Size(width, 420);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            MoeLiquidGlassService.setMockState(available: false);

            const readyUrl = 'https://example.com/ready.mp3';
            const playingUrl = 'https://example.com/playing.mp3';
            const errorUrl = 'https://example.com/error.mp3';
            final backends = <String, _FakeAudioPlaybackBackend>{
              readyUrl: _FakeAudioPlaybackBackend(
                duration: const Duration(seconds: 3),
              ),
              playingUrl: _FakeAudioPlaybackBackend(
                duration: const Duration(seconds: 12),
              ),
              errorUrl: _FakeAudioPlaybackBackend(
                duration: const Duration(seconds: 30),
              ),
            };
            final fallbackBackend = _FakeAudioPlaybackBackend();
            final settings = mapUiModelsToAppSettings(
              const <String, dynamic>{},
            ).copyWith(expandAudioText: false);
            final colors = dark ? MoeColors.dark() : MoeColors.light();
            final boundaryKey = GlobalKey();

            await tester.pumpWidget(
              ProviderScope(
                overrides: [
                  appSettingsProvider.overrideWith(
                    () => _FakeAppSettingsNotifier(settings),
                  ),
                  audioPlayerControllerProvider.overrideWith(
                    (ref, url) => AudioPlayerController(
                      url,
                      backend: backends[url] ?? fallbackBackend,
                    ),
                  ),
                ],
                child: SkinScope(
                  skin: const MoeTalkSkin(),
                  child: MaterialApp(
                    theme: ThemeData(
                      brightness: dark ? Brightness.dark : Brightness.light,
                      fontFamily: capture ? 'AudioBubblePreview' : null,
                      extensions: <ThemeExtension<dynamic>>[colors],
                    ),
                    home: MoeGlassTheme(
                      enabled: true,
                      useLiquidGlass: false,
                      blurSigma: 16,
                      child: Scaffold(
                        backgroundColor: colors.bgMain,
                        body: RepaintBoundary(
                          key: boundaryKey,
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                MessageBubble(
                                  isMe: false,
                                  message: voiceMessage(
                                    'a1',
                                    'assistant',
                                    readyUrl,
                                    3,
                                  ),
                                  showAvatar: false,
                                ),
                                const SizedBox(height: 12),
                                MessageBubble(
                                  isMe: true,
                                  message: voiceMessage(
                                    'u1',
                                    'user',
                                    playingUrl,
                                    12,
                                  ),
                                  showAvatar: false,
                                ),
                                const SizedBox(height: 12),
                                MessageBubble(
                                  isMe: false,
                                  message: voiceMessage(
                                    'a2',
                                    'assistant',
                                    errorUrl,
                                    30,
                                  ),
                                  showAvatar: false,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pump();
            await tester.pump();
            unawaited(backends[playingUrl]!.play());
            backends[errorUrl]!.emitError(StateError('加载失败'));
            await tester.pump();
            await tester.pump();

            expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
            expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
            expect(find.byIcon(Icons.refresh_rounded), findsOneWidget);
            _expectNoButtonMaterialInAudioSubtree();
            expect(tester.takeException(), isNull);

            if (capture) {
              await tester.runAsync(() async {
                final boundary =
                    boundaryKey.currentContext!.findRenderObject()
                        as RenderRepaintBoundary;
                final image = await boundary.toImage(pixelRatio: 2);
                final data = await image.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                final file = File(
                  '../../scratch/audio-bubble-integrated-20260916/audio-bubble-${width.toInt()}-${dark ? 'dark' : 'light'}.png',
                );
                await file.parent.create(recursive: true);
                await file.writeAsBytes(data!.buffer.asUint8List());
                image.dispose();
              });
            }
          },
        );
      }
    }
  });
}
