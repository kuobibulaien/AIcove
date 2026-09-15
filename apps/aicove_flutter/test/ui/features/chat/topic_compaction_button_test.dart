import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/domain/topic_compaction_port.dart';
import 'package:aicove_flutter/src/features/chat/providers/topic_compaction_provider.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/topic_compaction_button.dart';

class _Port implements TopicCompactionPort {
  final saved = <String, String>{};
  final archives = <bool>[];
  Completer<void>? gate;
  bool conflict = false, memory = true;
  bool Function()? cancelled;
  TopicCompactionDraft draft(String owner) {
    final message = Message(
        id: '$owner-raw',
        role: 'user',
        content: '$owner旧内容',
        createdAt: DateTime(2026));
    return TopicCompactionDraft(
        snapshot: TopicSnapshot(
            ownerId: owner,
            previousBoundaryId: null,
            allMessages: [message],
            messages: [message],
            previous: null),
        summary: '$owner：周五看海，怕冷',
        canArchive: memory);
  }

  @override
  Future<TopicCompactionDraft> prepare(String ownerId,
      {required void Function(int, int) onProgress,
      required bool Function() isCancelled}) async {
    cancelled = isCancelled;
    onProgress(0, 1);
    if (gate != null) await gate!.future;
    return draft(ownerId);
  }

  @override
  Future<TopicCompactionResult> commit(
      TopicCompactionDraft draft, String summary,
      {required bool archive}) async {
    if (conflict) throw const TopicCompactionException('聊天已发生变化，草稿仍保留');
    saved[draft.snapshot.ownerId] = summary;
    archives.add(archive);
    return TopicCompactionResult(
        TopicHandoff(
            id: 'id',
            ownerId: draft.snapshot.ownerId,
            boundaryId: draft.snapshot.boundaryId,
            previousBoundaryId: null,
            summary: summary,
            sourceIds: [],
            sourceDigest: '',
            createdAt: DateTime(2026),
            memoryState: 'off'),
        memoryPending: false);
  }

  @override
  Future<TopicHandoff?> current(String ownerId) async => null;
  @override
  Future<bool> retryArchive(String ownerId) async => true;
  @override
  Future<void> undo(String ownerId) async {}
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  Future<void> open(WidgetTester tester, _Port port,
      {bool generating = false}) async {
    await tester.pumpWidget(ProviderScope(
        overrides: [topicCompactionProvider.overrideWithValue(port)],
        child: MaterialApp(
            home: Scaffold(
                appBar: AppBar(actions: [
          TopicCompactionButton(ownerId: 'a', isGenerating: generating)
        ])))));
    if (!generating) await tester.tap(find.byTooltip('压缩并开启新话题'));
    await tester.pumpAndSettle();
  }

  for (final width in [360.0, 1000.0]) {
    testWidgets('$width：真实右上角入口，摘要预览/编辑/归档开关/保存', (tester) async {
      await tester.binding.setSurfaceSize(Size(width, 850));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final port = _Port();
      await open(tester, port);
      expect(find.text('压缩并开启新话题'), findsOneWidget);
      await tester.tap(find.text('整理内容'));
      await tester.pumpAndSettle();
      expect(port.saved, isEmpty);
      expect(find.text('a：周五看海，怕冷'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '周五看海，要带外套');
      await tester.ensureVisible(find.text('同时归档到该角色记忆'));
      await tester.tap(find.text('同时归档到该角色记忆'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存并开启'));
      await tester.pumpAndSettle();
      expect(port.saved, {'a': '周五看海，要带外套'});
      expect(port.archives, [false]);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    });
  }

  testWidgets('取消进行中的整理，迟到结果不切换话题', (tester) async {
    final port = _Port()..gate = Completer<void>();
    await open(tester, port);
    await tester.tap(find.text('整理内容'));
    await tester.pump();
    await tester.tap(find.text('取消整理'));
    await tester.pumpAndSettle();
    expect(port.cancelled!(), isTrue);
    port.gate!.complete();
    await tester.pumpAndSettle();
    expect(port.saved, isEmpty);
    expect(find.text('确认保留的内容'), findsNothing);
  });

  testWidgets('保存冲突保留手改草稿；键盘与窄屏无溢出', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 850));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final port = _Port()..conflict = true;
    await open(tester, port);
    await tester.tap(find.text('整理内容'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '手动修正的内容');
    tester.view.viewInsets = const FakeViewPadding(bottom: 250);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存并开启'));
    await tester.pumpAndSettle();
    expect(find.text('手动修正的内容'), findsOneWidget);
    expect(port.saved, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('生成中禁用右上角压缩入口', (tester) async {
    await open(tester, _Port(), generating: true);
    expect(
        tester.widget<IconButton>(find.byType(IconButton)).onPressed, isNull);
  });

  testWidgets('弹窗复用为 B，A 的迟到摘要不能回填或保存', (tester) async {
    final port = _Port()..gate = Completer<void>();
    final owner = ValueNotifier('a');
    addTearDown(owner.dispose);
    await tester.pumpWidget(MaterialApp(
        home: ValueListenableBuilder<String>(
            valueListenable: owner,
            builder: (_, id, __) =>
                TopicCompactionDialog(ownerId: id, port: port))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('整理内容'));
    await tester.pump();
    owner.value = 'b';
    await tester.pump();
    port.gate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('a：周五看海，怕冷'), findsNothing);
    expect(port.saved, isEmpty);
    port.gate = null;
    await tester.tap(find.text('整理内容'));
    await tester.pumpAndSettle();
    expect(find.text('b：周五看海，怕冷'), findsOneWidget);
  });
}
