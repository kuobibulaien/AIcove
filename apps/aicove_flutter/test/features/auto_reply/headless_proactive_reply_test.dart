// F group (batch 2 plan §5): the background generation assembles through
// the chat entry with nothing but the database and settings — no UI state,
// no conversations list — and sends the same request the foreground does.
import 'dart:convert';
import 'dart:io';

import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/proactive_reply_generator.dart';
import 'package:aicove_flutter/src/features/auto_reply/domain/proactive_action.dart';
import 'package:aicove_flutter/src/features/chat/domain/persona_prompt_codec.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_backend_service.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/features/memory/application/memory_keeper_service.dart';
import 'package:aicove_flutter/src/features/memory/providers/memory_providers.dart';
import 'package:aicove_flutter/src/features/observability/trace_store.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
  @override
  Future<String?> getTemporaryPath() async => path;
}

class _Settings extends AppSettingsNotifier {
  _Settings(this._settings);
  final AppSettings _settings;
  @override
  Future<AppSettings> build() async => _settings;
}

final _now = DateTime.utc(2026, 10, 12, 10, 5, 30);
const _model = 'openai:gpt-4o';
const _conv = 'conv_headless';
const _reminder = '用户一上午没说话，轻轻问候一下';

AppSettings _settings() =>
    mapUiModelsToAppSettings({'context_window_tokens': 272000}).copyWith(
      defaultModelName: _model,
      defaultChatModels: const [_model],
      modelConfigs: {
        _model: ModelConfig(chatCapabilities: const ['tools']),
      },
      modelTypes: const {_model: 'chat'},
      providers: const [
        ProviderAuth(
          id: 'openai',
          apiKeys: ['test-key'],
          apiBaseUrl: 'https://api.openai.com/v1',
        ),
      ],
      modelProviderMap: const {_model: 'openai', 'gpt-4o': 'openai'},
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late db.AppDatabase database;
  late List<Override> overrides;
  late List<ApiConfig> sent;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final root = await Directory.systemTemp.createTemp('headless_reply_');
    final oldPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    TraceStore.instance.debugResetForTest();
    database = db.AppDatabase.forTesting(
      NativeDatabase(File('${root.path}/test.sqlite')),
    );
    addTearDown(() async {
      await database.close();
      PathProviderPlatform.instance = oldPaths;
      await root.delete(recursive: true);
    });

    final t = _now.millisecondsSinceEpoch;
    await database.into(database.conversations).insert(
          db.ConversationsCompanion.insert(
            id: _conv,
            title: '理',
            displayName: '理',
            personaPrompt: Value(
              PersonaPromptCodec.compose(userPrompt: '你是温柔的理。'),
            ),
            createdAt: t,
            updatedAt: t,
          ),
        );
    for (final (i, (role, text)) in [
      ('user', '早上好'),
      ('assistant', '早呀，今天想做什么？'),
    ].indexed) {
      await database.into(database.messages).insert(
            db.MessagesCompanion.insert(
              id: 'm$i',
              conversationId: _conv,
              role: role,
              content: text,
              createdAt: t - 3600000 + i * 1000,
            ),
          );
    }

    sent = [];
    overrides = [
      databaseProvider.overrideWithValue(database),
      appSettingsProvider.overrideWith(() => _Settings(_settings())),
      requestClockProvider.overrideWithValue(() => _now),
      memoryKeeperProvider.overrideWith(
        (ref) => MemoryKeeperService(
          store: ref.read(memoryStoreProvider),
          loadMessages: (_) async => const [],
          compactedBoundaries: (_) async => const {},
          agentFactory: () => throw StateError('memory agent disabled'),
          allowed: (_) async => false,
        ),
      ),
      proactiveReplyExecutorProvider.overrideWithValue(({
        required config,
        required sessionId,
        required userText,
        required turnId,
      }) async {
        sent.add(config);
        return const ApiCallResult(
          replyText: '想你啦，在忙吗？',
          processedText: '想你啦，在忙吗？',
          pluginEvents: [],
          toolResults: [],
        );
      }),
    ];
  });

  test('generates from the database and settings alone', () async {
    final reply = await generateHeadlessProactiveReply(
      conversationId: _conv,
      reminder: _reminder,
      turnId: 'bg_test',
      overrides: overrides,
    );

    expect(reply, '想你啦，在忙吗？');
    final config = sent.single;
    final messages = jsonEncode(config.messages);
    expect(messages, contains('你是温柔的理。'));
    expect(messages, contains('早呀，今天想做什么？'));
    expect((config.messages.last['content'] as String), contains(_reminder));
    expect(config.tools ?? const [], isEmpty);
  });

  test('the background request equals the foreground one', () async {
    await generateHeadlessProactiveReply(
      conversationId: _conv,
      reminder: _reminder,
      turnId: 'bg_test',
      overrides: overrides,
    );

    final container = ProviderContainer(overrides: overrides);
    addTearDown(container.dispose);
    final generator = container.read(proactiveReplyGeneratorProvider);
    final foreground = await generator.prepare(
      conversation: (await generator.loadConversation(_conv))!,
      reminder: _reminder,
    );

    expect(jsonEncode(sent.single.messages), jsonEncode(foreground.messages));
    expect(sent.single.modelFullId, foreground.modelFullId);
  });

  test('a reply written ahead uses the fire time, not the clock', () async {
    final container = ProviderContainer(
      overrides: [
        ...overrides,
        requestClockProvider.overrideWithValue(
          () => throw StateError('clock read'),
        ),
      ],
    );
    addTearDown(container.dispose);
    final generator = container.read(proactiveReplyGeneratorProvider);
    final conversation = (await generator.loadConversation(_conv))!;

    await expectLater(
      generator.prepare(conversation: conversation, reminder: _reminder),
      throwsStateError,
    );
    final config = await generator.prepare(
      conversation: conversation,
      reminder: _reminder,
      requestTime: _now.add(const Duration(hours: 3)),
    );
    expect(config.messages, isNotEmpty);
  });

  group('writing ahead with calls allowed (plan 12 §4.8)', () {
    Future<ProactiveDraft> draft({
      required bool allowCall,
      Future<ApiCallResult> Function(ApiConfig config)? reply,
    }) async {
      final container = ProviderContainer(
        overrides: [
          ...overrides,
          if (reply != null)
            proactiveReplyExecutorProvider.overrideWithValue(({
              required config,
              required sessionId,
              required userText,
              required turnId,
            }) {
              sent.add(config);
              return reply(config);
            }),
        ],
      );
      addTearDown(container.dispose);
      final generator = container.read(proactiveReplyGeneratorProvider);
      return generator.generateDraft(
        conversation: (await generator.loadConversation(_conv))!,
        reminder: _reminder,
        turnId: 'ahead',
        requestTime: _now,
        allowCall: allowCall,
      );
    }

    test('without permission the request has no tool and no hint', () async {
      final result = await draft(allowCall: false);

      expect(result.isCall, isFalse);
      expect(result.text, '想你啦，在忙吗？');
      expect(sent.single.tools ?? const [], isEmpty);
      expect(jsonEncode(sent.single.messages), isNot(contains('call_user')));
    });

    test('a call_user call becomes a call with its opening line', () async {
      final result = await draft(
        allowCall: true,
        reply: (config) async {
          // What the runner does with a bound tool call.
          final tool = config.boundTools!.single;
          await tool.handler({'opening_line': '喂～猜猜我是谁'});
          return const ApiCallResult(
            replyText: '',
            processedText: '',
            pluginEvents: [],
            toolResults: [],
          );
        },
      );

      expect(result.isCall, isTrue);
      expect(result.text, '喂～猜猜我是谁');
      final config = sent.single;
      expect(
        (config.tools!.single['function'] as Map)['name'],
        'call_user',
      );
      expect(
        config.messages.last['content'] as String,
        contains('用 call_user 直接打电话'),
      );
    });

    test('a written reply stays a message', () async {
      final result = await draft(
        allowCall: true,
        reply: (_) async => const ApiCallResult(
          replyText: '吃饱了吗',
          processedText: '吃饱了吗',
          pluginEvents: [],
          toolResults: [],
        ),
      );

      expect(result.isCall, isFalse);
      expect(result.text, '吃饱了吗');
    });
  });

  test('a missing conversation yields no reply and sends nothing', () async {
    final reply = await generateHeadlessProactiveReply(
      conversationId: 'gone',
      reminder: _reminder,
      turnId: 'bg_test',
      overrides: overrides,
    );

    expect(reply, isNull);
    expect(sent, isEmpty);
  });
}
