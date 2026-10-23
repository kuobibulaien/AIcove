import 'dart:convert';
import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/features/sync/data/cloud_local_store.dart';
import 'package:aicove_flutter/src/core/database/repositories/message_projection_mapping_repository.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/background_message_reprocessor.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_service.dart';
import 'package:aicove_flutter/src/features/plugins/domain/plugin.dart';
import 'package:aicove_flutter/src/features/plugins/plugin_providers.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/plugins/tts/tts_player_manager.dart';
import 'package:aicove_flutter/src/features/plugins/tts/voice_request.dart';
import 'package:aicove_flutter/src/features/chat/services/conversation_short_window_store.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart' as model;
import 'package:aicove_flutter/src/features/chat/chat_providers.dart';

const _id = 'bg_trigger_test';
const _body = '正文<tts>抱抱你</tts>晚饭吃了吗';

class _Settings extends AppSettingsNotifier {
  _Settings(this.tts);
  final bool tts;
  @override
  Future<AppSettings> build() async =>
      mapUiModelsToAppSettings({}).copyWith(ttsEnabled: tts);
}

class _Conversations extends ConversationsNotifier {
  @override
  Future<List<Conversation>> build() async => [
    Conversation(
      id: 'c',
      title: 'c',
      displayName: 'c',
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    ),
  ];
}

class _Send extends ChatSendService {
  _Send(super.ref);
  int calls = 0;
  bool fail = false;
  bool image = false;
  Future<void> Function()? duringProcessing;
  @override
  Future<ApiCallResult> processAssistantReplyWithPlugins({
    required Conversation conv,
    required String rawReplyText,
  }) async {
    calls++;
    if (fail) throw StateError('plugin failed');
    await duringProcessing?.call();
    return ApiCallResult(
      rawReplyText: rawReplyText,
      replyText: rawReplyText,
      processedText: '正文晚饭吃了吗',
      pluginEvents: [
        if (image)
          PluginEvent(
            pluginId: 'image',
            type: 'image_generate',
            data: {'prompt': '月亮'},
          ),
        PluginEvent(
          pluginId: 'tts',
          type: 'tts_convert',
          data: {'text': '抱抱你'},
        ),
      ],
      toolResults: [],
    );
  }
}

class _Mappings extends MessageProjectionMappingRepository {
  _Mappings(super.db);
  bool fail = false;
  @override
  Future<void> replaceForRawMessage({
    required String rawMessageId,
    required List<db.MessageProjectionMappingsCompanion> mappings,
  }) async {
    if (fail) throw StateError('delivery failed');
    return super.replaceForRawMessage(
      rawMessageId: rawMessageId,
      mappings: mappings,
    );
  }
}

class _OfflineTts extends TtsPlayerManager {
  _OfflineTts() : super(() => null);
  final events = StreamController<TtsPlayItem>.broadcast();
  final entered = Completer<void>();
  late PluginEvent event;
  bool autoComplete = false;
  @override
  Stream<TtsPlayItem> get processedStream => events.stream;
  @override
  Future<void> addEvents(List<PluginEvent> incoming) async {
    event = incoming.single;
    if (!entered.isCompleted) entered.complete();
    if (autoComplete) scheduleMicrotask(complete);
  }

  void complete() => events.add(
    TtsPlayItem(
      id: event.id,
      text: '抱抱你',
      event: event,
      audioUrl: 'https://example.invalid/audio.wav',
      status: TtsPlayItemStatus.completed,
    ),
  );
  @override
  void dispose() {
    unawaited(events.close());
    super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late db.AppDatabase database;
  late ProviderContainer container;
  late _Send send;
  late _Mappings mappings;
  late int at;
  _OfflineTts? manager;
  bool enableTts = false;
  setUp(() async {
    enableTts = false;
    SharedPreferences.setMockInitialValues({});
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    at = DateTime.now().millisecondsSinceEpoch - 60000;
    await database
        .into(database.conversations)
        .insert(
          db.ConversationsCompanion.insert(
            id: 'c',
            title: 'c',
            displayName: 'c',
            createdAt: at,
            updatedAt: at,
          ),
        );
    await database
        .into(database.messages)
        .insert(
          db.MessagesCompanion.insert(
            id: _id,
            conversationId: 'c',
            role: 'assistant',
            content: _body,
            createdAt: at,
            rawPayload: Value(
              jsonEncode({
                'version': 1,
                'bg_origin_device_id': 'phone',
                'rawReplyText': _body,
                'displayReplyText': _body,
              }),
            ),
          ),
        );
    mappings = _Mappings(database);
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        backgroundReprocessDeviceIdProvider.overrideWith((_) async => 'phone'),
        conversationsProvider.overrideWith(_Conversations.new),
        appSettingsProvider.overrideWith(() => _Settings(enableTts)),
        messageProjectionMappingRepositoryProvider.overrideWithValue(mappings),
        ttsPlayerManagerProvider.overrideWith((_) => manager),
        chatSendServiceProvider.overrideWith((ref) => send = _Send(ref)),
      ],
    );
  });
  tearDown(() async {
    container.dispose();
    await database.close();
  });
  Future<void> sweep() => container
      .read(backgroundMessageReprocessorProvider)
      .reprocessRecentBackgroundMessages();
  test('only the origin device enriches the same replicated bg row', () async {
    final replicaDb = db.AppDatabase.forTesting(NativeDatabase.memory());
    await replicaDb
        .into(replicaDb.conversations)
        .insert(
          (await database.select(database.conversations).getSingle())
              .toCompanion(false),
        );
    final original = await database.select(database.messages).getSingle();
    await replicaDb
        .into(replicaDb.messages)
        .insert(original.toCompanion(false));
    late _Send replicaSend;
    final replica = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(replicaDb),
        backgroundReprocessDeviceIdProvider.overrideWith((_) async => 'mac'),
        conversationsProvider.overrideWith(_Conversations.new),
        appSettingsProvider.overrideWith(() => _Settings(false)),
        chatSendServiceProvider.overrideWith((ref) => replicaSend = _Send(ref)),
      ],
    );
    try {
      replica.read(chatSendServiceProvider);
      await replica
          .read(backgroundMessageReprocessorProvider)
          .reprocessRecentBackgroundMessages();
      expect(replicaSend.calls, 0);
      expect(
        (await SharedPreferences.getInstance()).getKeys().where(
          (key) => key.startsWith('local.bg_reprocess.'),
        ),
        isEmpty,
      );
      expect(await replicaDb.select(replicaDb.messages).getSingle(), original);
      await sweep();
      expect(send.calls, 1);
      expect(
        jsonDecode(
          (await database.select(database.messages).getSingle()).rawPayload!,
        )['bg_reprocessed'],
        true,
      );
    } finally {
      replica.dispose();
      await replicaDb.close();
    }
  });

  for (final platform in [
    TargetPlatform.macOS,
    TargetPlatform.android,
    TargetPlatform.iOS,
  ]) {
    test('legacy bg ownership on $platform', () async {
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final row = await database.select(database.messages).getSingle();
      final payload = jsonDecode(row.rawPayload!) as Map<String, dynamic>;
      payload.remove('bg_origin_device_id');
      await database.customStatement(
        'UPDATE messages SET raw_payload=? WHERE id=?',
        [jsonEncode(payload), _id],
      );
      container.read(chatSendServiceProvider);
      final before = await database.select(database.messages).getSingle();
      await sweep();
      if (platform == TargetPlatform.macOS) {
        expect(send.calls, 0);
        expect(await database.select(database.messages).getSingle(), before);
      } else {
        expect(send.calls, 1);
      }
    });
  }

  test(
    'three failures survive service recreation then commit readable fallback without more paid calls',
    () async {
      container.read(chatSendServiceProvider);
      send.fail = true;
      for (var attempt = 0; attempt < 3; attempt++) {
        await sweep();
        container.invalidate(backgroundMessageReprocessorProvider);
      }
      final localKeys = (await SharedPreferences.getInstance()).getKeys().where(
        (key) => key.startsWith('local.bg_reprocess.'),
      );
      expect(localKeys, isNotEmpty);
      expect(localKeys.any(CloudLocalStore.syncPreference), false);
      final row = await database.select(database.messages).getSingle();
      expect(jsonDecode(row.rawPayload!)['bg_reprocessed'], true);
      expect(row.deletedAt, isNull);
      expect(row.content, _body);
      expect(jsonDecode(row.rawPayload!)['projectedMessages'], isNotEmpty);
      await sweep();
      expect(send.calls, 3);
    },
  );

  test(
    'spent budget retries failed snapshot commit with zero further plugin calls',
    () async {
      container.read(chatSendServiceProvider);
      send.fail = true;
      mappings.fail = true;
      for (var i = 0; i < 3; i++) {
        await sweep();
      }
      final original = await database.select(database.messages).getSingle();
      expect(original.deletedAt, isNull);
      expect(jsonDecode(original.rawPayload!)['bg_reprocessed'], isNot(true));
      mappings.fail = false;
      container.invalidate(backgroundMessageReprocessorProvider);
      await sweep();
      expect(send.calls, 3);
      expect(
        jsonDecode(
          (await database.select(database.messages).getSingle()).rawPayload!,
        )['bg_reprocessed'],
        true,
      );
    },
  );

  test(
    'third image failure falls back only that segment and retains prepared audio',
    () async {
      manager = _OfflineTts()..autoComplete = true;
      addTearDown(() {
        manager?.dispose();
        manager = null;
      });
      enableTts = true;
      const body = '前文<tts>抱抱你</tts><image>月亮</image>后文';
      final original = await database.select(database.messages).getSingle();
      final payload = jsonDecode(original.rawPayload!) as Map<String, dynamic>;
      payload['rawReplyText'] = body;
      payload['displayReplyText'] = body;
      await database.customStatement(
        'UPDATE messages SET content=?,raw_payload=? WHERE id=?',
        [body, jsonEncode(payload), _id],
      );
      container.read(chatSendServiceProvider);
      send.image = true;
      for (var i = 0; i < 3; i++) {
        await VoiceRequest(ownerId: 'c').run(sweep);
      }
      final row = await database.select(database.messages).getSingle();
      final snapshot = jsonDecode(row.rawPayload!);
      expect(snapshot['bg_reprocessed'], true);
      final projections = snapshot['projectedMessages'] as List;
      expect(
        projections.any(
          (m) => (m['blocks'] as List).any((b) => b['type'] == 'audio'),
        ),
        true,
      );
      expect(jsonEncode(projections), contains('月亮'));
      expect(jsonEncode(projections), contains('前文'));
      expect(jsonEncode(projections), contains('后文'));
      await sweep();
      expect(send.calls, 3);
    },
  );

  test(
    'a real prepared audio segment belongs to the same atomic raw snapshot',
    () async {
      manager = _OfflineTts();
      addTearDown(() {
        manager?.dispose();
        manager = null;
      });
      enableTts = true;
      final task = VoiceRequest(ownerId: 'c').run(sweep);
      await manager!.entered.future.timeout(const Duration(seconds: 3));
      manager!.complete();
      await task;
      expect(container.read(chatStatusProvider), ChatStatus.idle);
      final raw = await database.select(database.messages).getSingle();
      final payload = jsonDecode(raw.rawPayload!);
      final projections = payload['projectedMessages'] as List;
      expect(
        projections.where(
          (m) => (m['blocks'] as List).any((b) => b['type'] == 'audio'),
        ),
        hasLength(1),
      );
      expect(
        projections.every(
          (m) => m['sourceMessageId'] == _id && m['createdAt'] == at,
        ),
        true,
      );
      expect((await mappings.getByRawMessage(_id)).length, projections.length);
    },
  );

  test(
    'enrichment patches its raw without discarding an unrelated stream draft',
    () async {
      final cache = container.read(conversationTimelineCacheProvider);
      await cache.loadCachedMessages('c');
      await cache.replaceMessagesTransient(
        conversationId: 'c',
        messages: [
          model.Message(
            id: 'draft',
            sourceMessageId: 'inflight',
            role: 'assistant',
            content: 'still streaming',
            createdAt: DateTime.now(),
          ),
        ],
      );
      await sweep();
      final messages = await cache.loadCachedMessages('c');
      expect(messages.any((m) => m.id == 'draft'), true);
      expect(messages.any((m) => m.sourceMessageId == _id), true);
      expect(await database.select(database.messages).get(), hasLength(1));
    },
  );

  test('a synced deletion during plugin work is not resurrected', () async {
    container.read(chatSendServiceProvider);
    send.duringProcessing = () => database.customStatement(
      'UPDATE messages SET deleted_at=123 WHERE id=?',
      [_id],
    );
    await sweep();
    final row = await database.select(database.messages).getSingle();
    expect(row.deletedAt, 123);
    expect(jsonDecode(row.rawPayload!)['bg_reprocessed'], isNot(true));
    expect(await mappings.getByRawMessage(_id), isEmpty);
  });

  test(
    'reprocessing retains one raw identity, timestamp and complete projections; repeat is inert',
    () async {
      await sweep();
      final rows = await database.select(database.messages).get();
      expect(rows, hasLength(1));
      expect(rows.single.id, _id);
      expect(rows.single.createdAt, at);
      expect(rows.single.deletedAt, isNull);
      final payload = jsonDecode(rows.single.rawPayload!);
      expect(payload['bg_reprocessed'], true);
      expect(payload['projectedMessages'], isNotEmpty);
      final maps = await mappings.getByRawMessage(_id);
      expect(maps, isNotEmpty);
      expect(
        maps.every((m) => m.rawMessageId == _id && m.createdAt == at),
        true,
      );
      await sweep();
      expect(send.calls, 1);
      expect(await database.select(database.messages).get(), hasLength(1));
    },
  );
  for (final failure in ['plugin', 'delivery']) {
    test(
      '$failure failure preserves old visible message and allows retry',
      () async {
        container.read(chatSendServiceProvider);
        send.fail = failure == 'plugin';
        mappings.fail = failure == 'delivery';
        await sweep();
        final rows = await database.select(database.messages).get();
        expect(rows, hasLength(1));
        expect(rows.single.deletedAt, isNull);
        expect(rows.single.content, _body);
        expect(
          jsonDecode(rows.single.rawPayload!)['bg_reprocessed'],
          isNot(true),
        );
        send.fail = false;
        mappings.fail = false;
        await sweep();
        expect(
          jsonDecode(
            (await database.select(database.messages).getSingle()).rawPayload!,
          )['bg_reprocessed'],
          true,
        );
      },
    );
  }
}
