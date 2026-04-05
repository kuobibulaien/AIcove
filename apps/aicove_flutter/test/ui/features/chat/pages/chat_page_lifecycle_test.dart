import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/features/chat/chat_providers.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/conversation_timeline_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/conversation_short_window_store.dart';
import 'package:aicove_flutter/src/features/observability/trace_models.dart';
import 'package:aicove_flutter/src/ui/features/chat/pages/chat_page.dart';
import 'package:aicove_flutter/src/ui/features/chat/pages/deferred_conversation_activation.dart';

class _ChatPageShortWindowHarness {
  const _ChatPageShortWindowHarness({
    required this.database,
    required this.container,
    required this.conversationId,
  });

  final db.AppDatabase database;
  final ProviderContainer container;
  final String conversationId;
}

Future<void> _insertConversation(
  db.AppDatabase database,
  String conversationId,
  int timestamp,
) {
  return database.into(database.conversations).insert(
        db.ConversationsCompanion.insert(
          id: conversationId,
          title: '测试会话',
          displayName: '测试会话',
          createdAt: timestamp,
          updatedAt: timestamp,
        ),
      );
}

Future<void> _insertMessage(
  db.AppDatabase database,
  String conversationId, {
  required String id,
  required String role,
  required String content,
  required int createdAt,
}) {
  return database.into(database.messages).insert(
        db.MessagesCompanion.insert(
          id: id,
          conversationId: conversationId,
          role: role,
          content: content,
          createdAt: createdAt,
        ),
      );
}

Future<_ChatPageShortWindowHarness> _createChatPageShortWindowHarness() async {
  final database = db.AppDatabase.forTesting(NativeDatabase.memory());
  const conversationId = 'conv_local_stage';
  final baseTime = DateTime(2026, 3, 27, 14, 0, 0).millisecondsSinceEpoch;
  await _insertConversation(database, conversationId, baseTime);

  for (var i = 1; i <= 40; i++) {
    await _insertMessage(
      database,
      conversationId,
      id: 'm$i',
      role: i.isOdd ? 'user' : 'assistant',
      content: 'message-$i',
      createdAt: baseTime + i,
    );
  }

  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(database),
    ],
  );

  final store = container.read(conversationTimelineCacheProvider);
  await store.reloadConversationFromRawStore(
    conversationId,
    targetMessageCount: kConversationInitialVisibleCount,
  );
  final addedCount = await store.loadOlderMessages(
    conversationId: conversationId,
    pageSize: 5,
  );
  expect(addedCount, 5);

  return _ChatPageShortWindowHarness(
    database: database,
    container: container,
    conversationId: conversationId,
  );
}

class _ActivationHarness extends ConsumerStatefulWidget {
  const _ActivationHarness({
    required this.conversationId,
    required this.activation,
  });

  final String conversationId;
  final DeferredConversationActivation activation;

  @override
  ConsumerState<_ActivationHarness> createState() => _ActivationHarnessState();
}

class _ActivationHarnessState extends ConsumerState<_ActivationHarness> {
  @override
  void initState() {
    super.initState();
    _scheduleActivation(widget.conversationId);
  }

  @override
  void didUpdateWidget(covariant _ActivationHarness oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.conversationId != widget.conversationId) {
      _scheduleActivation(widget.conversationId);
    }
  }

  void _scheduleActivation(String conversationId) {
    widget.activation.schedule(
      conversationId: conversationId,
      isMounted: () => mounted,
      readActiveConversationId: () => ref.read(activeConversationIdProvider),
      activateConversation: (id) {
        ref.read(activeConversationIdProvider.notifier).state = id;
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return const SizedBox.shrink();
  }
}

Widget _buildHost({
  required ProviderContainer container,
  required String conversationId,
  required DeferredConversationActivation activation,
}) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: _ActivationHarness(
        conversationId: conversationId,
        activation: activation,
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('进入页面时会话激活应延后到首帧后执行', (tester) async {
    final container = ProviderContainer();
    final activation = DeferredConversationActivation();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      _buildHost(
        container: container,
        conversationId: 'conv_a',
        activation: activation,
      ),
    );
    expect(tester.takeException(), isNull);

    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(container.read(activeConversationIdProvider), 'conv_a');
  });

  testWidgets('切换会话时不应在构建阶段直接写 provider', (tester) async {
    final container = ProviderContainer();
    final activation = DeferredConversationActivation();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      _buildHost(
        container: container,
        conversationId: 'conv_a',
        activation: activation,
      ),
    );
    await tester.pump();
    expect(container.read(activeConversationIdProvider), 'conv_a');

    await tester.pumpWidget(
      _buildHost(
        container: container,
        conversationId: 'conv_b',
        activation: activation,
      ),
    );
    expect(tester.takeException(), isNull);

    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(container.read(activeConversationIdProvider), 'conv_b');
  });

  test('聊天页上滑分页时，应先消费会话热缓存，再继续查数据库历史页', () async {
    final harness = await _createChatPageShortWindowHarness();
    addTearDown(harness.container.dispose);
    addTearDown(harness.database.close);

    final store = harness.container.read(conversationTimelineCacheProvider);
    final firstVisibleCount = await resolveChatPageLoadMoreVisibleCount(
      store: store,
      conversationId: harness.conversationId,
      currentVisibleCount: kConversationInitialVisibleCount,
    );
    expect(firstVisibleCount, 25);

    final secondVisibleCount = await resolveChatPageLoadMoreVisibleCount(
      store: store,
      conversationId: harness.conversationId,
      currentVisibleCount: firstVisibleCount,
    );
    expect(secondVisibleCount, 40);
  });

  test('退出监听后可见窗口应回到默认首屏大小，避免重进会话沿用旧窗口值', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final subscription = container.listen<int>(
      conversationVisibleCountProvider('conv_a'),
      (_, __) {},
      fireImmediately: true,
    );

    expect(subscription.read(), kConversationInitialVisibleCount);
    container.read(conversationVisibleCountProvider('conv_a').notifier).state =
        kConversationInitialVisibleCount + 12;
    expect(
      subscription.read(),
      kConversationInitialVisibleCount + 12,
    );

    subscription.close();
    await container.pump();

    expect(
      container.read(conversationVisibleCountProvider('conv_a')),
      kConversationInitialVisibleCount,
    );
  });

  test('loading 空窗若页面内缓存缺席，应回退到当前生命周期内的时间线热缓存', () {
    final now = DateTime(2026, 4, 4, 11, 0, 0);
    final fallbackMessages = resolveChatPageLoadingFallbackMessages(
      conversationId: 'conv_a',
      cachedConversationId: null,
      cachedMessages: const <Message>[],
      isGenerating: false,
      inMemoryTimelineMessages: <Message>[
        Message(
          id: 'msg_warm_user',
          role: 'user',
          content: '热缓存里的用户消息',
          createdAt: now,
          status: 'sent',
        ),
        Message(
          id: 'msg_warm_ai',
          role: 'assistant',
          content: '热缓存里的助手消息',
          createdAt: now.add(const Duration(milliseconds: 1)),
          status: 'sent',
        ),
      ],
    );

    expect(
      fallbackMessages.map((message) => message.id).toList(),
      <String>['msg_warm_user', 'msg_warm_ai'],
    );
  });

  test('AppBar 标题应跟当前会话最新进行中的 Trace 阶段走', () {
    final now = DateTime(2026, 3, 21, 12, 0, 0);
    final title = resolveChatPageAppBarTitle(
      displayName: 'Arona',
      conversationId: 'conv_a',
      chatStatus: ChatStatus.idle,
      traceEvents: <TraceEvent>[
        TraceEvent(
          traceId: 'trace_other',
          sessionId: 'conv_b',
          turnId: 'turn_other',
          roundIndex: 0,
          eventSeq: 1,
          stage: TraceStage.toolExecStarted.value,
          status: TraceEventStatus.success.value,
          source: 'ChatActions',
          startedAt: now,
          endedAt: now,
          durationMs: 0,
        ),
        TraceEvent(
          traceId: 'trace_a',
          sessionId: 'conv_a',
          turnId: 'turn_a',
          roundIndex: 0,
          eventSeq: 1,
          stage: TraceStage.turnStarted.value,
          status: TraceEventStatus.success.value,
          source: 'ChatActions',
          startedAt: now,
          endedAt: now,
          durationMs: 0,
        ),
        TraceEvent(
          traceId: 'trace_a',
          sessionId: 'conv_a',
          turnId: 'turn_a',
          roundIndex: 0,
          eventSeq: 2,
          stage: TraceStage.toolExecStarted.value,
          status: TraceEventStatus.success.value,
          source: 'ChatActions',
          startedAt: now.add(const Duration(milliseconds: 200)),
          endedAt: now.add(const Duration(milliseconds: 200)),
          durationMs: 0,
        ),
      ],
    );

    expect(title, '工具执行中');
  });

  test('AppBar 标题在图片生成中时应优先显示图片生成状态', () {
    final now = DateTime(2026, 3, 21, 12, 0, 0);
    final title = resolveChatPageAppBarTitle(
      displayName: 'Arona',
      conversationId: 'conv_a',
      chatStatus: ChatStatus.generatingImage,
      traceEvents: <TraceEvent>[
        TraceEvent(
          traceId: 'trace_a',
          sessionId: 'conv_a',
          turnId: 'turn_a',
          roundIndex: 0,
          eventSeq: 1,
          stage: TraceStage.toolExecStarted.value,
          status: TraceEventStatus.success.value,
          source: 'ChatActions',
          startedAt: now,
          endedAt: now,
          durationMs: 0,
        ),
      ],
    );

    expect(title, ChatStatus.generatingImage.label);
  });

  test('AppBar 标题在当前会话没有进行中的 Trace 时应回退为角色名', () {
    final now = DateTime(2026, 3, 21, 12, 0, 0);
    final title = resolveChatPageAppBarTitle(
      displayName: 'Arona',
      conversationId: 'conv_a',
      chatStatus: ChatStatus.idle,
      traceEvents: <TraceEvent>[
        TraceEvent(
          traceId: 'trace_done',
          sessionId: 'conv_a',
          turnId: 'turn_done',
          roundIndex: 0,
          eventSeq: 1,
          stage: TraceStage.turnStarted.value,
          status: TraceEventStatus.success.value,
          source: 'ChatActions',
          startedAt: now,
          endedAt: now,
          durationMs: 0,
        ),
        TraceEvent(
          traceId: 'trace_done',
          sessionId: 'conv_a',
          turnId: 'turn_done',
          roundIndex: 0,
          eventSeq: 2,
          stage: TraceStage.turnCompleted.value,
          status: TraceEventStatus.success.value,
          source: 'ChatActions',
          startedAt: now.add(const Duration(milliseconds: 100)),
          endedAt: now.add(const Duration(milliseconds: 100)),
          durationMs: 0,
        ),
        TraceEvent(
          traceId: 'trace_other_running',
          sessionId: 'conv_b',
          turnId: 'turn_other_running',
          roundIndex: 0,
          eventSeq: 1,
          stage: TraceStage.toolExecStarted.value,
          status: TraceEventStatus.success.value,
          source: 'ChatActions',
          startedAt: now.add(const Duration(milliseconds: 200)),
          endedAt: now.add(const Duration(milliseconds: 200)),
          durationMs: 0,
        ),
      ],
    );

    expect(title, 'Arona');
  });
}
