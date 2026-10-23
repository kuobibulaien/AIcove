import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/core/database/converters/database_converters.dart';
import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/task_agent/application/task_agent_runner.dart';
import 'package:aicove_flutter/src/features/task_agent/application/task_agent_service.dart';
import 'package:aicove_flutter/src/features/task_agent/data/agent_task_store.dart';
import 'package:aicove_flutter/src/features/task_agent/data/task_process_record.dart';
import 'package:aicove_flutter/src/features/task_agent/domain/agent_task.dart';
import 'package:aicove_flutter/src/features/task_agent/task_agent_providers.dart';
import 'package:aicove_flutter/src/ui/features/task_agent/task_agent_pages.dart';
import 'package:aicove_flutter/src/ui/features/task_agent/task_receipt_bubble.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Source-rendered previews: `--dart-define=WRITE_TASK_PREVIEW=true`.
const _capture = bool.fromEnvironment('WRITE_TASK_PREVIEW');

void main() {
  late db.AppDatabase database;
  late AgentTaskStore store;
  late Directory dir;
  late TaskAgentService service;
  late TaskReceiptBlock doneReceipt;
  var seeded = false;

  setUp(() {
    seeded = false;
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    store = AgentTaskStore(database);
    dir = Directory.systemTemp.createTempSync('task_pages_test');
  });

  /// Real database work, run outside the widget test's fake clock.
  Future<void> seed() async {
    if (seeded) return;
    seeded = true;
    await database
        .into(database.conversations)
        .insert(
          db.ConversationsCompanion.insert(
            id: 'c1',
            title: 'c1',
            displayName: 'c1',
            createdAt: 0,
            updatedAt: 0,
          ),
        );
    Future<RecordedReceipt?> finished(
      String id,
      String instruction,
      AgentTaskStatus to, {
      String summary = '',
      String? question,
    }) async {
      await store.create(
        id: id,
        requestKey: id,
        conversationId: 'c1',
        instruction: instruction,
      );
      await store.markRunning(id);
      return store.finish(
        id,
        from: {AgentTaskStatus.running},
        to: to,
        executorDevice: 'mac',
        summary: summary,
        question: question,
      );
    }

    doneReceipt = (await finished(
      'weather',
      '查一下杭州明天的天气，顺便看要不要带伞',
      AgentTaskStatus.done,
      summary: '杭州明天小雨转阴，14～19 度，午后降水概率 70%，建议带伞。',
    ))!.block;
    await finished(
      'hotel',
      '帮我比较一下西湖附近的三家酒店',
      AgentTaskStatus.needsInput,
      summary: '找到 8 家，需要确认预算。',
      question: '每晚预算大概多少？',
    );
    await store.create(
      id: 'notes',
      requestKey: 'notes',
      conversationId: 'c1',
      instruction: '把读书笔记按作者整理成目录',
    );
    await store.setSwitch(false);
    await store.setSwitch(true);
    await TaskProcessRecord(dir).appendLog(
      'weather',
      '第 1 轮',
      '- 调用 web_search {"query":"杭州 明天 天气"}\n  结果：小雨转阴 14～19℃',
    );
    service = TaskAgentService(
      store: store,
      process: TaskProcessRecord(dir),
      runner: TaskAgentRunner(
        loadSettings: () => throw UnimplementedError(),
        executor:
            ({
              required config,
              required tools,
              required sessionId,
              required cancellation,
            }) => throw UnimplementedError(),
      ),
      capabilities: (_, _, _) async => const TaskAgentCapabilities(),
      writeReceipt: (_) async {},
      relay: (_, _) async => true,
      findReceipt: (_) async => null,
      ownsConversation: (_) async => true,
      deviceId: () async => 'mac',
    );
  }

  tearDown(() => dir.delete(recursive: true));

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    // Not pumpAndSettle: the switch keeps a ticker running.
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<GlobalKey> mount(
    WidgetTester tester,
    double width,
    Widget primary,
  ) async {
    await tester.runAsync(seed);
    // The in-memory database is left open: closing it waits forever on work
    // queued under the widget test's fake clock.
    if (_capture) {
      await tester.runAsync(() async {
        final text = FontLoader('Preview')
          ..addFont(
            File(
              '/System/Library/Fonts/STHeiti Medium.ttc',
            ).readAsBytes().then(ByteData.sublistView),
          );
        await text.load();
        final icons = FontLoader('MaterialIcons')
          ..addFont(
            File(
              '${Platform.environment['HOME']}/dev-sdks/flutter-3.44.6/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
            ).readAsBytes().then(ByteData.sublistView),
          );
        await icons.load();
      });
    }
    tester.view.physicalSize = Size(width, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final boundary = GlobalKey();
    final navigator = GlobalKey<NavigatorState>();
    final observer = MoeDetailStackObserver();
    addTearDown(observer.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          agentTaskStoreProvider.overrideWithValue(store),
          taskAgentServiceProvider.overrideWith((ref) async => service),
        ],
        child: MaterialApp(
          theme: ThemeData(
            fontFamily: _capture ? 'Preview' : null,
            extensions: [MoeColors.light(accentColor: moePrimary)],
          ),
          home: RepaintBoundary(
            key: boundary,
            child: MoeAdaptiveShell(
              primary: primary,
              navigatorKey: navigator,
              observer: observer,
              detail: Navigator(
                key: navigator,
                observers: [observer],
                onGenerateRoute: (_) => MaterialPageRoute(
                  builder: (_) => const MoeWorkspacePlaceholder(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await settle(tester);
    return boundary;
  }

  Future<void> capture(WidgetTester tester, GlobalKey key, String name) async {
    if (!_capture) return;
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final out = Directory('../../.codex-temp/task_agent/previews')
        ..createSync(recursive: true);
      await File(
        '${out.path}/$name.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  for (final width in [360.0, 1040.0]) {
    testWidgets('task list, switch, detail with process at $width', (
      tester,
    ) async {
      final key = await mount(tester, width, const TaskListPage());
      expect(find.text('允许后台办事'), findsOneWidget);
      expect(find.text('查一下杭州明天的天气，顺便看要不要带伞'), findsOneWidget);
      expect(find.text('等你回答 · 已冻结'), findsOneWidget);
      expect(find.text('排队中 · 已冻结'), findsOneWidget);
      await capture(tester, key, 'list-${width.toInt()}');

      await tester.tap(find.text('查一下杭州明天的天气，顺便看要不要带伞'));
      await settle(tester);
      expect(find.text('完整过程'), findsOneWidget);
      expect(find.textContaining('web_search'), findsOneWidget);
      expect(find.byKey(const ValueKey('task-cancel')), findsNothing);
      await capture(tester, key, 'detail-${width.toInt()}');
    });
  }

  /// A receipt synced from another device: only the chat message exists.
  Future<void> syncedReceipt(
    String receiptId,
    TaskReceiptStatus status,
    int createdAt, {
    String summary = '',
    String? question,
  }) async {
    final messageId = taskReceiptMessageId(receiptId);
    final block = TaskReceiptBlock(
      messageId: messageId,
      receiptId: receiptId,
      taskId: 'remote',
      receiptStatus: status,
      summary: summary,
      question: question,
      executorDevice: 'phone',
    );
    await database
        .into(database.messages)
        .insert(
          MessageConverter.toCompanion(
            Message(
              id: messageId,
              role: 'user',
              content: block.content,
              createdAt: DateTime.fromMillisecondsSinceEpoch(createdAt),
            ),
            'c1',
          ),
        );
    await database
        .into(database.messageBlocks)
        .insert(MessageBlockConverter.toCompanion(block, messageId, 0));
  }

  for (final width in [360.0, 1040.0]) {
    testWidgets('a remote task waiting on its receipt shows the executor '
        'offline at $width', (tester) async {
      await tester.runAsync(() async {
        await seed();
        await syncedReceipt(
          'remote_q',
          TaskReceiptStatus.needsInput,
          10,
          summary: '找到两家店，都在营业。',
          question: '要订哪一家？',
        );
      });
      final key = await mount(
        tester,
        width,
        const TaskDetailPage(taskId: 'remote'),
      );
      expect(find.text('这个任务在另一台设备上执行，这里只有回执。'), findsOneWidget);
      expect(find.textContaining('执行设备离线或未同步'), findsOneWidget);
      expect(find.text('回执 · 需要你回答'), findsOneWidget);
      await capture(tester, key, 'remote-offline-${width.toInt()}');
    });
  }

  testWidgets('a later terminal receipt clears the offline notice', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await seed();
      await syncedReceipt('remote_q', TaskReceiptStatus.needsInput, 10);
      await syncedReceipt(
        'remote_done',
        TaskReceiptStatus.done,
        20,
        summary: '已订好。',
      );
    });
    await mount(tester, 360, const TaskDetailPage(taskId: 'remote'));
    expect(find.textContaining('执行设备离线或未同步'), findsNothing);
    expect(find.text('回执 · 已完成'), findsOneWidget);
  });

  testWidgets('a frozen task can be resumed; a waiting one cancelled', (
    tester,
  ) async {
    await mount(tester, 1040, const TaskListPage());
    await tester.tap(find.text('把读书笔记按作者整理成目录'));
    await settle(tester);
    expect(find.byKey(const ValueKey('task-resume')), findsOneWidget);

    await tester.tap(find.text('帮我比较一下西湖附近的三家酒店'));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('task-cancel')));
    await settle(tester);
    final hotel = await tester.runAsync(() => store.get('hotel'));
    expect(hotel!.status, AgentTaskStatus.cancelled);
  });

  testWidgets('the receipt bubble shows status, summary and question', (
    tester,
  ) async {
    final question = TaskReceiptBlock(
      messageId: 'm',
      receiptId: 'hotel_1',
      taskId: 'hotel',
      receiptStatus: TaskReceiptStatus.needsInput,
      summary: '找到 8 家，需要确认预算。',
      question: '每晚预算大概多少？',
      executorDevice: 'mac',
    );
    final key = await mount(
      tester,
      360,
      Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final receipt in [doneReceipt, question])
                Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: moePrimary,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: TaskReceiptBubble(
                    receipt: receipt,
                    textColor: Colors.white,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    expect(find.text('后台任务 · 已完成'), findsOneWidget);
    expect(find.text('问：每晚预算大概多少？'), findsOneWidget);
    await capture(tester, key, 'receipt-360');
    await tester.tap(find.text('后台任务 · 已完成'));
    await settle(tester);
    expect(find.text('任务详情'), findsOneWidget);
  });
}
