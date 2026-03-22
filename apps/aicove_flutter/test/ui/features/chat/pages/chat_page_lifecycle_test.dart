import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/conversation_timeline_providers.dart';
import 'package:aicove_flutter/src/features/observability/trace_models.dart';
import 'package:aicove_flutter/src/ui/features/chat/pages/chat_page.dart';
import 'package:aicove_flutter/src/ui/features/chat/pages/deferred_conversation_activation.dart';

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

  test('聊天页常规进入时应启用持久首屏快照直出', () {
    expect(
      resolveChatPageAllowPersistentViewportBoot(
        conversationId: 'conv_a',
        deferEntryShell: false,
      ),
      isTrue,
    );
  });

  test('聊天页延迟壳或无会话时不应启用持久首屏快照直出', () {
    expect(
      resolveChatPageAllowPersistentViewportBoot(
        conversationId: 'conv_a',
        deferEntryShell: true,
      ),
      isFalse,
    );
    expect(
      resolveChatPageAllowPersistentViewportBoot(
        conversationId: null,
        deferEntryShell: false,
      ),
      isFalse,
    );
    expect(
      resolveChatPageAllowPersistentViewportBoot(
        conversationId: '   ',
        deferEntryShell: false,
      ),
      isFalse,
    );
  });

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

  test('退出监听后可见窗口应保留最近一次历史窗口大小', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final subscription = container.listen<int>(
      conversationVisibleCountProvider('conv_a'),
      (_, __) {},
      fireImmediately: true,
    );

    expect(subscription.read(), kConversationInitialVisibleCount);
    container.read(conversationVisibleCountProvider('conv_a').notifier).state =
        12;
    expect(subscription.read(), 12);

    subscription.close();
    await container.pump();

    expect(
      container.read(conversationVisibleCountProvider('conv_a')),
      12,
    );
  });

  test('AppBar 标题应跟当前会话最新进行中的 Trace 阶段走', () {
    final now = DateTime(2026, 3, 21, 12, 0, 0);
    final title = resolveChatPageAppBarTitle(
      displayName: 'Arona',
      conversationId: 'conv_a',
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

  test('AppBar 标题在当前会话没有进行中的 Trace 时应回退为角色名', () {
    final now = DateTime(2026, 3, 21, 12, 0, 0);
    final title = resolveChatPageAppBarTitle(
      displayName: 'Arona',
      conversationId: 'conv_a',
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
