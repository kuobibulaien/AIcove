/// 离线转场探针：真实 CupertinoPageRoute + ChatPage，复用内存夹具。
/// flutter run --profile --no-resident -d <device> -t tool/chat_entry_probe.dart
/// adb logcat -s flutter | grep ChatEntryProbe
/// 手机需解锁前台；完成后用默认入口 flutter run --no-resident 恢复正常应用。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ui' show FramePhase;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/message_bubble.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_message_list.dart';
import 'package:aicove_flutter/src/features/chat/services/conversation_short_window_store.dart';
import 'package:aicove_flutter/src/ui/features/chat/pages/chat_page.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_message_list_display_cache.dart';
import 'package:aicove_flutter/src/ui/theme/skin_provider.dart';
import 'package:aicove_flutter/src/ui/theme/skins/moetalk_skin.dart';

import 'chat_segmented_fixture.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final fixture = await SegmentedChatFixture.create(historyCount: 0);
  runApp(UncontrolledProviderScope(
    container: fixture.container,
    child: SkinScope(
      skin: const MoeTalkSkin(),
      child: MaterialApp(home: _EntryProbe(fixture: fixture)),
    ),
  ));
}

class _EntryProbe extends StatefulWidget {
  const _EntryProbe({required this.fixture});
  final SegmentedChatFixture fixture;
  @override
  State<_EntryProbe> createState() => _EntryProbeState();
}

class _EntryProbeState extends State<_EntryProbe> with WidgetsBindingObserver {
  final frames = <FrameTiming>[];
  bool measuring = false;
  bool lostForeground = false;
  String progress = '等待解锁并进入前台；合成历史，不读取真实聊天';
  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(_record);
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback(
        (_) => unawaited(_run().catchError((Object error) {
              debugPrint('[ChatEntryProbe] ${jsonEncode({
                    'valid': false,
                    'errorType': error.runtimeType.toString()
                  })}');
            })));
  }

  void _record(List<FrameTiming> values) => frames.addAll(values);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (measuring && state != AppLifecycleState.resumed) lostForeground = true;
  }

  Future<void> _run() async {
    await Future<void>.delayed(const Duration(seconds: 2));
    while (mounted &&
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    if (!mounted) return;
    final hz = View.of(context).display.refreshRate;
    final budget = 1000000 / hz;
    measuring = true;
    final results = <Map<String, Object?>>[];
    final cache =
        widget.fixture.container.read(conversationTimelineCacheProvider);
    // warm 条件复用同一份长历史，冷条件清显示缓存但保留已准备的时间线。
    for (var round = 0; round < 3 && mounted; round++) {
      for (final scenario in ['short', 'long', 'warmLong']) {
        if (scenario != 'warmLong') {
          // ignore: invalid_use_of_visible_for_testing_member
          ChatMessageListDisplayCache.clear();
          final segments = scenario == 'short' ? 1 : 120;
          final history = List.generate(
              20,
              (i) => Message.text(
                    id: 'entry_${round}_$i',
                    role: i.isEven ? 'user' : 'assistant',
                    content: i.isEven
                        ? '离线问题 $i'
                        : List.generate(segments,
                                (j) => '第$round轮第$i条第$j段合成历史用于验证长聊天的页面进场排版。')
                            .join(),
                    createdAt: DateTime(2026, 1, 1).add(Duration(minutes: i)),
                    status: 'sent',
                  ));
          await cache.replaceMessages(
            conversationId: widget.fixture.conversation.id,
            removeMessageIds:
                (await cache.loadCachedMessages(widget.fixture.conversation.id))
                    .map((m) => m.id)
                    .toList(),
            messages: history,
          );
        }
        if (!mounted) return;
        setState(() => progress = '$scenario，第 ${round + 1}/3 轮');
        await SchedulerBinding.instance.endOfFrame;
        if (!mounted) return;
        final start = SchedulerBinding
            .instance.currentSystemFrameTimeStamp.inMicroseconds;
        final route = CupertinoPageRoute<void>(
            builder: (_) => ChatPage(
                  conversationId: widget.fixture.conversation.id,
                  initialConversation: widget.fixture.conversation,
                ));
        final completed = Completer<void>();
        unawaited(Navigator.of(context).push(route));
        route.animation!.addStatusListener((status) {
          if (status == AnimationStatus.completed && !completed.isCompleted) {
            completed.complete();
          }
        });
        await completed.future.timeout(const Duration(seconds: 10));
        await SchedulerBinding.instance.endOfFrame;
        final end = SchedulerBinding
            .instance.currentSystemFrameTimeStamp.inMicroseconds;
        lostForeground |=
            WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed;
        var sourceMessages = 0;
        var sourceCharacters = 0;
        var renderedBubbles = 0;
        var tailPresent = false;
        void inspect(Element element) {
          final widget = element.widget;
          if (widget is ChatMessageList) {
            sourceMessages = widget.messages.length;
            sourceCharacters =
                widget.messages.fold(0, (n, m) => n + m.content.length);
          }
          if (widget is MessageBubble) {
            renderedBubbles++;
            if (widget.message.id.startsWith('entry_${round}_19')) {
              tailPresent = true;
            }
          }
          element.visitChildren(inspect);
        }

        WidgetsBinding.instance.rootElement?.visitChildren(inspect);
        // FrameTiming 由引擎批量回传，按 vsync 时间窗筛选，不按回调到达时间归属。
        await Future<void>.delayed(const Duration(milliseconds: 1100));
        final selected = frames.where((f) {
          final stamp = f.timestampInMicroseconds(FramePhase.vsyncStart);
          return stamp > start && stamp <= end;
        }).toList();
        double percentile(Iterable<int> source, double p) {
          final list = source.toList()..sort();
          return list.isEmpty
              ? 0
              : list[((list.length - 1) * p).round()] / 1000;
        }

        final result = <String, Object?>{
          'scenario': scenario,
          'sourceMessages': sourceMessages,
          'sourceCharacters': sourceCharacters,
          'renderedBubbles': renderedBubbles,
          'tailPresent': tailPresent,
          'round': round,
          'frames': selected.length,
          'uiP95Ms': percentile(
              selected.map((f) => f.buildDuration.inMicroseconds), .95),
          'uiMaxMs': percentile(
              selected.map((f) => f.buildDuration.inMicroseconds), 1),
          'rasterMaxMs': percentile(
              selected.map((f) => f.rasterDuration.inMicroseconds), 1),
          'overBudget': selected
              .where((f) =>
                  f.buildDuration.inMicroseconds > budget ||
                  f.rasterDuration.inMicroseconds > budget)
              .length,
          'elapsedMs': (end - start) / 1000,
        };
        results.add(result);
        debugPrint('[ChatEntryProbe] ${jsonEncode(result)}');
        if (!mounted) return;
        Navigator.of(context).pop();
        await route.completed;
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }
    if (!mounted) return;
    debugPrint('[ChatEntryProbe] ${jsonEncode({
          'valid': !lostForeground &&
              results.length == 9 &&
              results.every((r) =>
                  (r['frames']! as int) >= 5 &&
                  r['sourceMessages'] == 20 &&
                  r['tailPresent'] == true),
          'refreshRate': hz,
          'runs': results.length,
          'lostForeground': lostForeground,
          'note':
              '合成纯文本热时间线；冷/热显示缓存；含真实ChatPage、分段和Cupertino转场；不含真实数据库冷读、网络和图片',
        })}');
    setState(() => progress = '完成，结果在 ChatEntryProbe 日志；请恢复正常入口');
  }

  @override
  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(_record);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('离线聊天转场测试')),
        body: Center(child: Text(progress)),
      );
}
