import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:just_audio/just_audio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/chat_actions.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/audio_player_widget.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_message_list.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_viewport_controller.dart';
import 'package:aicove_flutter/src/ui/theme/skin_provider.dart';
import 'package:aicove_flutter/src/ui/theme/skins/moetalk_skin.dart';

class _Backend implements AudioPlaybackBackend {
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
  Future<Duration?> setUrl(String url) async => const Duration(seconds: 8);
  @override
  Future<Duration?> setFilePath(String path) async =>
      const Duration(seconds: 8);
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> dispose() async {}
}

class _Settings extends AppSettingsNotifier {
  @override
  Future<AppSettings> build() async => mapUiModelsToAppSettings({}).copyWith(
      expandAudioText: true,
      enhancedDialogueSettings: const EnhancedDialogueSettings(enabled: true));
}

class _Actions extends ChatActions {
  _Actions(super.ref);
  final calls = <(String, String, String)>[];
  @override
  Future<void> regenerateMedia(
      {required String conversationId,
      required String messageId,
      required String blockId}) async {
    calls.add((conversationId, messageId, blockId));
  }
}

void main() {
  for (final width in [360.0, 1000.0]) {
    testWidgets('真实语音气泡右键仅重合成语音，保留转文字入口 $width', (tester) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      late _Actions actions;
      final container = ProviderContainer(overrides: [
        databaseProvider.overrideWithValue(database),
        audioPlayerControllerProvider.overrideWith(
            (ref, url) => AudioPlayerController(url, backend: _Backend())),
        appSettingsProvider.overrideWith(_Settings.new),
        chatActionsProvider.overrideWith((ref) => actions = _Actions(ref))
      ]);
      addTearDown(() async {
        container.dispose();
        await database.close();
      });
      await container.read(appSettingsProvider.future);
      final viewport = ChatViewportController();
      addTearDown(viewport.dispose);
      var wholeReplyCalls = 0;
      final message = Message.fromBlocks(
          id: 'audio',
          role: 'assistant',
          status: 'sent',
          blocks: [
            // Keep the playback backend offline; gesture routing is the assertion.
            AudioBlock(
                id: 'voice',
                messageId: 'audio',
                url: 'https://example.invalid/audio.wav',
                text: '原语音内容',
                durationSeconds: 8),
          ]);
      await tester.pumpWidget(UncontrolledProviderScope(
          container: container,
          child: SkinScope(
              skin: const MoeTalkSkin(),
              child: MaterialApp(
                  builder: (context, child) => MediaQuery(
                      data: MediaQuery.of(context)
                          .copyWith(textScaler: const TextScaler.linear(1.8)),
                      child: child!),
                  home: Scaffold(
                      body: ChatMessageList(
                          conversationId: 'owner',
                          displayName: '测试',
                          viewportController: viewport,
                          messages: [message],
                          hasMoreMessages: false,
                          onRegenerateMessage: (_) => wholeReplyCalls++))))));
      await tester.pump(const Duration(milliseconds: 400));
      final gesture = await tester.startGesture(
          tester.getCenter(find.byType(AudioPlayerWidget)),
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryMouseButton);
      await gesture.up();
      // The desktop PopupMenuRoute measures its entries on the first frame.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('重新生成语音'), findsOneWidget);
      expect(find.text('隐藏文字'), findsOneWidget);
      expect(find.text('复制'), findsOneWidget);
      expect(find.text('重新生成'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('重新生成语音'));
      await tester.pumpAndSettle();
      expect(actions.calls, [('owner', 'audio', 'voice')]);
      expect(wholeReplyCalls, 0);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 4));
    });
  }
}
