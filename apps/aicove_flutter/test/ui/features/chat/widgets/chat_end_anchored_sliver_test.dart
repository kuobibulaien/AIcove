import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_end_anchored_sliver.dart';

/// 最小台架：与聊天列表同构的 reverse + center 双 sliver 视口，活跃区
/// 放一个高度可变的盒子，验证长高发生的那一帧内容末端就已贴底。
class _Host extends StatefulWidget {
  const _Host({super.key, required this.controller});
  final ChatEndAnchorController controller;
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  double activeHeight = 200;
  final scrollController = ScrollController();
  final centerKey = const ValueKey<String>('center');

  void grow(double delta) => setState(() => activeHeight += delta);

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      controller: scrollController,
      reverse: true,
      center: centerKey,
      slivers: [
        ChatEndAnchoredSliver(
          controller: widget.controller,
          sliver: SliverPadding(
            padding: const EdgeInsets.only(bottom: 20),
            sliver: SliverToBoxAdapter(
              child: SizedBox(
                key: const ValueKey<String>('active'),
                height: activeHeight,
              ),
            ),
          ),
        ),
        SliverToBoxAdapter(key: centerKey, child: const SizedBox.shrink()),
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) => SizedBox(height: 60, key: ValueKey(index)),
            childCount: 40,
          ),
        ),
      ],
    );
  }
}

Future<GlobalKey<_HostState>> _pump(
  WidgetTester tester,
  ChatEndAnchorController controller,
) async {
  final key = GlobalKey<_HostState>();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 500,
          width: 300,
          child: _Host(key: key, controller: controller),
        ),
      ),
    ),
  );
  await tester.pump();
  return key;
}

double _distanceToBottom(GlobalKey<_HostState> key) {
  final position = key.currentState!.scrollController.position;
  return position.pixels - position.minScrollExtent;
}

void main() {
  testWidgets('arm 后首帧布局即把活跃区末端修正到底部（含 padding）', (tester) async {
    final controller = ChatEndAnchorController();
    controller.arm();
    final key = await _pump(tester, controller);
    expect(_distanceToBottom(key), lessThanOrEqualTo(0.5),
        reason: '首帧不经 post-frame jumpTo 就应贴底');
    final activeBottom =
        tester.getBottomLeft(find.byKey(const ValueKey<String>('active'))).dy;
    final viewportBottom =
        tester.getBottomLeft(find.byType(CustomScrollView)).dy;
    expect(viewportBottom - activeBottom, closeTo(20, 0.5),
        reason: '末端与视口底部只差 SliverPadding 的 bottom');
  });

  testWidgets('armed 期间内容长高：长高那一帧就贴底，不出现错帧', (tester) async {
    final controller = ChatEndAnchorController();
    controller.arm();
    final key = await _pump(tester, controller);
    expect(_distanceToBottom(key), lessThanOrEqualTo(0.5));

    for (var step = 0; step < 3; step++) {
      controller.arm();
      key.currentState!.grow(80);
      await tester.pump();
      expect(_distanceToBottom(key), lessThanOrEqualTo(0.5),
          reason: '第$step次长高的同一帧内应保持贴底');
    }
  });

  testWidgets('未 arm 时长高不修正：detached 阅读位置不被抢', (tester) async {
    final controller = ChatEndAnchorController();
    controller.arm();
    final key = await _pump(tester, controller);
    await tester.pump();
    await tester.pump();
    expect(controller.isArmed, isFalse, reason: '一帧无修正后应自动解除，避免残留状态影响后续帧');

    key.currentState!.scrollController.jumpTo(
      key.currentState!.scrollController.position.minScrollExtent + 150,
    );
    await tester.pump();
    final before = _distanceToBottom(key);
    expect(before, closeTo(150, 0.5));

    key.currentState!.grow(80);
    await tester.pump();
    expect(_distanceToBottom(key), closeTo(before + 80, 0.5),
        reason: '未 arm 时 pixels 不动，距底随长高等量增大（画面稳定）');
  });

  testWidgets('同一帧重复 arm 不得使自动解除失联', (tester) async {
    final controller = ChatEndAnchorController();
    controller.arm();
    controller.arm();
    await _pump(tester, controller);
    await tester.pump();
    await tester.pump();
    expect(controller.isArmed, isFalse, reason: '连续流增量会在一帧里多次 arm，不能永久残留贴底修正');
  });

  testWidgets('disarm 后立即失效', (tester) async {
    final controller = ChatEndAnchorController();
    controller.arm();
    final key = await _pump(tester, controller);
    controller.arm();
    controller.disarm();
    key.currentState!.grow(80);
    await tester.pump();
    expect(_distanceToBottom(key), closeTo(80, 0.5));
  });

  testWidgets('hold 为真时跨多帧保持 armed（入场动画期逐帧长高全程贴底）', (tester) async {
    var hold = true;
    final controller = ChatEndAnchorController(isHoldActive: () => hold);
    controller.arm();
    final key = await _pump(tester, controller);
    for (var step = 0; step < 4; step++) {
      await tester.pump();
    }
    expect(controller.isArmed, isTrue);
    key.currentState!.grow(60);
    await tester.pump();
    expect(_distanceToBottom(key), lessThanOrEqualTo(0.5));
    hold = false;
    await tester.pump();
    await tester.pump();
    expect(controller.isArmed, isFalse);
  });
}
