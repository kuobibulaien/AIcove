// Real-model check for plan 12 B4 (opt-in): with calls allowed, DeepSeek
// Flash gets the `call_user` tool while writing ahead for a playful role and
// either calls or writes a message; the request must be accepted and the
// draft non-empty. Skipped unless DEEPSEEK_API_KEY is set.
import 'dart:io';

import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/context_analyzer.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/proactive_reply_generator.dart';
import 'package:aicove_flutter/src/features/auto_reply/domain/proactive_decision.dart';
import 'package:aicove_flutter/src/features/chat/domain/persona_prompt_codec.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_backend_service.dart';
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

final String? _key = Platform.environment['DEEPSEEK_API_KEY'];

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
const _model = 'openai:deepseek-flash';
const _conv = 'conv_headless';

AppSettings _settings() =>
    mapUiModelsToAppSettings({'context_window_tokens': 272000}).copyWith(
      defaultModelName: _model,
      defaultChatModels: const [_model],
      modelConfigs: {
        _model: ModelConfig(chatCapabilities: const ['tools']),
      },
      modelTypes: const {_model: 'chat'},
      providers: [
        ProviderAuth(
          id: 'openai',
          apiKeys: [_key ?? ''],
          apiBaseUrl: 'https://api.deepseek.com',
        ),
      ],
      modelProviderMap: const {_model: 'openai', 'deepseek-flash': 'openai'},
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The test binding answers every HTTP request with 400; this one is real.
  HttpOverrides.global = null;

  for (final (label, persona) in const [
    ('playful', '你是小柚，古灵精怪、黏人，最喜欢突然打电话吓对方一跳，想到什么就直接打过去，很少只发文字。'),
    ('quiet', '你是小柚，文静内向，不太爱打电话，更习惯慢慢打字聊天，怕打扰对方。'),
  ]) {
    test(
      'the $label role writes ahead with call_user offered',
      () => _writeAhead(label, persona),
      skip: _key == null ? 'DEEPSEEK_API_KEY not set' : false,
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }
}

Future<void> _writeAhead(String label, String persona) async {
  SharedPreferences.setMockInitialValues({});
  final root = await Directory.systemTemp.createTemp('call_real_');
  final oldPaths = PathProviderPlatform.instance;
  PathProviderPlatform.instance = _Paths(root.path);
  TraceStore.instance.debugResetForTest();
  final database = db.AppDatabase.forTesting(
    NativeDatabase(File('${root.path}/test.sqlite')),
  );
  addTearDown(() async {
    await database.close();
    PathProviderPlatform.instance = oldPaths;
    await root.delete(recursive: true);
  });
  final t = _now.millisecondsSinceEpoch;
  await database
      .into(database.conversations)
      .insert(
        db.ConversationsCompanion.insert(
          id: _conv,
          title: '小柚',
          displayName: '小柚',
          personaPrompt: Value(PersonaPromptCodec.compose(userPrompt: persona)),
          createdAt: t,
          updatedAt: t,
        ),
      );
  for (final (i, (role, text)) in [
    ('user', '我去开个会，一个小时'),
    ('assistant', '去吧去吧，开完记得想我'),
  ].indexed) {
    await database
        .into(database.messages)
        .insert(
          db.MessagesCompanion.insert(
            id: 'm$i',
            conversationId: _conv,
            role: role,
            content: text,
            createdAt: t - 3600000 + i * 1000,
          ),
        );
  }
  final container = ProviderContainer(
    overrides: [
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
    ],
  );
  addTearDown(container.dispose);
  final generator = container.read(proactiveReplyGeneratorProvider);
  final reminder = ContextAnalyzer.buildReachOutReminder(
    kind: ProactiveReachOutKind.checkIn,
    fireAt: _now,
    lastUserAt: _now.subtract(const Duration(hours: 1)),
  );

  final draft = await generator.generateDraft(
    conversation: (await generator.loadConversation(_conv))!,
    reminder: reminder,
    turnId: 'real_call',
    requestTime: _now,
    allowCall: true,
  );
  // ignore: avoid_print
  print('$label ${draft.action.id}: ${draft.text}');
  expect(draft.text.trim(), isNotEmpty);
}
