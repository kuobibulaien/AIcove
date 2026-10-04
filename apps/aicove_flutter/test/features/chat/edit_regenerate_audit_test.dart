// 编辑/重生成生命周期回归；仅内存DB和可控端口，不调用真实模型。
import 'dart:async';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/features/chat/application/chat_ports.dart';
import 'package:aicove_flutter/src/features/chat/chat_actions.dart';
import 'package:aicove_flutter/src/features/chat/chat_layer_providers.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_history_store.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/core/app_logger.dart';
import 'package:aicove_flutter/src/features/observability/frontend_diagnostics_provider.dart';
import 'package:aicove_flutter/src/features/observability/frontend_diagnostics_service.dart';

final _owner = StateProvider<Conversation?>((ref) => null);

class AuditSettings extends AppSettingsNotifier {
  AuditSettings(this.pending);
  final Future<AppSettings> pending;
  @override
  Future<AppSettings> build() => pending;
}

const auditSettings = AppSettings(
  ttsEnabled: false,
  defaultModelName: 'test',
  defaultPersonaPrompt: '',
  modelList: [],
  allKnownModels: [],
  modelDisplayNames: {},
  modelTypes: {},
  modelConfigs: {},
  apiKey: '',
  apiBaseUrl: '',
  imageGenerationEnabled: false,
  maxFileUploadMB: 10,
  contextWindowTokens: 272000,
  customModels: [],
  providers: [],
  modelProviderMap: {},
  backendApiKey: '',
  messageChunkingEnabled: false,
  messageFormatConfig: MessageFormatConfig(),
  textScaleFactor: 1,
  uiScaleFactor: 1,
  autoReplySettings: AutoReplySettings(),
  globalBackgroundColor: GlobalBackgroundColor.white,
  chatBackgroundColor: ChatBackgroundColor.defaultColor,
  isDarkMode: false,
  useSystemTheme: false,
  accentColor: 'FC96AA',
);

class AuditSend implements ChatSendPort {
  String? historyOwner;
  @override
  Future<List<Message>> prepareHistoryFromStore(
      {required Conversation conv,
      required Message userMsg,}) async {
    historyOwner = conv.id;
    throw StateError('audit stop before network');
  }

  @override
  Future<List<Message>> loadConversationMessagesFromStore(
      {required Conversation conv, Message? ensureTailMessage}) async {
    historyOwner = conv.id;
    throw StateError('audit stop before enhanced network');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class AuditHistory implements ChatHistoryPort {
  AuditHistory(this.messages);
  final List<Message> messages;
  Completer<List<Message>>? pendingRead;
  int reads = 0;
  int truncations = 0;
  bool failTruncate = true;
  bool failRead = false;
  final truncated = Completer<void>();
  @override
  Future<List<Message>> loadRawMessages(String conversationId) async {
    reads++;
    if (failRead) throw StateError('audit read failure');
    return pendingRead == null ? messages : await pendingRead!.future;
  }

  @override
  Future<void> truncateAfterMessage(
      {required String conversationId, required String anchorMessageId}) async {
    truncations++;
    if (!truncated.isCompleted) truncated.complete();
    if (failTruncate) throw StateError('audit truncate failure');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final time = DateTime(2026, 9, 6);
  final conv = Conversation(
      id: 'audit',
      title: 'audit',
      displayName: 'audit',
      createdAt: time,
      updatedAt: time);
  final user = Message(id: 'u', role: 'user', content: 'test', createdAt: time);
  final ai = Message(
      id: 'a',
      role: 'assistant',
      content: 'reply',
      createdAt: time.add(const Duration(seconds: 1)));
  late db.AppDatabase database;
  late ProviderContainer container;
  final diagnosticEntries = <LogEntry>[];
  ProviderContainer makeContainer(
      {ChatHistoryPort? history,
      AuditSend? send,
      Future<AppSettings>? settings}) {
    final result = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(database),
      frontendDiagnosticsProvider.overrideWithValue(
          FrontendDiagnosticsService(sink: diagnosticEntries.add)),
      activeConversationProvider.overrideWith((ref) => ref.watch(_owner)),
      if (history != null) chatHistoryPortProvider.overrideWithValue(history),
      if (send != null) chatSendPortProvider.overrideWithValue(send),
      if (settings != null)
        appSettingsProvider.overrideWith(() => AuditSettings(settings)),
    ]);
    result.read(_owner.notifier).state = conv;
    return result;
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    diagnosticEntries.clear();
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    await database.into(database.conversations).insert(
        db.ConversationsCompanion.insert(
            id: conv.id,
            title: conv.title,
            displayName: conv.displayName,
            createdAt: time.millisecondsSinceEpoch,
            updatedAt: time.millisecondsSinceEpoch));
    for (final m in [user, ai]) {
      await database.into(database.messages).insert(db.MessagesCompanion.insert(
          id: m.id,
          conversationId: conv.id,
          role: m.role,
          content: m.content,
          createdAt: m.createdAt.millisecondsSinceEpoch));
    }
    container = makeContainer();
  });
  tearDown(() async {
    container.dispose();
    await database.close();
  });

  test('R01 慢历史读取开始时应立即锁定重新生成按钮', () async {
    final history = AuditHistory([user, ai])
      ..pendingRead = Completer<List<Message>>();
    container.dispose();
    container = makeContainer(history: history);
    final pending = container.read(chatActionsProvider).regenerate(ai.id);
    await Future<void>.delayed(Duration.zero);
    final busy = container.read(conversationSendingProvider(conv.id));
    history.pendingRead!.complete([]); // 结束读取，不调用模型。
    await pending;
    expect(busy, isTrue, reason: '等待历史时没有忙碌状态，用户可重复触发');
  });

  test('R02 重新生成截断失败必须释放sending状态', () async {
    final history = AuditHistory([user, ai]);
    container.dispose();
    container = makeContainer(history: history);
    await expectLater(
        container.read(chatActionsProvider).regenerate(ai.id), completes);
    expect(container.read(errorProvider), contains('audit truncate failure'));
    expect(history.reads, 1, reason: '定位原消息应复用同一次raw读取');
    expect(container.read(conversationSendingProvider(conv.id)), isFalse);
  });

  test('R03 截断必须包含已被前端隐藏的后续raw消息', () async {
    final store = container.read(chatHistoryStoreProvider);
    await store.hideMessagesInFrontendTimeline(conv.id, [ai.id]);
    await store.truncateAfterMessage(
        conversationId: conv.id, anchorMessageId: user.id);
    expect(
        (await store.loadAllRawMessages(conv.id)).map((m) => m.id), [user.id]);
  });

  test('R04 编辑不得在已有生成进行中直接删除其用户消息', () async {
    container.read(conversationSendingProvider(conv.id).notifier).state = true;
    await expectLater(container.read(chatActionsProvider).editMessage(user.id),
        throwsStateError);
    final remaining = await container
        .read(chatHistoryStoreProvider)
        .loadAllRawMessages(conv.id);
    expect(remaining.map((m) => m.id), [user.id, ai.id],
        reason: '生成中应拒绝编辑，不删除正在使用的原历史');
  });

  test('R05 同会话连续点击只进入一次历史读取', () async {
    final history = AuditHistory([user, ai])
      ..pendingRead = Completer<List<Message>>();
    container.dispose();
    container = makeContainer(history: history);
    final actions = container.read(chatActionsProvider);
    final first = actions.regenerate(ai.id);
    final second = actions.regenerate(ai.id);
    await Future<void>.delayed(Duration.zero);
    final reads = history.reads;
    history.pendingRead!.complete([]);
    await Future.wait([first, second]);
    expect(reads, 1);
    expect(container.read(conversationSendingProvider(conv.id)), isFalse);
  });

  test('R06 读取期间取消，晚到历史不得删除旧回复', () async {
    final history = AuditHistory([user, ai])
      ..pendingRead = Completer<List<Message>>();
    container.dispose();
    container = makeContainer(history: history);
    final actions = container.read(chatActionsProvider);
    final pending = actions.regenerate(ai.id);
    await Future<void>.delayed(Duration.zero);
    final stopped = await actions.interruptCurrentGeneration(convId: conv.id);
    history.pendingRead!.complete([user, ai]);
    try {
      await pending;
    } on StateError {/* 未修复版本的截断故障由下面断言揭示。 */}
    expect(stopped, isTrue);
    expect(history.truncations, 0);
    expect(container.read(conversationSendingProvider(conv.id)), isFalse);
  });

  test('生成中编辑先停止旧轮次，晚到读取不截断编辑历史', () async {
    final history = AuditHistory([user, ai])
      ..pendingRead = Completer<List<Message>>();
    container.dispose();
    container = makeContainer(history: history);
    final actions = container.read(chatActionsProvider);
    final pending = actions.regenerate(ai.id);
    await Future<void>.delayed(Duration.zero);
    try {
      expect(await actions.editMessage(user.id), user.content);
      expect(container.read(conversationSendingProvider(conv.id)), isFalse);
      expect(container.read(chatEditSeedProvider(conv.id))?.draft.messageId,
          user.id);
      expect((await container.read(chatHistoryStoreProvider)
          .loadAllRawMessages(conv.id)).map((m) => m.id), [user.id, ai.id]);
    } finally {
      history.pendingRead!.complete([user, ai]);
      await pending;
    }
    expect(history.truncations, 0);
  });

  test('R07 历史读取失败也必须正常报告并释放状态', () async {
    final history = AuditHistory([user, ai])..failRead = true;
    container.dispose();
    container = makeContainer(history: history);
    await expectLater(
        container.read(chatActionsProvider).regenerate(ai.id), completes);
    expect(container.read(errorProvider), contains('audit read failure'));
    expect(container.read(conversationSendingProvider(conv.id)), isFalse);
  });

  test('R09 取消旧读取后开始新一轮，旧finally不得解开新发送锁', () async {
    final firstRead = Completer<List<Message>>();
    final history = AuditHistory([user, ai])..pendingRead = firstRead;
    container.dispose();
    container = makeContainer(history: history);
    final actions = container.read(chatActionsProvider);
    final first = actions.regenerate(ai.id);
    await Future<void>.delayed(Duration.zero);
    expect(await actions.interruptCurrentGeneration(convId: conv.id), isTrue);
    final secondRead = Completer<List<Message>>();
    history.pendingRead = secondRead;
    final second = actions.regenerate(ai.id);
    await Future<void>.delayed(Duration.zero);
    firstRead.complete([]);
    await first;
    final busyAfterOldFinished =
        container.read(conversationSendingProvider(conv.id));
    secondRead.complete([]);
    await second;
    expect(busyAfterOldFinished, isTrue);
    expect(history.reads, 2);
    expect(history.truncations, 0);
    expect(container.read(conversationSendingProvider(conv.id)), isFalse);
  });

  test('R10 已有发送占用时拒绝重生成且不释放别人的锁', () async {
    final history = AuditHistory([user, ai]);
    container.dispose();
    container = makeContainer(history: history);
    container.read(conversationSendingProvider(conv.id).notifier).state = true;
    await container.read(chatActionsProvider).regenerate(ai.id);
    expect(history.reads, 0);
    expect(container.read(conversationSendingProvider(conv.id)), isTrue);
  });

  for (final enhanced in [false, true]) {
    test('R08 等待设置时切会话仍使用原owner enhanced=$enhanced', () async {
      final history = AuditHistory([user, ai])..failTruncate = false;
      final settings = Completer<AppSettings>();
      final send = AuditSend();
      container.dispose();
      container = makeContainer(
          history: history, send: send, settings: settings.future);
      final actions = container.read(chatActionsProvider);
      final pending = enhanced
          ? actions.regenerateWithEnhancement(ai.id)
          : actions.regenerate(ai.id);
      await history.truncated.future;
      container.read(_owner.notifier).state = conv.copyWith(id: 'other');
      container.read(errorProvider.notifier).state = 'other error';
      container.read(chatStatusProvider.notifier).state =
          ChatStatus.generatingImage;
      settings.complete(auditSettings.copyWith(
          enhancedDialogueSettings:
              const EnhancedDialogueSettings(enabled: true)));
      await pending;
      expect(send.historyOwner, conv.id);
      expect(container.read(conversationSendingProvider(conv.id)), isFalse);
      expect(container.read(conversationSendingProvider('other')), isFalse);
      expect(container.read(errorProvider), 'other error');
      expect(container.read(chatStatusProvider), ChatStatus.generatingImage);
      await Future<void>.delayed(Duration.zero);
      final preparation = diagnosticEntries
          .map((entry) => entry.metadata)
          .where((meta) =>
              meta?['event'] == 'sendRequested' && meta?['phase'] == 'end')
          .single!;
      expect(preparation['state'], containsPair('regenerate', true));
      expect(preparation['state'], containsPair('enhanced', enhanced));
      expect(preparation['state']['historyReadMs'], isNonNegative);
      expect(preparation['state']['truncateMs'], isNonNegative);
    });
  }
}
