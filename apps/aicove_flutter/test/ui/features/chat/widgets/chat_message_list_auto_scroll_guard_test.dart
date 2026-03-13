import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/features/chat/conversation_timeline_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_message_list.dart';
import 'package:aicove_flutter/src/ui/theme/skin_provider.dart';
import 'package:aicove_flutter/src/ui/theme/skins/moetalk_skin.dart';

class _FakeAppSettingsNotifier extends AppSettingsNotifier {
  _FakeAppSettingsNotifier(this._settings);

  final AppSettings _settings;

  @override
  Future<AppSettings> build() async => _settings;
}

AppSettings _buildSettings() {
  return const AppSettings(
    ttsEnabled: true,
    defaultModelName: 'deepseek-chat',
    defaultPersonaPrompt: '',
    modelList: <String>['deepseek-chat'],
    allKnownModels: <String>['deepseek-chat'],
    modelDisplayNames: <String, String>{},
    modelTypes: <String, String>{},
    modelConfigs: <String, ModelConfig>{},
    apiKey: '',
    apiBaseUrl: 'https://api.openai.com/v1',
    imageGenerationEnabled: false,
    maxFileUploadMB: 10,
    historyMessageLimit: 100,
    customModels: <CustomModel>[],
    providers: <ProviderAuth>[],
    modelProviderMap: <String, String>{},
    backendApiKey: '',
    messageChunkingEnabled: false,
    messageFormatConfig: MessageFormatConfig(enableChunking: false),
    textScaleFactor: 1.0,
    uiScaleFactor: 1.0,
    imagePreviewScale: 1.0,
    autoReplySettings: AutoReplySettings(),
    globalBackgroundColor: GlobalBackgroundColor.white,
    chatBackgroundColor: ChatBackgroundColor.defaultColor,
    isDarkMode: false,
    useSystemTheme: true,
    accentColor: 'FC96AA',
    hideUserAvatar: false,
  );
}

List<Message> _buildInitialMessages(int count) {
  final baseTime = DateTime(2026, 1, 1, 12, 0, 0);
  return List<Message>.generate(count, (index) {
    final role = index.isEven ? 'assistant' : 'user';
    final longText = List.filled(12, '用于撑高列表').join('，');
    return Message.text(
      id: 'm_$index',
      role: role,
      content: '第$index条消息：$longText',
      createdAt: baseTime.add(Duration(minutes: index)),
      status: 'sent',
    );
  });
}

class _ChatListHarness extends StatefulWidget {
  const _ChatListHarness({super.key});

  @override
  State<_ChatListHarness> createState() => _ChatListHarnessState();
}

class _ChatListHarnessState extends State<_ChatListHarness> {
  late List<Message> _messages;
  bool _autoScrollToBottomEnabled = true;
  int _forceScrollToBottomSignal = 0;
  String? _streamingAssistantId;
  double _bottomOverlayHeight = 0;

  @override
  void initState() {
    super.initState();
    _messages = _buildInitialMessages(40);
  }

  void appendAssistantMessage() {
    final nextIndex = _messages.length;
    final lastTime = _messages.last.createdAt;
    final longText = List.filled(10, 'AI连续回复片段').join('，');
    setState(() {
      _messages = [
        ..._messages,
        Message.text(
          id: 'm_$nextIndex',
          role: 'assistant',
          content: '新增AI消息：$longText',
          createdAt: lastTime.add(const Duration(minutes: 1)),
          status: 'sent',
        ),
      ];
    });
  }

  void appendUserMessage() {
    final nextIndex = _messages.length;
    final lastTime = _messages.last.createdAt;
    final longText = List.filled(10, '用户发送消息').join('，');
    setState(() {
      _messages = [
        ..._messages,
        Message.text(
          id: 'm_$nextIndex',
          role: 'user',
          content: '新增用户消息：$longText',
          createdAt: lastTime.add(const Duration(minutes: 1)),
          status: 'sent',
        ),
      ];
    });
  }

  void appendAssistantStreamingMessage() {
    final nextIndex = _messages.length;
    final lastTime = _messages.last.createdAt;
    final id = 'm_$nextIndex';
    _streamingAssistantId = id;
    setState(() {
      _messages = [
        ..._messages,
        Message.text(
          id: id,
          role: 'assistant',
          content: '流式开始',
          createdAt: lastTime.add(const Duration(minutes: 1)),
          status: 'sending',
        ),
      ];
    });
  }

  void growAssistantStreamingChunk() {
    final streamId = _streamingAssistantId;
    if (streamId == null) return;
    setState(() {
      _messages = _messages
          .map((m) =>
              m.id == streamId ? m.copyWith(content: '${m.content} · 继续生成') : m)
          .toList();
    });
  }

  void resumeAutoScrollFromInputTap() {
    setState(() {
      _autoScrollToBottomEnabled = true;
    });
  }

  void forceScrollToBottomFromSend() {
    setState(() {
      _autoScrollToBottomEnabled = true;
      _forceScrollToBottomSignal += 1;
    });
  }

  void setBottomOverlayHeight(double height) {
    setState(() {
      _bottomOverlayHeight = height;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ChatMessageList(
      conversationId: 'conv_test',
      messages: _messages,
      displayName: '测试AI',
      avatarUrl: null,
      bottomOverlayHeight: _bottomOverlayHeight,
      autoScrollToBottomEnabled: _autoScrollToBottomEnabled,
      onAutoScrollDisabled: () {
        if (!_autoScrollToBottomEnabled) return;
        setState(() => _autoScrollToBottomEnabled = false);
      },
      forceScrollToBottomSignal: _forceScrollToBottomSignal,
    );
  }
}

Widget _buildHost(GlobalKey<_ChatListHarnessState> harnessKey) {
  final settings = _buildSettings();
  return ProviderScope(
    overrides: [
      appSettingsProvider
          .overrideWith(() => _FakeAppSettingsNotifier(settings)),
    ],
    child: SkinScope(
      skin: const MoeTalkSkin(),
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 360,
              height: 520,
              child: _ChatListHarness(key: harnessKey),
            ),
          ),
        ),
      ),
    ),
  );
}

Widget _buildHostWithMessages({
  required AppSettings settings,
  required List<Message> messages,
  StreamingBubbleState streamingBubbleState = StreamingBubbleState.hidden,
}) {
  return ProviderScope(
    overrides: [
      appSettingsProvider
          .overrideWith(() => _FakeAppSettingsNotifier(settings)),
    ],
    child: SkinScope(
      skin: const MoeTalkSkin(),
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 360,
              height: 520,
              child: ChatMessageList(
                conversationId: 'conv_test',
                messages: messages,
                displayName: '测试AI',
                avatarUrl: null,
                streamingBubbleState: streamingBubbleState,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

double _distanceToBottom(ScrollController controller) {
  return controller.position.maxScrollExtent - controller.offset;
}

GlobalKey _extractBubbleGestureKey(WidgetTester tester, String messageId) {
  final bubbleFinder =
      find.byKey(ValueKey<String>('message_bubble_$messageId'));
  expect(bubbleFinder, findsOneWidget);

  final gestureCandidates = find.ancestor(
    of: bubbleFinder,
    matching: find.byType(GestureDetector),
  );
  final keys = gestureCandidates
      .evaluate()
      .map((e) => e.widget)
      .whereType<GestureDetector>()
      .map((w) => w.key)
      .whereType<GlobalKey>()
      .toList(growable: false);

  expect(keys, isNotEmpty);
  return keys.first;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('assistant 纯 TextBlock 消息也应按前端规则分段', (tester) async {
    final settings = _buildSettings().copyWith(
      messageChunkingEnabled: true,
      messageFormatConfig: const MessageFormatConfig(
        enableChunking: true,
        chunkPunctuations: <String>['。'],
        minSegmentLength: 1,
      ),
    );
    final now = DateTime(2026, 1, 1, 12, 0, 0);
    final messages = <Message>[
      Message.fromBlocks(
        id: 'assistant_text_block',
        role: 'assistant',
        blocks: <MessageBlock>[
          TextBlock(
            messageId: 'assistant_text_block',
            content: '第一段。第二段。',
          ),
        ],
        createdAt: now,
        status: 'sent',
      ),
    ];

    await tester.pumpWidget(
      _buildHostWithMessages(
        settings: settings,
        messages: messages,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('第一段。'), findsOneWidget);
    expect(find.text('第二段。'), findsOneWidget);
    expect(find.text('第一段。第二段。'), findsNothing);
  });

  testWidgets('流式挂件应独立渲染并显示状态', (tester) async {
    await tester.pumpWidget(
      _buildHostWithMessages(
        settings: _buildSettings(),
        messages: const <Message>[],
        streamingBubbleState: const StreamingBubbleState(
          visible: true,
          text: '正在慢慢生成',
          status: StreamingBubbleStatus.streaming,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('streaming_bubble')), findsOne);
    expect(
        find.byKey(const ValueKey<String>('streaming_bubble_text')), findsOne);
    expect(find.text('生成中'), findsOneWidget);
    expect(find.text('正在慢慢生成'), findsOneWidget);
  });

  testWidgets('用户上滑后，AI新增消息不应强制回到底部', (tester) async {
    final harnessKey = GlobalKey<_ChatListHarnessState>();

    await tester.pumpWidget(_buildHost(harnessKey));
    await tester.pumpAndSettle();

    final listFinder = find.byType(ListView);
    expect(listFinder, findsOneWidget);

    await tester.drag(listFinder, const Offset(0, 320));
    await tester.pumpAndSettle();

    var controller = tester.widget<ListView>(listFinder).controller!;
    var gapAfterManual = _distanceToBottom(controller);
    if (gapAfterManual <= 40) {
      await tester.drag(listFinder, const Offset(0, -320));
      await tester.pumpAndSettle();
      controller = tester.widget<ListView>(listFinder).controller!;
      gapAfterManual = _distanceToBottom(controller);
    }
    expect(gapAfterManual, greaterThan(40));

    harnessKey.currentState!.appendAssistantMessage();
    await tester.pump();
    await tester.pumpAndSettle();

    controller = tester.widget<ListView>(listFinder).controller!;
    expect(_distanceToBottom(controller), greaterThan(40));
  });

  testWidgets('用户点击输入框时，若不在底部不应强制回到底部', (tester) async {
    final harnessKey = GlobalKey<_ChatListHarnessState>();

    await tester.pumpWidget(_buildHost(harnessKey));
    await tester.pumpAndSettle();

    final listFinder = find.byType(ListView);
    expect(listFinder, findsOneWidget);

    await tester.drag(listFinder, const Offset(0, 320));
    await tester.pumpAndSettle();

    var controller = tester.widget<ListView>(listFinder).controller!;
    var gapAfterManual = _distanceToBottom(controller);
    if (gapAfterManual <= 40) {
      await tester.drag(listFinder, const Offset(0, -320));
      await tester.pumpAndSettle();
      controller = tester.widget<ListView>(listFinder).controller!;
      gapAfterManual = _distanceToBottom(controller);
    }
    expect(gapAfterManual, greaterThan(40));

    harnessKey.currentState!.appendAssistantMessage();
    await tester.pump();
    await tester.pumpAndSettle();

    controller = tester.widget<ListView>(listFinder).controller!;
    expect(_distanceToBottom(controller), greaterThan(40));

    harnessKey.currentState!.resumeAutoScrollFromInputTap();
    await tester.pump();
    await tester.pumpAndSettle();

    controller = tester.widget<ListView>(listFinder).controller!;
    expect(_distanceToBottom(controller), greaterThan(40));
  });

  testWidgets('用户发送后应立即回到底部查看最新消息', (tester) async {
    final harnessKey = GlobalKey<_ChatListHarnessState>();

    await tester.pumpWidget(_buildHost(harnessKey));
    await tester.pumpAndSettle();

    final listFinder = find.byType(ListView);
    expect(listFinder, findsOneWidget);

    await tester.drag(listFinder, const Offset(0, 320));
    await tester.pumpAndSettle();

    var controller = tester.widget<ListView>(listFinder).controller!;
    var gapAfterManual = _distanceToBottom(controller);
    if (gapAfterManual <= 40) {
      await tester.drag(listFinder, const Offset(0, -320));
      await tester.pumpAndSettle();
      controller = tester.widget<ListView>(listFinder).controller!;
      gapAfterManual = _distanceToBottom(controller);
    }
    expect(gapAfterManual, greaterThan(40));

    harnessKey.currentState!.forceScrollToBottomFromSend();
    harnessKey.currentState!.appendUserMessage();
    await tester.pump();
    await tester.pumpAndSettle();

    controller = tester.widget<ListView>(listFinder).controller!;
    expect(_distanceToBottom(controller), lessThanOrEqualTo(8));
  });

  testWidgets('静止态下流式生成时，列表锚点应保持稳定', (tester) async {
    final harnessKey = GlobalKey<_ChatListHarnessState>();

    await tester.pumpWidget(_buildHost(harnessKey));
    await tester.pumpAndSettle();

    final listFinder = find.byType(ListView);
    expect(listFinder, findsOneWidget);

    await tester.drag(listFinder, const Offset(0, 320));
    await tester.pumpAndSettle();

    var controller = tester.widget<ListView>(listFinder).controller!;
    var gapAfterManual = _distanceToBottom(controller);
    if (gapAfterManual <= 40) {
      await tester.drag(listFinder, const Offset(0, -320));
      await tester.pumpAndSettle();
      controller = tester.widget<ListView>(listFinder).controller!;
      gapAfterManual = _distanceToBottom(controller);
    }
    expect(gapAfterManual, greaterThan(40));

    harnessKey.currentState!.appendAssistantStreamingMessage();
    await tester.pumpAndSettle();

    final gaps = <double>[];
    for (var i = 0; i < 12; i++) {
      harnessKey.currentState!.growAssistantStreamingChunk();
      await tester.pump(const Duration(milliseconds: 16));
      final controller = tester.widget<ListView>(listFinder).controller!;
      gaps.add(_distanceToBottom(controller));
    }
    await tester.pumpAndSettle();

    for (var i = 1; i < gaps.length; i++) {
      // 静止态流式更新过程中不应出现明显“反向回弹”抖动。
      expect(gaps[i], greaterThanOrEqualTo(gaps[i - 1] - 0.5));
    }
    var maxStep = 0.0;
    for (var i = 1; i < gaps.length; i++) {
      final step = (gaps[i] - gaps[i - 1]).abs();
      if (step > maxStep) maxStep = step;
    }
    expect(maxStep, lessThan(32.0));
  });

  testWidgets('同一条流式消息更新时，气泡锚点Key不应变化', (tester) async {
    final harnessKey = GlobalKey<_ChatListHarnessState>();

    await tester.pumpWidget(_buildHost(harnessKey));
    await tester.pumpAndSettle();

    harnessKey.currentState!.appendAssistantStreamingMessage();
    await tester.pumpAndSettle();

    final streamId = harnessKey.currentState!._streamingAssistantId;
    expect(streamId, isNotNull);

    final keyBefore = _extractBubbleGestureKey(tester, streamId!);

    harnessKey.currentState!.growAssistantStreamingChunk();
    await tester.pump(const Duration(milliseconds: 16));

    final keyAfter = _extractBubbleGestureKey(tester, streamId);
    expect(
      identical(keyBefore, keyAfter),
      isTrue,
      reason: '同一消息流式更新时若锚点Key变化，会导致气泡节点反复重建，出现视觉闪烁',
    );
  });

  testWidgets('阅读中点击输入框后，输入框升高应在当前位置上顶', (tester) async {
    final harnessKey = GlobalKey<_ChatListHarnessState>();

    await tester.pumpWidget(_buildHost(harnessKey));
    await tester.pumpAndSettle();

    final listFinder = find.byType(ListView);
    expect(listFinder, findsOneWidget);

    await tester.drag(listFinder, const Offset(0, 320));
    await tester.pumpAndSettle();

    var controller = tester.widget<ListView>(listFinder).controller!;
    expect(_distanceToBottom(controller), greaterThan(40));

    harnessKey.currentState!.resumeAutoScrollFromInputTap();
    await tester.pump();
    await tester.pumpAndSettle();

    controller = tester.widget<ListView>(listFinder).controller!;
    var gapBeforeOverlay = _distanceToBottom(controller);
    expect(gapBeforeOverlay, greaterThan(40));
    final offsetBeforeOverlay = controller.offset;

    harnessKey.currentState!.setBottomOverlayHeight(260);
    await tester.pump();
    await tester.pumpAndSettle();

    controller = tester.widget<ListView>(listFinder).controller!;
    final gapAfterOverlay = _distanceToBottom(controller);
    expect(gapAfterOverlay, greaterThan(40));
    expect(controller.offset, greaterThan(offsetBeforeOverlay + 100));
  });
}
