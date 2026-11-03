import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/core/database/repositories/conversation_repository.dart';
import 'package:aicove_flutter/src/features/chat/chat_providers.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_deferred_image_delivery.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_pending_tts_resolver.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_tts_handler.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/features/plugins/domain/plugin.dart';
import 'package:aicove_flutter/src/features/plugins/image/image_config.dart';
import 'package:aicove_flutter/src/features/plugins/image/image_plugin.dart';
import 'package:aicove_flutter/src/features/plugins/plugin_manager.dart';
import 'package:aicove_flutter/src/features/plugins/plugin_providers.dart';
import 'package:aicove_flutter/src/features/plugins/tts/tts_player_manager.dart';
import 'package:aicove_flutter/src/features/plugins/tts/voice_request.dart';

final _refProvider = Provider<Ref>((ref) => ref);
final _activeId = StateProvider<String>((ref) => 'a');

class _Speech extends TtsPlayerManager {
  _Speech() : super(() => null);
  final results = StreamController<TtsPlayItem>.broadcast();
  final events = <PluginEvent>[];
  final finished = <int>{};

  @override
  Stream<TtsPlayItem> get processedStream => results.stream;
  @override
  Future<void> addEvents(List<PluginEvent> items) async => events.addAll(items);

  void finish(int index, {bool success = true}) {
    if (!finished.add(index)) return;
    final event = events[index];
    results.add(
      TtsPlayItem(
        id: event.id,
        text: event.data['text'] as String,
        event: event,
        status: success
            ? TtsPlayItemStatus.completed
            : TtsPlayItemStatus.failed,
        audioUrl: success ? '/test-only/$index.wav' : null,
      ),
    );
  }

  @override
  void dispose() {
    results.close();
    super.dispose();
  }
}

class _Image extends ImagePlugin {
  _Image(Ref ref) : super(const ImageConfig(), ref);
  @override
  bool get enabled => true;
}

class _Conversations implements ConversationRepository {
  final pending = <String, Completer<db.Conversation?>>{};
  @override
  Future<db.Conversation?> getById(String id) =>
      pending.putIfAbsent(id, Completer<db.Conversation?>.new).future;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected repository call: $invocation');
}

void main() {
  late ProviderContainer container;
  late _Speech speech;
  late _Conversations conversations;
  late Ref ref;
  late ChatPendingTtsResolver resolver;
  setUp(() {
    speech = _Speech();
    conversations = _Conversations();
    container = ProviderContainer(
      overrides: [
        activeConversationProvider.overrideWith((ref) {
          final id = ref.watch(_activeId);
          return Conversation(
            id: id,
            title: id,
            displayName: id,
            createdAt: DateTime(2026),
            updatedAt: DateTime(2026),
            messages: const [],
          );
        }),
        ttsPlayerManagerProvider.overrideWithValue(speech),
        conversationRepositoryProvider.overrideWithValue(conversations),
        pluginManagerProvider.overrideWith(
          (ref) => PluginManager()..register(_Image(ref)),
        ),
      ],
    );
    ref = container.read(_refProvider);
    resolver = ChatPendingTtsResolver(
      ref: ref,
      ttsManager: speech,
      enqueueStoreMutation: (action) => action(),
    );
  });
  tearDown(() {
    container.dispose();
    speech.dispose();
  });

  Future<void> resolve(
    String owner,
    String id, {
    void Function(String, double?)? onAudioResolved,
    void Function(String)? onTextFallback,
    bool Function()? shouldApplyResult,
  }) => VoiceRequest(ownerId: owner).run(
    () => resolver.resolveSinglePendingMessage(
      convId: owner,
      message: resolver.buildPendingPlaceholderMessage('speech', messageId: id),
      persistResult: false,
      onAudioResolved: onAudioResolved,
      onTextFallback: onTextFallback,
      shouldApplyResult: shouldApplyResult,
    ),
  );

  test(
    'concurrent synthesis counts actual tasks and duplicate callers join',
    () async {
      final pending = [
        resolve('a', 'a1'),
        resolve('a', 'a1'),
        resolve('a', 'a2'),
      ];
      try {
        expect(speech.events, hasLength(2));
        expect(container.read(conversationVoiceTaskCountProvider('a')), 2);
        expect(container.read(chatStatusProvider), ChatStatus.generatingVoice);
        speech.finish(0);
        await pending[0];
        await pending[1];
        expect(container.read(conversationVoiceTaskCountProvider('a')), 1);
        expect(container.read(chatStatusProvider), ChatStatus.generatingVoice);
      } finally {
        for (var index = 0; index < speech.events.length; index++) {
          speech.finish(index);
        }
        await Future.wait(pending);
      }
      expect(container.read(chatStatusProvider), ChatStatus.idle);
      expect(container.read(conversationVoiceTaskCountProvider('a')), 0);
    },
  );

  test(
    'synthesis in another conversation cannot overwrite the main phase',
    () async {
      setConversationMainChatStatus(ref, 'a', ChatStatus.toolCalling);
      final pending = resolve('b', 'b1', shouldApplyResult: () => false);
      try {
        expect(container.read(chatStatusProvider), ChatStatus.toolCalling);
        container.read(_activeId.notifier).state = 'b';
        expect(container.read(chatStatusProvider), ChatStatus.generatingVoice);
        container.read(_activeId.notifier).state = 'a';
      } finally {
        speech.finish(0);
        await pending;
      }
      expect(container.read(conversationVoiceTaskCountProvider('b')), 0);
      expect(container.read(chatStatusProvider), ChatStatus.toolCalling);
    },
  );

  test(
    'failed synthesis and throwing callbacks both release their task',
    () async {
      final pending = resolve(
        'a',
        'a1',
        onTextFallback: (_) => throw StateError('callback'),
      );
      final checked = expectLater(pending, throwsStateError);
      speech.finish(0, success: false);
      await checked;
      expect(container.read(conversationVoiceTaskCountProvider('a')), 0);
      expect(container.read(chatStatusProvider), ChatStatus.idle);
    },
  );

  test(
    'snapshot handler delegates one voice task and preserves a new main phase',
    () async {
      final handler = ChatTtsHandler(ref);
      final event = PluginEvent(
        pluginId: 'tts',
        type: 'tts_convert',
        id: 'snapshot-event',
        data: const {'text': 'speech', 'originalText': 'speech'},
      );
      VoiceRequest(ownerId: 'b').attach(event);
      final pending = handler.prepareBackgroundSnapshot(
        convId: 'b',
        rawMessage: resolver.buildPendingPlaceholderMessage(
          'raw',
          messageId: 'raw',
        ),
        buildResult: const AssistantMessageBuildResult(
          messages: [],
          lastMessageText: '',
        ),
        replyText: '<tts>speech</tts>',
        pluginEvents: [event],
        ttsEnabled: true,
      );
      try {
        expect(container.read(conversationVoiceTaskCountProvider('b')), 1);
        expect(container.read(chatStatusProvider), ChatStatus.idle);
        container.read(_activeId.notifier).state = 'b';
        expect(container.read(chatStatusProvider), ChatStatus.generatingVoice);
        setConversationMainChatStatus(ref, 'b', ChatStatus.thinking);
      } finally {
        speech.finish(0);
        await pending;
      }
      expect(container.read(chatStatusProvider), ChatStatus.thinking);
      expect(container.read(conversationVoiceTaskCountProvider('b')), 0);
    },
  );

  test(
    'overlapping deferred images release separately on configuration failure',
    () async {
      final delivery = ChatDeferredImageDelivery(
        ref: ref,
        enqueueStoreMutation: (action) => action(),
        runBackgroundTask: (_, task) {},
      );
      final pending = ['a', 'b']
          .map(
            (owner) => delivery.prepareSnapshotImage(
              convId: owner,
              prompt: 'test',
              messageId: 'image-$owner',
            ),
          )
          .toList();
      final checked = pending
          .map((future) => expectLater(future, throwsStateError))
          .toList();
      try {
        expect(container.read(conversationImageTaskCountProvider('a')), 1);
        expect(container.read(conversationImageTaskCountProvider('b')), 1);
        expect(container.read(chatStatusProvider), ChatStatus.generatingImage);
        container.read(_activeId.notifier).state = 'b';
        conversations.pending['a']!.complete(null);
        await checked[0];
        expect(container.read(chatStatusProvider), ChatStatus.generatingImage);
        expect(container.read(conversationImageTaskCountProvider('a')), 0);
      } finally {
        for (final gate in conversations.pending.values) {
          if (!gate.isCompleted) gate.complete(null);
        }
        await Future.wait(checked);
      }
      expect(container.read(chatStatusProvider), ChatStatus.idle);
      expect(container.read(conversationImageTaskCountProvider('b')), 0);
    },
  );
}
