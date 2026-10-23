import 'dart:async';

import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/core/models/block_status.dart';
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/audio_player_widget.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_frontend_message_projection_service.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_history_store.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_message_projection_codec.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/voice_autoplay_prompt.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeBackend implements AudioPlaybackBackend {
  final _state = StreamController<PlayerState>.broadcast();
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration?>.broadcast();
  final _events = StreamController<PlaybackEvent>.broadcast();
  int playCalls = 0;

  @override
  Stream<PlayerState> get playerStateStream => _state.stream;
  @override
  Stream<Duration> get positionStream => _position.stream;
  @override
  Stream<Duration?> get durationStream => _duration.stream;
  @override
  Stream<PlaybackEvent> get playbackEventStream => _events.stream;
  @override
  Duration get position => Duration.zero;

  @override
  Future<Duration?> setUrl(String url) async {
    _state.add(PlayerState(false, ProcessingState.ready));
    return const Duration(seconds: 2);
  }

  @override
  Future<Duration?> setFilePath(String path) => setUrl(path);

  @override
  Future<void> play() async {
    playCalls += 1;
    _state.add(PlayerState(true, ProcessingState.ready));
  }

  @override
  Future<void> pause() async =>
      _state.add(PlayerState(false, ProcessingState.ready));

  @override
  Future<void> seek(Duration position) async {}

  void complete() => _state.add(PlayerState(false, ProcessingState.completed));

  @override
  Future<void> dispose() async {}
}

class _RecordingStore extends ChatHistoryStore {
  _RecordingStore(super.ref);

  final List<Message> updates = <Message>[];

  @override
  Future<void> updateMessage({
    required String conversationId,
    required Message message,
    String? lastMessagePreview,
  }) async {
    updates.add(message);
  }
}

Message _voice(String id, {bool unread = true}) => Message.fromBlocks(
      id: id,
      role: 'assistant',
      createdAt: DateTime(2026, 10, 22),
      blocks: [
        AudioBlock(
          id: 'b_$id',
          messageId: id,
          url: 'https://example.invalid/$id.wav',
          text: id,
          unread: unread,
        ),
      ],
    );

String _url(String id) => 'https://example.invalid/$id.wav';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AudioBlock 未读字段', () {
    test('旧数据没有字段时算已读，已读不写进 JSON', () {
      final legacy = AudioBlock.fromJson({
        'id': 'b',
        'messageId': 'm',
        'type': 'audio',
        'status': 'success',
        'url': 'file:///a.wav',
      });
      expect(legacy.unread, isFalse);
      expect(legacy.toJson().containsKey('unread'), isFalse);
      final unread = legacy.withUnread(true);
      expect(AudioBlock.fromJson(unread.toJson()).unread, isTrue);
    });

    test('只把新回复里已就绪的语音标为未读', () {
      final pending = Message.fromBlocks(
        id: 'p',
        role: 'assistant',
        createdAt: DateTime(2026),
        blocks: [AudioBlock(messageId: 'p', url: '', status: BlockStatus.pending)],
      );
      final user = _voice('u', unread: false).copyWith(role: 'user');
      final marked = markNewVoicesUnread([
        _voice('a', unread: false),
        pending,
        user,
      ]);
      expect((marked[0].blocks!.single as AudioBlock).unread, isTrue);
      expect((marked[1].blocks!.single as AudioBlock).unread, isFalse);
      expect((marked[2].blocks!.single as AudioBlock).unread, isFalse);
    });
  });

  group('未读标记落库与重建', () {
    late db.AppDatabase database;
    late ProviderContainer container;
    final time = DateTime(2026, 10, 22);

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      database = db.AppDatabase.forTesting(NativeDatabase.memory());
      await database.into(database.conversations).insert(
            db.ConversationsCompanion.insert(
              id: 'a',
              title: '语音',
              displayName: '语音',
              createdAt: time.millisecondsSinceEpoch,
              updatedAt: time.millisecondsSinceEpoch,
            ),
          );
      container = ProviderContainer(overrides: [
        databaseProvider.overrideWithValue(database),
        activeConversationProvider.overrideWith(
          (ref) => Conversation(
            id: 'a',
            title: '语音',
            displayName: '语音',
            createdAt: time,
            updatedAt: time,
          ),
        ),
      ]);
    });

    tearDown(() async {
      container.dispose();
      await database.close();
    });

    Future<AudioBlock> reprojectedVoice(ChatHistoryStore store) async {
      final raw = await store.loadMessageById('raw',
          conversationId: 'a', preferProjection: false);
      final projected =
          const ChatFrontendMessageProjectionService().projectMessage(raw!);
      return projected
          .expand((m) => m.blocks ?? const <MessageBlock>[])
          .whereType<AudioBlock>()
          .single;
    }

    test('新语音落库为未读，从原文重建仍未读；标已读后重建为已读', () async {
      final store = container.read(chatHistoryStoreProvider);
      await store.appendAssistantRawMessage(
        conversationId: 'a',
        userMessageId: '',
        rawMessage: Message(
          id: 'raw',
          role: 'assistant',
          content: '正文',
          createdAt: time,
          rawPayload: const {'rawReplyText': '正文'},
        ),
        projectedMessages: const [],
        lastMessagePreview: '正文',
      );
      await store.appendMessage(
        conversationId: 'a',
        message: Message.fromBlocks(
          id: 'voice',
          role: 'assistant',
          createdAt: time,
          blocks: [
            AudioBlock(messageId: 'voice', url: 'file:///v.wav', text: '你好'),
          ],
        ).copyWith(sourceMessageId: 'raw'),
      );

      final stored = await store.loadMessageById('raw',
          conversationId: 'a', preferProjection: false);
      expect(
        ChatMessageProjectionCodec.supplementInsertOps(stored!.rawPayload)
            .single
            .unread,
        isTrue,
      );
      expect((await reprojectedVoice(store)).unread, isTrue);

      final shown = (await store.loadCachedTimelineMessages('a')).firstWhere(
        (m) => m.blocks?.any((b) => b is AudioBlock) ?? false,
      );
      await store.updateMessage(
        conversationId: 'a',
        message: shown.copyWith(blocks: [
          for (final block in shown.blocks!)
            block is AudioBlock ? block.withUnread(false) : block,
        ]),
      );
      expect((await reprojectedVoice(store)).unread, isFalse);
    });

    test('旧补插记录没有未读字段，重建出的语音算已读', () {
      final raw = Message(
        id: 'old',
        role: 'assistant',
        content: '正文',
        createdAt: time,
        rawPayload: const {
          'rawReplyText': '正文',
          'supplementInsertOps': [
            {
              'kind': 'audio',
              'textCharsBefore': 2,
              'forceAppendToTail': true,
              'audioUrl': 'file:///old.wav',
            },
          ],
        },
      );
      final voice = const ChatFrontendMessageProjectionService()
          .projectMessage(raw)
          .expand((m) => m.blocks ?? const <MessageBlock>[])
          .whereType<AudioBlock>()
          .single;
      expect(voice.unread, isFalse);
    });
  });

  group('连续点播判定', () {
    test('三条不同语音才算连续，重复点同一条不累计，间隔太久重新计', () {
      final streak = VoiceTapStreak();
      final t = DateTime(2026, 10, 22, 12);
      expect(streak.add('a', t), isFalse);
      expect(streak.add('a', t.add(const Duration(seconds: 5))), isFalse);
      expect(streak.add('b', t.add(const Duration(seconds: 10))), isFalse);
      expect(streak.add('c', t.add(const Duration(minutes: 5))), isFalse);
      expect(streak.add('d', t.add(const Duration(minutes: 6))), isFalse);
      expect(streak.add('e', t.add(const Duration(minutes: 7))), isTrue);
    });

    test('未读列表按时间线顺序并跳过已听过的', () {
      final messages = [
        _voice('a'),
        _voice('b', unread: false),
        _voice('c'),
        _voice('d'),
      ];
      expect(unreadVoiceUrls(messages, {_url('c')}), [_url('a'), _url('d')]);
    });
  });

  testWidgets('连点三条后右下角提示，点播放按顺序播完剩下的未读语音', (tester) async {
    final ids = ['v1', 'v2', 'v3', 'v4', 'v5'];
    final backends = {for (final id in ids) _url(id): _FakeBackend()};
    final coordinator = AudioPlaybackCoordinator();
    late _RecordingStore store;

    await tester.pumpWidget(ProviderScope(
      overrides: [
        audioPlaybackCoordinatorProvider.overrideWithValue(coordinator),
        audioPlayerControllerProvider.overrideWith(
          (ref, url) => AudioPlayerController(url,
              backend: backends[url], ref: ref, coordinator: coordinator),
        ),
        chatHistoryStoreProvider.overrideWith((ref) => store = _RecordingStore(ref)),
      ],
      child: MaterialApp(
        theme: ThemeData(extensions: [MoeColors.light()]),
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomRight,
            child: VoiceAutoplayPrompt(
              conversationId: 'c',
              messages: [for (final id in ids) _voice(id)],
            ),
          ),
        ),
      ),
    ));
    final container = ProviderScope.containerOf(
      tester.element(find.byType(VoiceAutoplayPrompt)),
    );
    for (final id in ids) {
      container.listen(audioPlayerControllerProvider(_url(id)).notifier, (_, _) {});
    }
    AudioPlayerController controller(String id) =>
        container.read(audioPlayerControllerProvider(_url(id)).notifier);
    await tester.pump();

    for (final id in ['v1', 'v2']) {
      await controller(id).togglePlayPause();
      await tester.pump();
    }
    expect(find.textContaining('自动播放'), findsNothing);
    await controller('v3').togglePlayPause();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('自动播放剩下的 2 条语音？'), findsOneWidget);
    expect(
      store.updates
          .map((m) => (m.blocks!.single as AudioBlock))
          .map((b) => (b.messageId, b.unread)),
      [('v1', false), ('v2', false), ('v3', false)],
    );

    await tester.tap(find.text('播放'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('自动播放'), findsNothing);
    expect(backends[_url('v4')]!.playCalls, 0, reason: '先等当前这条播完');

    backends[_url('v3')]!.complete();
    await tester.pump();
    await tester.pump();
    expect(backends[_url('v4')]!.playCalls, 1);
    expect(backends[_url('v5')]!.playCalls, 0);

    backends[_url('v4')]!.complete();
    await tester.pump();
    await tester.pump();
    expect(backends[_url('v5')]!.playCalls, 1);
    backends[_url('v5')]!.complete();
    await tester.pump();
    expect(
      store.updates.map((m) => m.id),
      ['v1', 'v2', 'v3', 'v4', 'v5'],
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('自动连播时用户点了别的语音，连播停下', (tester) async {
    final ids = ['v1', 'v2', 'v3', 'v4', 'v5'];
    final backends = {for (final id in ids) _url(id): _FakeBackend()};
    final coordinator = AudioPlaybackCoordinator();

    await tester.pumpWidget(ProviderScope(
      overrides: [
        audioPlaybackCoordinatorProvider.overrideWithValue(coordinator),
        audioPlayerControllerProvider.overrideWith(
          (ref, url) => AudioPlayerController(url,
              backend: backends[url], ref: ref, coordinator: coordinator),
        ),
        chatHistoryStoreProvider.overrideWith(_RecordingStore.new),
      ],
      child: MaterialApp(
        theme: ThemeData(extensions: [MoeColors.light()]),
        home: Scaffold(
          body: VoiceAutoplayPrompt(
            conversationId: 'c',
            messages: [for (final id in ids) _voice(id)],
          ),
        ),
      ),
    ));
    final container = ProviderScope.containerOf(
      tester.element(find.byType(VoiceAutoplayPrompt)),
    );
    for (final id in ids) {
      container.listen(audioPlayerControllerProvider(_url(id)).notifier, (_, _) {});
    }
    AudioPlayerController controller(String id) =>
        container.read(audioPlayerControllerProvider(_url(id)).notifier);
    for (final id in ['v1', 'v2', 'v3']) {
      await controller(id).togglePlayPause();
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('播放'));
    await tester.pump();
    backends[_url('v3')]!.complete();
    await tester.pump();
    await tester.pump();
    expect(backends[_url('v4')]!.playCalls, 1);

    // 用户改点 v1 重听：v4 被打断，v5 不再自动开始。
    await controller('v1').togglePlayPause();
    await tester.pump();
    backends[_url('v1')]!.complete();
    await tester.pump();
    await tester.pump();
    expect(backends[_url('v5')]!.playCalls, 0);
    await tester.pumpWidget(const SizedBox());
  });
}
