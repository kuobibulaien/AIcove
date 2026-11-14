import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/models/block_status.dart';
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/chat/domain/chat_timeline_deletion.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_history_store.dart';
import 'package:aicove_flutter/src/features/chat/services/conversation_short_window_store.dart';
import 'package:aicove_flutter/src/features/content_tags/domain/tag_presentation.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/voice_call/application/active_voice_call.dart';
import 'package:aicove_flutter/src/features/voice_call/application/voice_call_session.dart';
import 'package:aicove_flutter/src/features/voice_call/providers/voice_call_providers.dart';
import 'package:aicove_flutter/src/ui/features/chat/pages/chat_page.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_message_list.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_message_list_items.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_reply_action_bar.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_run_status_line.dart';
import 'package:aicove_flutter/src/ui/features/voice_call/widgets/voice_call_live_messages.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
import 'package:aicove_flutter/src/ui/theme/skin_provider.dart';
import 'package:aicove_flutter/src/ui/theme/skins/moetalk_skin.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../tool/chat_segmented_fixture.dart';

const TagPresentationMap _testTagMap = {
  'think': TagPresentationEntry(TagPresentation.fold, '思考'),
  'status': TagPresentationEntry(TagPresentation.fold, '状态栏'),
};

class _PreviewActiveVoiceCallNotifier extends ActiveVoiceCallNotifier {
  _PreviewActiveVoiceCallNotifier(this._call);

  final ActiveVoiceCall? _call;

  @override
  ActiveVoiceCall? build() => _call;
}

class _FakeActiveVoiceCall extends ChangeNotifier implements ActiveVoiceCall {
  _FakeActiveVoiceCall({
    required this.conversationId,
    required this.startedAt,
    required this.transcript,
  });

  @override
  final String conversationId;

  @override
  final DateTime startedAt;

  @override
  final List<CallTurn> transcript;

  @override
  final ValueNotifier<Duration> elapsed = ValueNotifier(Duration.zero);

  @override
  VoiceCallPhase get phase => VoiceCallPhase.listening;

  @override
  String? get error => null;

  @override
  String get partial => '';

  @override
  bool get muted => false;

  @override
  bool get speakerOff => false;

  @override
  bool get minimized => true;

  @override
  bool get inWindow => true;

  @override
  bool get ending => false;

  @override
  bool get connected => true;

  @override
  bool get outgoing => true;

  final Set<int> _hidden = <int>{};

  @override
  bool isTurnHidden(int index) => _hidden.contains(index);

  @override
  void hideTurn(int index) {
    _hidden.add(index);
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _seedRawMessages(
  SegmentedChatFixture fixture,
  List<Message> rawMessages,
) async {
  for (final raw in rawMessages) {
    await fixture.database
        .into(fixture.database.messages)
        .insert(
          db.MessagesCompanion.insert(
            id: raw.id,
            conversationId: fixture.conversation.id,
            role: raw.role,
            content: raw.content,
            createdAt: raw.createdAt.millisecondsSinceEpoch,
          ),
        );
  }
}

Future<SegmentedChatFixture> _createSeededFixture(
  WidgetTester tester, {
  AppSettings settings = segmentedProbeSettings,
  required List<Message> rawMessages,
  required List<Message> timelineMessages,
  Conversation Function(Conversation conversation)? decorate,
  List<Override> extraOverrides = const [],
}) async {
  final fixture = (await tester.runAsync(() async {
    final created = await SegmentedChatFixture.create(
      settings: settings,
      historyMessages: const <Message>[],
      decorate: decorate,
      extraOverrides: extraOverrides,
    );
    await _seedRawMessages(created, rawMessages);
    await created.container
        .read(conversationTimelineCacheProvider)
        .upsertMessages(
          conversationId: created.conversation.id,
          messages: timelineMessages,
        );
    return created;
  }))!;
  return fixture;
}

Future<void> _rightClick(WidgetTester tester, Offset position) async {
  final gesture = await tester.createGesture(
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryMouseButton,
  );
  await gesture.addPointer(location: position);
  await gesture.down(position);
  await gesture.up();
  await gesture.removePointer();
  await tester.pumpAndSettle();
}

Future<void> _pumpAsyncEffects(
  WidgetTester tester, {
  int cycles = 16,
  bool drainToast = true,
}) async {
  for (var i = 0; i < cycles; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  if (drainToast) {
    await tester.pump(const Duration(seconds: 3));
  }
}

Future<T> _awaitWithPump<T>(
  WidgetTester tester,
  Future<T> Function() action,
) async {
  var completed = false;
  late T result;
  Object? caughtError;
  StackTrace? caughtStack;
  final future = action().then(
    (value) {
      result = value;
      completed = true;
    },
    onError: (Object error, StackTrace stack) {
      caughtError = error;
      caughtStack = stack;
      completed = true;
    },
  );
  for (var i = 0; i < 120 && !completed; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  expect(completed, isTrue, reason: '异步操作未在预期帧内完成');
  await future;
  if (caughtError != null) {
    Error.throwWithStackTrace(caughtError!, caughtStack!);
  }
  return result;
}

Future<void> _disposeFixture(
  WidgetTester tester,
  SegmentedChatFixture fixture,
) async {
  await tester.pump(const Duration(seconds: 3));
  await tester.pumpWidget(const SizedBox.shrink());
  var disposed = false;
  final cleanup = fixture.dispose().then((_) => disposed = true);
  for (var i = 0; i < 100 && !disposed; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  expect(disposed, isTrue);
  await cleanup;
}

Future<void> _pumpChatPage(
  WidgetTester tester,
  SegmentedChatFixture fixture, {
  required double width,
  double height = 780,
  double pixelRatio = 1,
  String? fontFamily,
  Key? boundaryKey,
  bool settle = true,
}) async {
  tester.view.devicePixelRatio = pixelRatio;
  tester.view.physicalSize = Size(width * pixelRatio, height * pixelRatio);
  addTearDown(tester.view.reset);

  final navigator = GlobalKey<NavigatorState>();
  Widget app = SkinScope(
    skin: const MoeTalkSkin(),
    child: MaterialApp(
      navigatorKey: navigator,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        platform: TargetPlatform.iOS,
        fontFamily: fontFamily,
        extensions: [MoeColors.light()],
      ),
      home: MoeWorkspace(
        navigatorKey: navigator,
        isWide: width > 600,
        isDetail: true,
        child: ChatPage(
          conversationId: fixture.conversation.id,
          initialConversation: fixture.conversation,
        ),
      ),
    ),
  );
  if (boundaryKey != null) {
    app = RepaintBoundary(key: boundaryKey, child: app);
  }
  await tester.pumpWidget(
    UncontrolledProviderScope(container: fixture.container, child: app),
  );
  await _pumpAsyncEffects(tester, cycles: 10, drainToast: false);
  if (settle) {
    await tester.pumpAndSettle();
  }
}

Future<void> _loadPreviewFonts() async {
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  final materialFontCandidates = <String>[
    if (flutterRoot != null && flutterRoot.isNotEmpty)
      '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    '${Platform.environment['HOME']}/dev-sdks/flutter-3.44.6/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  ];
  final materialFontPath = materialFontCandidates.firstWhere(
    (path) => File(path).existsSync(),
  );
  for (final entry in <String, String>{
    'Preview': '/System/Library/Fonts/STHeiti Medium.ttc',
    'Menlo': '/System/Library/Fonts/Menlo.ttc',
    'MaterialIcons': materialFontPath,
  }.entries) {
    final loader = FontLoader(entry.key)
      ..addFont(File(entry.value).readAsBytes().then(ByteData.sublistView));
    await loader.load();
  }
}

void main() {
  const writePreview = bool.fromEnvironment('WRITE_CHAT_DELETE_PREVIEW');

  group('Piece ID 稳定性与删除计划解析纯函数', () {
    test('开关思维链与工具调用折叠时，标签折叠与正文段 pieceId 保持稳定不漂移', () {
      final msg = Message.fromBlocks(
        id: 'a1',
        sourceMessageId: 'raw_a1',
        role: 'assistant',
        createdAt: DateTime(2026, 11, 14, 10),
        blocks: [
          ThinkingBlock(
            id: 'th_0',
            messageId: 'a1',
            title: '模型思考',
            content: '先想一下回答结构。',
          ),
          ToolBlock(
            id: 'tool_0',
            messageId: 'a1',
            toolCallId: 'call_0',
            toolName: 'web_search',
            arguments: const {'q': '天气'},
            result: const {'content': '晴天 22°C'},
          ),
          TextBlock(
            id: 'txt_0',
            messageId: 'a1',
            content: '<think>组织语气</think>\n<status>心情：愉快</status>\n第一句正文。第二句正文。',
          ),
        ],
      );
      const chunkConfig = MessageFormatConfig(
        enableChunking: true,
        chunkPunctuations: ['。'],
      );

      final full = buildChatMessageListItems(
        messages: [msg],
        config: chunkConfig,
        tagPresentation: _testTagMap,
        showThinkingFolds: true,
        showToolCallFolds: true,
      ).whereType<ChatChunkedMessageItem>().toList();

      expect(full.map((e) => e.pieceId).toList(), [
        'a1__piece_fold_thinking_0',
        'a1__piece_fold_tool_0',
        'a1__piece_fold_tag_0',
        'a1__piece_fold_tag_1',
        'a1__piece_body_0',
        'a1__piece_body_1',
      ]);

      final noThinkingNoTool = buildChatMessageListItems(
        messages: [msg],
        config: chunkConfig,
        tagPresentation: _testTagMap,
        showThinkingFolds: false,
        showToolCallFolds: false,
      ).whereType<ChatChunkedMessageItem>().toList();

      expect(noThinkingNoTool.map((e) => e.pieceId).toList(), [
        'a1__piece_fold_tag_1',
        'a1__piece_body_0',
        'a1__piece_body_1',
      ]);
    });

    test('所有切分块被隐藏时不画空气泡，尾部运行状态转为 standalone', () {
      final msg = Message.text(
        id: 'a_cut',
        role: 'assistant',
        content: '第一句。第二句。',
        createdAt: DateTime(2026, 11, 14, 10),
        rawPayload: const {'runStatus': 'truncated'},
      );
      const chunkConfig = MessageFormatConfig(
        enableChunking: true,
        chunkPunctuations: ['。'],
      );

      final items = buildChatMessageListItems(
        messages: [msg],
        config: chunkConfig,
        hiddenPieceIds: const {
          'a_cut__piece_body_0',
          'a_cut__piece_body_1',
        },
        showReplyActions: true,
      );

      expect(items.whereType<ChatChunkedMessageItem>(), isEmpty);
      expect(items.whereType<ChatTimeDividerItem>(), isEmpty);
      final status = items.whereType<ChatRunStatusItem>().single;
      expect(status.standalone, isTrue);
      expect(chatListItemSelectionMessage(status)?.content, '[回复达到长度上限，被截断了]');
      expect(items.whereType<ChatReplyActionsItem>(), hasLength(1));
    });
  });

  testWidgets('气泡模式分段气泡：单删 piece 局部隐藏、多选删除分段、删完最后正文自动升级真删 Raw，混选弹窗文案准确', (
    tester,
  ) async {
    final now = DateTime(2026, 11, 14, 12, 0);
    final user1 = Message.text(
      id: 'u1',
      role: 'user',
      content: '给我讲三句晚安故事',
      createdAt: now,
    );
    final user2 = Message.text(
      id: 'u2',
      role: 'user',
      content: '再来两句带思考的回复',
      createdAt: now.add(const Duration(minutes: 1)),
    );
    final reply1 = Message.text(
      id: 'a1',
      sourceMessageId: 'a1',
      role: 'assistant',
      content: '月亮升起来了。星星眨着眼睛。晚风轻轻吹过窗台。',
      createdAt: now.add(const Duration(seconds: 10)),
    );
    final reply2 = Message.text(
      id: 'a2',
      sourceMessageId: 'a2',
      role: 'assistant',
      content: '<think>温柔简短一点</think>\n早点休息吧。祝你好梦。',
      createdAt: now.add(const Duration(minutes: 1, seconds: 10)),
    );

    final fixture = await _createSeededFixture(
      tester,
      rawMessages: [user1, reply1, user2, reply2],
      timelineMessages: [user1, reply1, user2, reply2],
    );
    final store = fixture.container.read(chatHistoryStoreProvider);

    await _pumpChatPage(tester, fixture, width: 400);

    expect(find.text('月亮升起来了。'), findsOneWidget);
    expect(find.text('星星眨着眼睛。'), findsOneWidget);
    expect(find.text('晚风轻轻吹过窗台。'), findsOneWidget);

    // 1. 单删第 1 段：只局部隐藏该 piece，其余分段和数据库 Raw 保留。
    await tester.longPress(find.text('月亮升起来了。'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.text('移除内容'), findsOneWidget);
    expect(
      find.text('确定从当前界面移除这块内容吗？同条消息的其余部分和 AI 记忆会保留。'),
      findsOneWidget,
    );
    await tester.tap(find.text('移除'));
    await _pumpAsyncEffects(tester);
    await tester.pumpAndSettle();

    expect(find.text('月亮升起来了。'), findsNothing);
    expect(find.text('星星眨着眼睛。'), findsOneWidget);
    expect(find.text('晚风轻轻吹过窗台。'), findsOneWidget);
    final rawAfterPieceHide = await _awaitWithPump(
      tester,
      () => store.loadAllRawMessages(fixture.conversation.id),
    );
    expect(rawAfterPieceHide.map((m) => m.id), contains('a1'));

    // 2. 多选仅勾选第 2 段：展示局部隐藏文案并成功隐藏该段。
    await tester.longPress(find.text('星星眨着眼睛。'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('多选'));
    await tester.pumpAndSettle();
    expect(find.text('已选 1 条消息'), findsOneWidget);
    await tester.tap(find.widgetWithIcon(IconButton, Icons.delete_outline));
    await tester.pumpAndSettle();
    expect(
      find.text('移除选中的 1 项内容？仅从当前界面隐藏，其余部分和 AI 记忆会保留。'),
      findsOneWidget,
    );
    await tester.tap(find.text('确定'));
    await _pumpAsyncEffects(tester);
    await tester.pumpAndSettle();

    expect(find.text('星星眨着眼睛。'), findsNothing);
    expect(find.text('晚风轻轻吹过窗台。'), findsOneWidget);

    // 3. 删完 a1 最后一段正文：自动升级真删 Raw！
    await tester.longPress(find.text('晚风轻轻吹过窗台。'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.text('删除消息'), findsOneWidget);
    expect(find.text('确定删除这条消息吗？删除后 AI 也会忘记这段内容。'), findsOneWidget);
    await tester.tap(find.text('删除').last);
    await _pumpAsyncEffects(tester);
    await tester.pumpAndSettle();

    expect(find.text('晚风轻轻吹过窗台。'), findsNothing);
    final rawAfterLastBodyDelete = await _awaitWithPump(
      tester,
      () => store.loadAllRawMessages(fixture.conversation.id),
    );
    expect(rawAfterLastBodyDelete.map((m) => m.id), isNot(contains('a1')));

    // 4. 混选整条用户消息 u1 + a2 的其中一段正文：展示混合确认文案。
    await tester.longPress(find.text('给我讲三句晚安故事'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('多选'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('早点休息吧。'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.text('已选 2 条消息'), findsOneWidget);
    await tester.tap(find.widgetWithIcon(IconButton, Icons.delete_outline));
    await tester.pumpAndSettle();
    expect(
      find.text('删除选中的 2 项内容？整条删完的消息 AI 也会忘记，只移除其中一部分的会保留其余内容。'),
      findsOneWidget,
    );
    await tester.tap(find.text('确定'));
    await _pumpAsyncEffects(tester);
    await tester.pumpAndSettle();

    expect(find.text('给我讲三句晚安故事'), findsNothing);
    expect(find.text('早点休息吧。'), findsNothing);
    expect(find.text('祝你好梦。'), findsOneWidget);

    // 5. a2 还剩思考折叠块 + 最后一段正文「祝你好梦。」，删除最后一段正文后连同思考壳整条真删！
    await tester.longPress(find.text('祝你好梦。'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.text('确定删除这条消息吗？删除后 AI 也会忘记这段内容。'), findsOneWidget);
    await tester.tap(find.text('删除').last);
    await _pumpAsyncEffects(tester);
    await tester.pumpAndSettle();

    expect(find.text('祝你好梦。'), findsNothing);
    expect(find.byType(MoeCollapsibleBubble), findsNothing);
    final rawFinal = await _awaitWithPump(
      tester,
      () => store.loadAllRawMessages(fixture.conversation.id),
    );
    expect(rawFinal.map((m) => m.id), ['u2']);

    await _disposeFixture(tester, fixture);
  });

  testWidgets('文档模式：宽屏 1000px 多选框贴齐 760 阅读栏左缘、连续折叠段不挤压，底部操作栏整轮真删', (
    tester,
  ) async {
    final now = DateTime(2026, 11, 14, 14, 0);
    final userMsg = Message.text(
      id: 'u1',
      role: 'user',
      content: '帮我查一下目录并整理说明',
      createdAt: now,
    );
    final toolProj1 = Message.fromBlocks(
      id: 'raw_turn__proj_0',
      sourceMessageId: 'raw_turn',
      role: 'assistant',
      createdAt: now.add(const Duration(seconds: 5)),
      blocks: [
        ToolBlock(
          id: 'tb_1',
          messageId: 'raw_turn__proj_0',
          toolCallId: 'call_1',
          toolName: 'bash',
          arguments: const {'command': 'ls -la'},
          result: const {'content': 'README.md\nsrc/'},
        ),
      ],
    );
    final replyProj2 = Message.fromBlocks(
      id: 'raw_turn__proj_1',
      sourceMessageId: 'raw_turn',
      role: 'assistant',
      createdAt: now.add(const Duration(seconds: 8)),
      rawPayload: const {'runStatus': 'truncated'},
      blocks: [
        ThinkingBlock(
          id: 'th_1',
          messageId: 'raw_turn__proj_1',
          title: '思考',
          content: '先确认目录结构，再给出简明说明。',
        ),
        TextBlock(
          id: 'txt_1',
          messageId: 'raw_turn__proj_1',
          content: '<think>进度：已完成扫描</think>\n目录里包含说明文档与源码目录。',
        ),
      ],
    );

    final docSettings = segmentedProbeSettings.copyWith(
      chatDisplayStyle: ChatDisplayStyle.document,
      documentShowThinking: true,
      documentShowToolCalls: true,
    );
    final fixture = await _createSeededFixture(
      tester,
      settings: docSettings,
      rawMessages: [
        userMsg,
        Message.text(
          id: 'raw_turn',
          role: 'assistant',
          content: '目录里包含说明文档与源码目录。',
          createdAt: now.add(const Duration(seconds: 8)),
        ),
      ],
      timelineMessages: [userMsg, toolProj1, replyProj2],
      decorate: (c) => c.copyWith(chatDisplayStyle: ChatDisplayStyle.document),
    );
    final store = fixture.container.read(chatHistoryStoreProvider);

    await _pumpChatPage(tester, fixture, width: 1000);

    // 验证连续折叠段与运行状态行、底部操作栏均已渲染
    expect(find.byType(MoeFoldSection), findsNWidgets(3));
    expect(find.byType(ChatRunStatusLine), findsOneWidget);
    expect(find.byType(ChatReplyActionBar), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(ChatReplyActionBar),
        matching: find.byIcon(Icons.delete_outline_rounded),
      ),
      findsOneWidget,
    );

    // 进入多选模式：检查宽屏 1000px 下复选框紧贴居中 760px 阅读栏左缘（> 80px），且连续折叠行不挤压
    final list = tester.widget<ChatMessageList>(find.byType(ChatMessageList));
    const firstFoldCheckboxId =
        'raw_turn__proj_0${ChatTimelinePieceId.separator}fold_tool_0';
    list.selection!.start(firstFoldCheckboxId);
    await tester.pumpAndSettle();

    final checkboxes = tester
        .widgetList<MoeCheckbox>(find.byType(MoeCheckbox))
        .toList();
    expect(checkboxes.length, greaterThanOrEqualTo(4));

    final checkboxRects = find
        .byType(MoeCheckbox)
        .evaluate()
        .map((e) => (e.renderObject! as RenderBox).localToGlobal(Offset.zero) & e.size!)
        .toList()
      ..sort((a, b) => a.top.compareTo(b.top));

    for (final rect in checkboxRects) {
      expect(
        rect.left,
        greaterThan(80.0),
        reason: '宽屏 1000px 下复选框应紧贴居中 760px 阅读栏左缘而非视口最左端',
      );
    }
    for (var i = 1; i < checkboxRects.length; i++) {
      expect(
        checkboxRects[i].top - checkboxRects[i - 1].top,
        greaterThanOrEqualTo(38.0),
        reason: '连续折叠段与相邻行的复选框不应重叠挤压',
      );
    }

    list.selection!.clear();
    await tester.pumpAndSettle();

    // 点击底部操作栏的「删除」按钮：整轮真删（工具、思考、状态栏、正文、状态行全消失）
    await tester.tap(
      find.descendant(
        of: find.byType(ChatReplyActionBar),
        matching: find.byIcon(Icons.delete_outline_rounded),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('删除回复'), findsOneWidget);
    expect(find.text('确定删除这轮回复吗？删除后 AI 也会忘记这段内容。'), findsOneWidget);
    await tester.tap(find.text('删除').last);
    await _pumpAsyncEffects(tester);
    await tester.pumpAndSettle();

    expect(find.byType(MoeFoldSection), findsNothing);
    expect(find.byType(ChatRunStatusLine), findsNothing);
    expect(find.text('目录里包含说明文档与源码目录。'), findsNothing);
    final remainingRaw = await _awaitWithPump(
      tester,
      () => store.loadAllRawMessages(fixture.conversation.id),
    );
    expect(remainingRaw.map((m) => m.id), ['u1']);

    await _disposeFixture(tester, fixture);
  });

  testWidgets('折叠块手势与右键菜单：桌面右键弹精简菜单、左键空白区不误触展开、合并纯工具块一次删净不残留', (
    tester,
  ) async {
    String? copiedText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copiedText = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    final now = DateTime(2026, 11, 14, 15, 0);
    final tool1 = Message.fromBlocks(
      id: 'raw_m__proj_0',
      sourceMessageId: 'raw_m',
      role: 'assistant',
      createdAt: now,
      blocks: [
        ToolBlock(
          id: 't1',
          messageId: 'raw_m__proj_0',
          toolCallId: 'c1',
          toolName: 'bash',
          arguments: const {'command': 'pwd'},
          result: const {'content': '/workspace'},
        ),
      ],
    );
    final tool2 = Message.fromBlocks(
      id: 'raw_m__proj_1',
      sourceMessageId: 'raw_m',
      role: 'assistant',
      createdAt: now.add(const Duration(seconds: 1)),
      blocks: [
        ToolBlock(
          id: 't2',
          messageId: 'raw_m__proj_1',
          toolCallId: 'c2',
          toolName: 'read',
          arguments: const {'path': 'pubspec.yaml'},
          result: const {'content': 'name: aicove'},
        ),
      ],
    );
    final replyBody = Message.text(
      id: 'raw_m__proj_2',
      sourceMessageId: 'raw_m',
      role: 'assistant',
      content: '<think>核对完毕，准备回复</think>\n配置一切正常。',
      createdAt: now.add(const Duration(seconds: 2)),
    );

    final docSettings = segmentedProbeSettings.copyWith(
      chatDisplayStyle: ChatDisplayStyle.document,
      documentShowThinking: true,
      documentShowToolCalls: true,
    );
    final fixture = (await tester.runAsync(() async {
      final created = await SegmentedChatFixture.create(
        settings: docSettings,
        historyMessages: const <Message>[],
        decorate: (c) => c.copyWith(chatDisplayStyle: ChatDisplayStyle.document),
      );
      await created.container
          .read(chatHistoryStoreProvider)
          .appendAssistantRawMessage(
            conversationId: created.conversation.id,
            userMessageId: '',
            rawMessage: Message.fromBlocks(
              id: 'raw_m',
              role: 'assistant',
              createdAt: now.add(const Duration(seconds: 2)),
              blocks: [
                ...tool1.blocks!,
                ...tool2.blocks!,
                TextBlock(
                  id: 'txt_m',
                  messageId: 'raw_m',
                  content: '<think>核对完毕，准备回复</think>\n配置一切正常。',
                ),
              ],
            ),
            projectedMessages: [tool1, tool2, replyBody],
            lastMessagePreview: '配置一切正常。',
          );
      return created;
    }))!;

    await _pumpChatPage(tester, fixture, width: 1000);

    // 连续 2 条 _isToolOnly 合并为 1 个工具折叠段 + 1 个思考折叠段
    expect(find.byType(MoeFoldSection), findsNWidgets(2));
    expect(find.text('bash、read · 2 次'), findsOneWidget);
    expect(find.text('思考'), findsOneWidget);

    // 左键点击阅读栏右侧空白处：不误触展开；左键点标题才展开，且展开内容包裹 SelectionArea
    final thinkRect = tester.getRect(find.text('思考'));
    await tester.tapAt(Offset(thinkRect.right + 220, thinkRect.center.dy));
    await tester.pumpAndSettle();
    expect(find.text('核对完毕，准备回复'), findsNothing);

    await tester.tap(find.text('思考'));
    await tester.pumpAndSettle();
    expect(find.text('核对完毕，准备回复'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(MoeFoldSection).last,
        matching: find.byType(SelectionArea),
      ),
      findsOneWidget,
    );

    // 桌面鼠标右键点击思考折叠块：仅展示「多选 / 复制 / 删除」，复制内容为折叠正文
    await _rightClick(tester, tester.getCenter(find.text('思考')));
    expect(find.text('多选'), findsOneWidget);
    expect(find.text('复制'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
    expect(find.text('引用'), findsNothing);
    expect(find.text('重新生成'), findsNothing);
    await tester.tap(find.text('复制'));
    await tester.pumpAndSettle();
    expect(copiedText, '核对完毕，准备回复');

    // 单删思考折叠块：保留正文「配置一切正常。」不误杀
    await _rightClick(tester, tester.getCenter(find.text('思考')));
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.text('移除内容'), findsOneWidget);
    await tester.tap(find.text('移除'));
    await _pumpAsyncEffects(tester);
    await tester.pumpAndSettle();
    expect(find.text('思考'), findsNothing);
    expect(find.text('配置一切正常。'), findsOneWidget);

    // 右键删除合并工具折叠块：一次将 tool1 + tool2 全部隐藏，绝不弹出第 2 条残留工具块
    await _rightClick(tester, tester.getCenter(find.text('bash、read · 2 次')));
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移除'));
    await _pumpAsyncEffects(tester);
    await tester.pumpAndSettle();
    expect(find.byType(MoeFoldSection), findsNothing);
    expect(find.text('配置一切正常。'), findsOneWidget);

    await _disposeFixture(tester, fixture);

    // 气泡模式下 MoeCollapsibleBubble 同样支持桌面右键弹菜单
    final bubbleReply = Message.text(
      id: 'b_fold',
      sourceMessageId: 'b_fold',
      role: 'assistant',
      content: '<think>体力：95</think>\n准备出发！',
      createdAt: now,
    );
    final bubbleFixture = await _createSeededFixture(
      tester,
      rawMessages: [bubbleReply],
      timelineMessages: [bubbleReply],
    );
    await _pumpChatPage(tester, bubbleFixture, width: 400);

    expect(find.byType(MoeCollapsibleBubble), findsOneWidget);
    await _rightClick(
      tester,
      tester.getCenter(find.byType(MoeCollapsibleBubble)),
    );
    expect(find.text('多选'), findsOneWidget);
    expect(find.text('复制'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
    expect(find.text('重新生成'), findsNothing);
    await tester.tap(find.text('复制'));
    await tester.pumpAndSettle();
    expect(copiedText, '体力：95');

    await _disposeFixture(tester, bubbleFixture);
  });

  testWidgets('钉子户打通：无正文状态行可右键/多选删除、已完成消息的 pending 图片占位框可删、通话实时临时气泡无复选框', (
    tester,
  ) async {
    final now = DateTime(2026, 11, 14, 16, 0);
    final userMsg = Message.text(
      id: 'u1',
      role: 'user',
      content: '画一张海边日落',
      createdAt: now,
    );
    final textSibling = Message.text(
      id: 'raw_img__proj_text',
      sourceMessageId: 'raw_img',
      role: 'assistant',
      content: '这就给你画好啦。',
      createdAt: now.add(const Duration(seconds: 3)),
    );
    final stuckPendingImg = Message.fromBlocks(
      id: 'raw_img__proj_img',
      sourceMessageId: 'raw_img',
      role: 'assistant',
      status: 'sent',
      createdAt: now.add(const Duration(seconds: 4)),
      blocks: [
        ImageBlock(
          id: 'img_pending_0',
          messageId: 'raw_img__proj_img',
          prompt: 'sunset beach',
          width: 240,
          height: 180,
          status: BlockStatus.pending,
        ),
      ],
    );
    final stoppedEmpty = Message(
      id: 'raw_stopped',
      sourceMessageId: 'raw_stopped',
      role: 'assistant',
      content: '',
      status: 'sent',
      createdAt: now.add(const Duration(seconds: 10)),
      rawPayload: const {'runStatus': 'cancelled'},
    );

    late _FakeActiveVoiceCall fakeCall;
    final docSettings = segmentedProbeSettings.copyWith(
      chatDisplayStyle: ChatDisplayStyle.document,
    );
    final fixture = await _createSeededFixture(
      tester,
      settings: docSettings,
      rawMessages: [
        userMsg,
        Message.text(
          id: 'raw_img',
          role: 'assistant',
          content: '这就给你画好啦。',
          createdAt: now.add(const Duration(seconds: 4)),
        ),
        stoppedEmpty,
      ],
      timelineMessages: [userMsg, textSibling, stuckPendingImg, stoppedEmpty],
      decorate: (c) => c.copyWith(chatDisplayStyle: ChatDisplayStyle.document),
      extraOverrides: [
        activeVoiceCallProvider.overrideWith(() {
          fakeCall = _FakeActiveVoiceCall(
            conversationId: 'offline_segmented_probe',
            startedAt: now.add(const Duration(minutes: 2)),
            transcript: const [
              CallTurn(role: 'assistant', text: '喂，听得到我说话吗？'),
            ],
          );
          return _PreviewActiveVoiceCallNotifier(fakeCall);
        }),
      ],
    );

    await _pumpChatPage(tester, fixture, width: 800, settle: false);
    // CircularProgressIndicator 为无限动画，后续用 pump 推进帧
    expect(find.text('已停止'), findsOneWidget);
    expect(find.text('喂，听得到我说话吗？'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    // 1. 已完成消息中的 pending 图片占位框支持右键弹菜单（无保存/引用，有多选/删除），且可局部移除
    final pendingClip = find.ancestor(
      of: find.byType(CircularProgressIndicator),
      matching: find.byType(ClipPath),
    );
    final pendingCenter = tester.getCenter(
      pendingClip.evaluate().isNotEmpty
          ? pendingClip.first
          : find.byType(CircularProgressIndicator),
    );
    final mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await mouse.addPointer(location: pendingCenter);
    await mouse.down(pendingCenter);
    await mouse.up();
    await mouse.removePointer();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('多选'), findsOneWidget);
    expect(find.text('删除'), findsWidgets);
    expect(find.text('保存'), findsNothing);
    expect(find.text('引用'), findsNothing);

    await tester.tap(find.text('删除').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('移除内容'), findsOneWidget);
    await tester.tap(find.text('移除'));
    await _pumpAsyncEffects(tester);
    await tester.pumpAndSettle();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('这就给你画好啦。'), findsOneWidget);

    // 2. 无正文 standalone ChatRunStatusItem 支持右键打开「多选 / 重新生成 / 删除」并可进入多选勾选删除；
    //    同时通话实时临时气泡（voice_call_live_*）不生成复选框！
    final liveMsg = voiceCallLiveMessages(fakeCall).single;
    expect(liveMsg.id, startsWith(voiceCallLiveMessagePrefix));
    expect(chatListItemSelectionMessage(ChatMessageItem(liveMsg)), isNull);

    await _rightClick(tester, tester.getCenter(find.text('已停止')));
    expect(find.text('多选'), findsOneWidget);
    expect(find.text('重新生成'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
    expect(find.text('复制'), findsNothing);
    expect(find.text('引用'), findsNothing);

    await tester.tap(find.text('多选'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('message-select-raw_stopped')),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey('message-select-${liveMsg.id}')),
      findsNothing,
      reason: '通话实时临时气泡禁止在多选模式出现勾选框',
    );

    await tester.tap(find.widgetWithIcon(IconButton, Icons.delete_outline));
    await tester.pumpAndSettle();
    expect(find.text('删除选中的 1 条消息？删除后 AI 也会忘记这些内容。'), findsOneWidget);
    await tester.tap(find.text('确定'));
    await _pumpAsyncEffects(tester);
    await tester.pumpAndSettle();

    expect(find.text('已停止'), findsNothing);

    await _disposeFixture(tester, fixture);
  });

  testWidgets('导出聊天删除改造源码渲染预览图（360 窄屏操作栏 / 1000 宽屏多选 / 1000 折叠右键菜单）', (
    tester,
  ) async {
    if (!writePreview) return;
    await tester.runAsync(_loadPreviewFonts);
    final outDir = Directory('../../scratch/chat-delete-preview')
      ..createSync(recursive: true);

    final now = DateTime.now().subtract(const Duration(minutes: 6));
    final userMsg = Message.text(
      id: 'u_prev',
      role: 'user',
      content: '帮我看看周末露营带什么装备合适？',
      createdAt: now,
    );
    final toolProj = Message.fromBlocks(
      id: 'raw_prev__proj_0',
      sourceMessageId: 'raw_prev',
      role: 'assistant',
      createdAt: now.add(const Duration(seconds: 4)),
      blocks: [
        ToolBlock(
          id: 'tb_prev',
          messageId: 'raw_prev__proj_0',
          toolCallId: 'call_prev',
          toolName: 'weather_lookup',
          arguments: const {'city': '杭州', 'days': 2},
          result: const {'content': '周六晴 15~24°C，夜间微风'},
        ),
      ],
    );
    final replyProj = Message.fromBlocks(
      id: 'raw_prev__proj_1',
      sourceMessageId: 'raw_prev',
      role: 'assistant',
      createdAt: now.add(const Duration(seconds: 8)),
      blocks: [
        ThinkingBlock(
          id: 'th_prev',
          messageId: 'raw_prev__proj_1',
          title: '模型思考',
          content: '昼夜温差接近 9°C，需要兼顾白天防晒和夜间保暖。',
        ),
        TextBlock(
          id: 'txt_prev',
          messageId: 'raw_prev__proj_1',
          content:
              '这周末天气很舒服，白天晴朗温暖，夜里稍微有一点凉意。\n\n'
              '- **过夜保暖**：薄羽绒或抓绒外套、温标 10°C 左右的睡袋\n'
              '- **营地实用**：天幕、折叠椅、头灯和驱蚊喷雾',
        ),
      ],
    );

    final docSettings = segmentedProbeSettings.copyWith(
      chatDisplayStyle: ChatDisplayStyle.document,
      documentShowThinking: true,
      documentShowToolCalls: true,
    );
    final fixture = await _createSeededFixture(
      tester,
      settings: docSettings,
      rawMessages: [
        userMsg,
        Message.text(
          id: 'raw_prev',
          role: 'assistant',
          content: '这周末天气很舒服',
          createdAt: now.add(const Duration(seconds: 8)),
        ),
      ],
      timelineMessages: [userMsg, toolProj, replyProj],
      decorate: (c) => Conversation(
        id: c.id,
        title: '林汐',
        displayName: '林汐',
        createdAt: c.createdAt,
        updatedAt: c.updatedAt,
        messages: c.messages,
        lastMessage: c.lastMessage,
        lastMessageTime: c.lastMessageTime,
        chatDisplayStyle: ChatDisplayStyle.document,
      ),
    );

    Future<void> savePng(GlobalKey key, String filename) async {
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('${outDir.path}/$filename').writeAsBytes(
          bytes!.buffer.asUint8List(),
        );
        image.dispose();
      });
    }

    // 1. 360px 窄屏文档模式（含思考折叠块、工具调用折叠块、正文、底部带复制/引用/重试/删除的操作栏）
    final key360 = GlobalKey();
    await _pumpChatPage(
      tester,
      fixture,
      width: 360,
      height: 680,
      pixelRatio: 2,
      fontFamily: 'Preview',
      boundaryKey: key360,
    );
    await savePng(key360, 'doc_mode_action_bar_360.png');

    // 2. 1000px 宽屏文档模式多选态
    final keyMulti1000 = GlobalKey();
    await _pumpChatPage(
      tester,
      fixture,
      width: 1000,
      height: 680,
      pixelRatio: 2,
      fontFamily: 'Preview',
      boundaryKey: keyMulti1000,
    );
    final list = tester.widget<ChatMessageList>(find.byType(ChatMessageList));
    list.selection!
      ..start('raw_prev__proj_0${ChatTimelinePieceId.separator}fold_tool_0')
      ..toggle('raw_prev__proj_1${ChatTimelinePieceId.separator}body_0');
    await tester.pumpAndSettle();
    await savePng(keyMulti1000, 'doc_mode_multiselect_1000.png');

    // 3. 1000px 宽屏文档模式折叠块右键弹出「多选 / 复制 / 删除」菜单态
    list.selection!.clear();
    await tester.pumpAndSettle();
    await _rightClick(tester, tester.getCenter(find.text('模型思考')));
    await savePng(keyMulti1000, 'fold_context_menu_1000.png');

    // 关闭弹出菜单再清理
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    await _disposeFixture(tester, fixture);
  });
}
