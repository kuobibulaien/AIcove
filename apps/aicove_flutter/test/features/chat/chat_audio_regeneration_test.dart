import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/core/media/media_store.dart';
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/core/models/block_status.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_history_store.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_media_regeneration.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_message_projection_codec.dart';
import 'package:aicove_flutter/src/features/plugins/tts/voice_preset_application.dart';
import 'package:aicove_flutter/src/features/plugins/tts/voice_request.dart';
import 'package:aicove_flutter/src/features/plugins/tts/tts_service.dart';
import 'package:aicove_flutter/src/features/plugins/tts/tts_config.dart';

class _Generator implements ChatMediaGenerationPort {
  _Generator(this.callback);
  final Future<GeneratedChatMedia> Function(String, String) callback;
  @override
  Future<GeneratedChatMedia> generate(String owner, String input,
          {ImageGenerationSnapshot? imageSnapshot}) =>
      callback(owner, input);
}

class _VoiceApplication implements VoicePresetApplicationPort {
  _VoiceApplication(this.request);
  VoiceRequest request;
  final owners = <String>[];
  @override
  Future<VoiceRequest> forOwnerId(String ownerId) async {
    owners.add(ownerId);
    return request;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected voice operation');
}

class _Speech extends TtsService {
  _Speech(this.pending)
      : super(
            config: TtsConfig(enabled: true),
            apiKey: 'test-only',
            requestUrl: 'http://127.0.0.1');
  final Completer<TtsConvertResult> pending;
  final called = Completer<void>();
  String? input;
  String? owner;
  @override
  Future<TtsConvertResult> convert(String text) {
    input = text;
    owner = VoiceRequest.current?.ownerId;
    called.complete();
    return pending.future;
  }
}

class _LocalHttpOverrides extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late db.AppDatabase database;
  late ProviderContainer container;
  ChatHistoryStore store() => container.read(chatHistoryStoreProvider);
  Message message(
          {String role = 'assistant',
          String? text = '原始语音内容',
          BlockStatus status = BlockStatus.success}) =>
      Message.fromBlocks(
          id: 'audio',
          role: role,
          createdAt: DateTime.fromMillisecondsSinceEpoch(10),
          blocks: [
            AudioBlock(
                id: 'voice',
                messageId: 'audio',
                url: '/old.wav',
                text: text,
                durationSeconds: 8,
                status: status),
            ImageBlock(
                id: 'image',
                messageId: 'audio',
                localPath: '/keep.png',
                prompt: 'cat'),
          ]);
  Future<void> seed({bool projected = false}) async {
    final msg = message();
    await store().updateMessage(
        conversationId: 'a',
        message: projected
            ? Message(
                id: 'raw',
                role: 'assistant',
                content: '保留原文',
                createdAt: msg.createdAt,
                rawPayload:
                    ChatMessageProjectionCodec.copyWithProjectedMessages({
                  'rawReplyText': '保留原文',
                  'processedText': '保留原文'
                }, [
                  msg.copyWith(sourceMessageId: 'raw'),
                  Message(
                      id: 'sibling',
                      role: 'assistant',
                      content: '保留后续回复',
                      createdAt: msg.createdAt,
                      sourceMessageId: 'raw')
                ]))
            : msg);
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    await database.customStatement('PRAGMA foreign_keys = ON');
    container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(database)]);
    for (final owner in ['a', 'b']) {
      await database.into(database.conversations).insert(
          db.ConversationsCompanion.insert(
              id: owner,
              title: owner,
              displayName: owner,
              createdAt: 0,
              updatedAt: 0));
    }
  });
  tearDown(() async {
    container.dispose();
    await database.close();
  });
  ChatMediaRegeneration action(
          Future<GeneratedChatMedia> Function(String, String) callback) =>
      ChatMediaRegeneration(
          store: store(),
          isSending: (_) => false,
          generators: {RegeneratableMediaKind.audio: _Generator(callback)});
  Future<void> run(ChatMediaRegenerationPort port) => port.regenerate(
      conversationId: 'a', messageId: 'audio', blockId: 'voice');
  Future<AudioBlock> audio() async =>
      (await store().loadFrontendMessageById('audio', conversationId: 'a'))!
          .blocks!
          .whereType<AudioBlock>()
          .single;

  for (final projected in [false, true]) {
    test('语音替换持久化与重载，保留原文和图片 projected=$projected', () async {
      await seed(projected: projected);
      await run(action((owner, input) async {
        expect(owner, 'a');
        expect(input, '原始语音内容');
        return const GeneratedChatMedia.audio('/new.wav');
      }));
      container.dispose();
      container = ProviderContainer(
          overrides: [databaseProvider.overrideWithValue(database)]);
      final block = await audio();
      expect(block.url, '/new.wav');
      expect(block.text, '原始语音内容');
      expect(block.durationSeconds, isNull);
      expect(block.status, BlockStatus.success);
      final rebuilt = (await store()
          .loadFrontendMessageById('audio', conversationId: 'a'))!;
      expect(rebuilt.images.single.localPath, '/keep.png');
      expect(rebuilt.createdAt.millisecondsSinceEpoch, 10);
      if (projected) {
        expect(
            (await store().loadMessageById('raw', preferProjection: false))!
                .content,
            '保留原文');
        expect(
            (await store()
                    .loadFrontendMessageById('sibling', conversationId: 'a'))!
                .content,
            '保留后续回复');
      }
    });
    test('语音落库失败保持原音频及旧时长 projected=$projected', () async {
      await seed(projected: projected);
      await database.customStatement(
          "CREATE TRIGGER fail_audio BEFORE UPDATE ON messages BEGIN SELECT RAISE(ABORT, 'disk failure'); END");
      await expectLater(
          run(action(
              (_, __) async => const GeneratedChatMedia.audio('/new.wav'))),
          throwsA(predicate((e) => e.toString().contains('disk failure'))));
      expect((await audio()).url, '/old.wav');
      expect((await audio()).durationSeconds, 8);
      container.dispose();
      container = ProviderContainer(
          overrides: [databaseProvider.overrideWithValue(database)]);
      expect((await audio()).url, '/old.wav');
    });
  }
  test('语音供应商失败后释放锁，可再次重生成', () async {
    await seed();
    var count = 0;
    final port = action((_, __) async {
      if (++count == 1) throw StateError('provider unavailable');
      return const GeneratedChatMedia.audio('/new.wav', durationSeconds: 3);
    });
    await expectLater(run(port), throwsStateError);
    expect((await audio()).url, '/old.wav');
    await run(port);
    expect((await audio()).durationSeconds, 3);
  });
  test('同一语音重复点击只触发一次', () async {
    await seed();
    final started = Completer<void>();
    final result = Completer<GeneratedChatMedia>();
    var calls = 0;
    final port = action((_, __) {
      calls++;
      started.complete();
      return result.future;
    });
    final first = run(port);
    await started.future;
    await expectLater(run(port), throwsStateError);
    result.complete(const GeneratedChatMedia.audio('/new.wav'));
    await first;
    expect(calls, 1);
  });
  for (final change in ['hidden', 'deleted', 'changed']) {
    test('生成期间目标$change拒绝回填', () async {
      await seed();
      await expectLater(run(action((_, __) async {
        if (change == 'hidden') {
          await store().hideMessagesInFrontendTimeline('a', ['audio']);
        }
        if (change == 'deleted') {
          await store().softDeleteMessages('a', ['audio']);
        }
        if (change == 'changed') {
          await store().updateMessage(
              conversationId: 'a', message: message(text: '新的正文'));
        }
        return const GeneratedChatMedia.audio('/late.wav');
      })), throwsStateError);
    });
  }
  test('拒绝用户录音、无原文与待生成语音', () async {
    for (final msg in [
      message(role: 'user'),
      message(text: null),
      message(text: '  '),
      message(status: BlockStatus.pending)
    ]) {
      await store().updateMessage(conversationId: 'a', message: msg);
      expect(
          MediaRegenerationTarget.canRegenerate(msg, msg.blocks!.first), false);
      await expectLater(
          run(action((_, __) async => fail('不可请求供应商'))), throwsStateError);
    }
  });
  test('拒绝跨会话重生成及错误媒体返回类型', () async {
    await seed();
    final port =
        action((_, __) async => const GeneratedChatMedia.image('/wrong.png'));
    await expectLater(
        port.regenerate(
            conversationId: 'b', messageId: 'audio', blockId: 'voice'),
        throwsStateError);
    await expectLater(run(port), throwsStateError);
    expect((await audio()).url, '/old.wav');
  });
  test('真实语音适配器固定owner快照，生成期间切换音色不串用', () async {
    final pending = Completer<TtsConvertResult>();
    final speech = _Speech(pending);
    final app = _VoiceApplication(VoiceRequest(ownerId: 'a', service: speech));
    container.dispose();
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(database),
      voicePresetApplicationProvider.overrideWithValue(app)
    ]);
    await seed();
    final future = run(container.read(chatMediaRegenerationProvider));
    await speech.called.future;
    app.request = VoiceRequest(ownerId: 'b', error: 'new owner');
    pending.complete(TtsConvertResult(
        audioUrl: '/new.wav', text: '返回内容不替换原文', success: true));
    await future;
    expect(app.owners, ['a']);
    expect(speech.owner, 'a');
    expect(speech.input, '原始语音内容');
    expect((await audio()).text, '原始语音内容');
    expect((await audio()).url, '/new.wav');
  });
  test('语音端口返回错误owner时不得调用合成', () async {
    final speech = _Speech(Completer<TtsConvertResult>());
    container.dispose();
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(database),
      voicePresetApplicationProvider.overrideWithValue(
          _VoiceApplication(VoiceRequest(ownerId: 'b', service: speech)))
    ]);
    await seed();
    await expectLater(
        run(container.read(chatMediaRegenerationProvider)), throwsStateError);
    expect(speech.called.isCompleted, false);
  });
  test('语音重生成实际经过本机HTTP，保存新音频并保留角色音色参数', () async {
    final mediaDirectory = await Directory.systemTemp.createTemp('tts-media-');
    final mediaStore = MediaStore(mediaDirectory, 'tts-test-device');
    MediaStore.use(mediaStore);
    addTearDown(() async {
      await mediaStore.close();
      await mediaDirectory.delete(recursive: true);
    });
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final bodies = <Map<String, dynamic>>[];
    server.listen((request) async {
      bodies.add(jsonDecode(await utf8.decoder.bind(request).join())
          as Map<String, dynamic>);
      request.response.headers.contentType = ContentType('audio', 'wav');
      request.response.add([82, 73, 70, 70, 0, 0, 0, 0]);
      await request.response.close();
    });
    final speech = TtsService(
        config: TtsConfig(enabled: true, voice: 'role-voice', speed: 0.8),
        apiKey: 'test-only',
        requestUrl: 'http://127.0.0.1:${server.port}/v1',
        requestFormat: 'openai_tts',
        model: 'tts-test');
    container.dispose();
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(database),
      voicePresetApplicationProvider.overrideWithValue(
          _VoiceApplication(VoiceRequest(ownerId: 'a', service: speech)))
    ]);
    await seed();
    await HttpOverrides.runWithHttpOverrides(
        () => run(container.read(chatMediaRegenerationProvider)),
        _LocalHttpOverrides());
    expect(bodies, hasLength(1));
    expect(bodies.single['input'], '原始语音内容');
    expect(bodies.single['voice'], 'role-voice');
    expect(bodies.single['speed'], 0.8);
    expect((await audio()).url, startsWith('data:audio/'));
    expect((await audio()).durationSeconds, isNull);
  });
}
