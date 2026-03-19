import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/conversation_timeline_providers.dart';
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
}
