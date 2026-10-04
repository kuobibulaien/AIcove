import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/core/database/database.dart';
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/core/media/media_store.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/audio_player_widget.dart';
import 'package:aicove_flutter/src/features/sync/data/cloud_local_store.dart';
import 'package:aicove_flutter/src/features/sync/data/cloud_sync_scheduler.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/moe_chat_header.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/moe_liquid_glass.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _enabled = bool.fromEnvironment('RUN_POWER_MECHANISM_AUDIT');

class _SilentAudioBackend implements AudioPlaybackBackend {
  @override
  Stream<PlayerState> get playerStateStream => const Stream.empty();
  @override
  Stream<Duration> get positionStream => const Stream.empty();
  @override
  Stream<Duration?> get durationStream => const Stream.empty();
  @override
  Stream<PlaybackEvent> get playbackEventStream => const Stream.empty();
  @override
  Duration get position => Duration.zero;
  @override
  Future<Duration?> setFilePath(String path) async =>
      const Duration(seconds: 2);
  @override
  Future<Duration?> setUrl(String url) async => const Duration(seconds: 2);
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> dispose() async {}
}

class _RecordingLocalStore extends CloudLocalStore {
  _RecordingLocalStore(
    super.db,
    super.preferences,
    super.documents,
    super.support,
  );
  final queries = <String>[];

  @override
  Future<List<Map<String, dynamic>>> rows(
    String sql, [
    List<Object?> args = const [],
  ]) async {
    queries.add(sql);
    if (scanned && sql.contains('embedded_media_scanned_v1')) {
      return [
        {'1': 1},
      ];
    }
    return [];
  }

  bool scanned = false;

  @override
  Future<void> execute(String sql, [List<Object?> args = const []]) async {
    // Only the sync bookkeeping marker for a finished full scan is allowed.
    if (sql.contains("VALUES('embedded_media_scanned_v1')")) {
      scanned = true;
      return;
    }
    throw StateError('This audit must not write application data');
  }
}

Widget _host(Widget child, {bool liquid = false, bool dark = false}) =>
    MaterialApp(
      theme: ThemeData(
        brightness: dark ? Brightness.dark : Brightness.light,
        extensions: [dark ? MoeColors.dark() : MoeColors.light()],
      ),
      home: MoeGlassTheme(
        enabled: liquid,
        useLiquidGlass: liquid,
        blurSigma: 16,
        child: Scaffold(body: Center(child: child)),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group(
    'opt-in power mechanism investigation, not device power measurement',
    () {
      setUpAll(() async {
        if (ui.ImageFilter.isShaderFilterSupported) {
          for (final name in [
            'liquid_glass_render.frag',
            'liquid_glass_geometry_blended.frag',
          ]) {
            final target = File('build/unit_test_assets/shaders/$name');
            await target.parent.create(recursive: true);
            await File(
              'build/unit_test_assets/packages/liquid_glass_widgets/shaders/$name',
            ).copy(target.path);
          }
        }
        await LiquidGlassWidgets.initialize(enablePerformanceMonitor: false);
        MoeLiquidGlassService.setMockState(available: true);
      });

      testWidgets('ready unplayed audio should stop scheduling frames', (
        tester,
      ) async {
        final controller = AudioPlayerController(
          'https://example.invalid/synthetic-audio.wav',
          backend: _SilentAudioBackend(),
        );
        await tester.runAsync(() async {
          await Future<void>.delayed(Duration.zero);
        });
        expect(controller.state.isLoading, isFalse);
        expect(controller.state.isPlaying, isFalse);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              audioPlayerControllerProvider.overrideWith(
                (ref, url) => controller,
              ),
            ],
            child: _host(
              AudioPlayerWidget(
                block: AudioBlock(
                  id: 'audit-audio',
                  messageId: 'audit-message',
                  url: 'https://example.invalid/synthetic-audio.wav',
                  durationSeconds: 2,
                ),
                textColor: Colors.black,
              ),
            ),
          ),
        );
        await tester.pump(const Duration(seconds: 2));
        var scheduledAfterPump = 0;
        for (var i = 0; i < 30; i++) {
          await tester.pump(const Duration(milliseconds: 16));
          if (tester.binding.hasScheduledFrame) scheduledAfterPump++;
        }
        final activeCallbacks = tester.binding.transientCallbackCount;
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        debugPrint(
          '[PowerMechanism] unplayedAudio scheduledAfterPump=$scheduledAfterPump/30 activeCallbacks=$activeCallbacks',
        );
        expect(
          scheduledAfterPump,
          0,
          reason:
              'A ready, never-played waveform must not keep scheduling frames',
        );
      });

      testWidgets(
        'freshly created unplayed audio settles after load notification',
        (tester) async {
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                audioPlayerControllerProvider.overrideWith(
                  (ref, url) => AudioPlayerController(
                    url,
                    backend: _SilentAudioBackend(),
                  ),
                ),
              ],
              child: _host(
                AudioPlayerWidget(
                  block: AudioBlock(
                    id: 'audit-fresh-audio',
                    messageId: 'audit-fresh-message',
                    url: 'https://example.invalid/synthetic-fresh-audio.wav',
                    durationSeconds: 2,
                  ),
                  textColor: Colors.black,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle(
            const Duration(milliseconds: 100),
            EnginePhase.sendSemanticsUpdate,
            const Duration(seconds: 5),
          );
          expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
          var scheduledAfterPump = 0;
          for (var i = 0; i < 30; i++) {
            await tester.pump(const Duration(milliseconds: 16));
            if (tester.binding.hasScheduledFrame) scheduledAfterPump++;
          }
          debugPrint(
            '[PowerMechanism] freshlyCreatedUnplayedAudio scheduledAfterPump=$scheduledAfterPump/30',
          );
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          expect(scheduledAfterPump, 0);
        },
      );

      testWidgets('header requests independent premium surfaces', (
        tester,
      ) async {
        await tester.pumpWidget(
          _host(
            const MoeChatHeader(
              title: Text('Synthetic header'),
              actions: [Icon(Icons.more_horiz)],
              showBackButton: true,
              nativeInset: 0,
              toolbarHeight: 56,
            ),
            liquid: true,
          ),
        );
        await tester.pumpAndSettle(
          const Duration(milliseconds: 100),
          EnginePhase.sendSemanticsUpdate,
          const Duration(seconds: 5),
        );
        final surfaces = tester
            .widgetList<AdaptiveGlass>(find.byType(AdaptiveGlass))
            .toList();
        expect(surfaces.length, 3);
        expect(
          surfaces.every((surface) => surface.quality == GlassQuality.premium),
          isTrue,
        );
        expect(surfaces.every((surface) => surface.useOwnLayer), isTrue);
        final renderedLayers = tester
            .widgetList<LiquidGlassLayer>(find.byType(LiquidGlassLayer))
            .toList();
        if (ui.ImageFilter.isShaderFilterSupported) {
          expect(renderedLayers.length, 3);
          expect(
            renderedLayers.every((layer) => layer.captureImage == null),
            isTrue,
          );
        }
        var scheduledAfterPump = 0;
        for (var i = 0; i < 30; i++) {
          await tester.pump(const Duration(milliseconds: 16));
          if (tester.binding.hasScheduledFrame) scheduledAfterPump++;
        }
        debugPrint(
          '[PowerMechanism] header requestedPremium=${surfaces.length} shaderSupported=${ui.ImageFilter.isShaderFilterSupported} renderedLayers=${renderedLayers.length} idleScheduledAfterPump=$scheduledAfterPump/30',
        );
        expect(
          scheduledAfterPump,
          0,
          reason:
              'A static glass surface should not itself drive a continuous animation',
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      });

      for (final dark in [false, true]) {
        testWidgets(
          'explicit empty outer shadows leaves library shadows dark=$dark',
          (tester) async {
            await tester.pumpWidget(
              _host(
                const MoeLiquidGlass(
                  width: 180,
                  height: 60,
                  shadows: [],
                  child: Text('Synthetic surface'),
                ),
                liquid: true,
                dark: dark,
              ),
            );
            await tester.pumpAndSettle(
              const Duration(milliseconds: 100),
              EnginePhase.sendSemanticsUpdate,
              const Duration(seconds: 5),
            );
            final adaptive = tester.widget<AdaptiveGlass>(
              find.byType(AdaptiveGlass),
            );
            expect(adaptive.settings.effectiveShadow.length, 2);
            final layers = tester
                .widgetList<LiquidGlassLayer>(find.byType(LiquidGlassLayer))
                .toList();
            if (ui.ImageFilter.isShaderFilterSupported) {
              expect(layers.length, 1);
              expect(layers.single.shadows.length, dark ? 0 : 2);
            }
            debugPrint(
              '[PowerMechanism] outerShadows=0 dark=$dark libraryShadowRecipe=${adaptive.settings.effectiveShadow.length} renderedLayerShadows=${layers.map((layer) => layer.shadows.length).toList()}',
            );
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pump();
          },
        );
      }

      testWidgets('idle scheduler stays off the network between daily rounds', (
        tester,
      ) async {
        SharedPreferences.setMockInitialValues({});
        final preferences = await tester.runAsync(
          SharedPreferences.getInstance,
        );
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        final local = CloudLocalStore(
          database,
          preferences!,
          Directory.systemTemp,
          Directory.systemTemp,
        );
        var rounds = 0;
        final scheduler = CloudSyncScheduler(local, () async {
          rounds++;
          return true;
        });
        try {
          scheduler.start();
          for (var i = 0; i < 8; i++) {
            await tester.pump(const Duration(minutes: 15));
          }
          expect(rounds, 1);
          debugPrint(
            '[PowerMechanism] syntheticIdle2h rounds=$rounds noDatabaseEdits=true',
          );
        } finally {
          scheduler.close();
          await tester.runAsync(database.close);
        }
      });

      test(
        'after the first full pass, media compaction scans only pending edits',
        () async {
          SharedPreferences.setMockInitialValues({});
          final database = AppDatabase.forTesting(NativeDatabase.memory());
          final local = _RecordingLocalStore(
            database,
            await SharedPreferences.getInstance(),
            Directory.systemTemp,
            Directory.systemTemp,
          );
          try {
            final media = MediaStore(Directory.systemTemp, 'synthetic-audit');
            await local.compactEmbeddedMedia(mediaStore: media);
            await local.compactEmbeddedMedia(mediaStore: media);
            final scans = local.queries
                .where((sql) => sql.contains("instr("))
                .toList();
            expect(scans.length, 4);
            expect(
              scans.take(2).where((sql) => sql.contains('cloud_dirty')),
              isEmpty,
            );
            expect(
              scans.skip(2).every((sql) => sql.contains('cloud_dirty')),
              isTrue,
            );
            debugPrint(
              '[PowerMechanism] emptyCompactionInvocations=2 payloadScanQueries=${scans.length} realDatabaseQueries=0 networkCalls=0',
            );
          } finally {
            await database.close();
          }
        },
      );
    },
    skip: !_enabled,
  );
}
