import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:aicove_flutter/src/features/chat/conversation_timeline_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/core/models/block_status.dart';
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_message_list.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_message_list_display_cache.dart';
import 'package:aicove_flutter/src/ui/theme/skin_provider.dart';
import 'package:aicove_flutter/src/ui/theme/skins/moetalk_skin.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.rootPath);

  final String rootPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => rootPath;
}

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

class _PagingChatListHarness extends StatefulWidget {
  const _PagingChatListHarness({
    super.key,
    this.onDebugAutoScrollRequested,
    this.onDebugListItemCountChanged,
  });

  final ValueChanged<String>? onDebugAutoScrollRequested;
  final ValueChanged<int>? onDebugListItemCountChanged;

  @override
  State<_PagingChatListHarness> createState() => _PagingChatListHarnessState();
}

class _PagingChatListHarnessState extends State<_PagingChatListHarness> {
  late List<Message> _messages;
  bool _autoScrollToBottomEnabled = true;
  bool _isLoadingMore = false;
  bool _hasMoreMessages = true;
  StreamingBubbleState _streamingBubbleState = StreamingBubbleState.hidden;
  Completer<void>? _pendingLoadMore;
  List<Message>? _transientEmptyBackupMessages;
  int loadMoreCallCount = 0;

  @override
  void initState() {
    super.initState();
    _messages = _buildInitialMessages(40).sublist(20);
  }

  Future<void> triggerLoadMore() {
    final pending = _pendingLoadMore;
    if (pending != null) {
      return pending.future;
    }

    final completer = Completer<void>();
    _pendingLoadMore = completer;
    loadMoreCallCount += 1;
    setState(() => _isLoadingMore = true);
    return completer.future;
  }

  void completeLoadMore() {
    final completer = _pendingLoadMore;
    if (completer == null) return;
    final oldest = _messages.first;
    final oldestIndex =
        int.tryParse(oldest.id.replaceFirst('m_', '')) ?? _messages.length;
    final olderMessages = List<Message>.generate(5, (index) {
      final messageIndex = oldestIndex - 5 + index;
      final role = messageIndex.isEven ? 'assistant' : 'user';
      final longText = List.filled(12, '用于撑高列表').join('，');
      return Message.text(
        id: 'm_$messageIndex',
        role: role,
        content: '第$messageIndex条消息：$longText',
        createdAt: oldest.createdAt.subtract(Duration(minutes: 5 - index)),
        status: 'sent',
      );
    });

    setState(() {
      _messages = [...olderMessages, ..._messages];
      _isLoadingMore = false;
      _hasMoreMessages = false;
      _pendingLoadMore = null;
    });
    completer.complete();
  }

  void updateStreamingBubble(String text) {
    setState(() {
      _streamingBubbleState = StreamingBubbleState(
        visible: true,
        text: text,
        status: StreamingBubbleStatus.streaming,
      );
    });
  }

  void mutateTailMessage() {
    final last = _messages.last;
    setState(() {
      _messages = [
        ..._messages.sublist(0, _messages.length - 1),
        last.copyWith(
          content: '${last.content} · 尾消息更新',
          status: 'sending',
        ),
      ];
    });
  }

  void beginTransientEmptyWindowDuringPaging() {
    _transientEmptyBackupMessages = List<Message>.from(_messages);
    setState(() {
      _isLoadingMore = true;
      _hasMoreMessages = true;
      _messages = const <Message>[];
    });
  }

  void endTransientEmptyWindowDuringPaging() {
    final backup = _transientEmptyBackupMessages;
    if (backup == null) return;
    setState(() {
      _messages = backup;
      _isLoadingMore = false;
      _transientEmptyBackupMessages = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ChatMessageList(
      conversationId: 'conv_paging_test',
      messages: _messages,
      displayName: '测试AI',
      avatarUrl: null,
      streamingBubbleState: _streamingBubbleState,
      autoScrollToBottomEnabled: _autoScrollToBottomEnabled,
      onAutoScrollDisabled: () {
        if (!_autoScrollToBottomEnabled) return;
        setState(() => _autoScrollToBottomEnabled = false);
      },
      onLoadMore: triggerLoadMore,
      isLoadingMore: _isLoadingMore,
      hasMoreMessages: _hasMoreMessages,
      onDebugAutoScrollRequested: widget.onDebugAutoScrollRequested,
      onDebugListItemCountChanged: widget.onDebugListItemCountChanged,
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

Widget _buildPagingHost(
  GlobalKey<_PagingChatListHarnessState> harnessKey, {
  ValueChanged<String>? onDebugAutoScrollRequested,
  ValueChanged<int>? onDebugListItemCountChanged,
}) {
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
              child: _PagingChatListHarness(
                key: harnessKey,
                onDebugAutoScrollRequested: onDebugAutoScrollRequested,
                onDebugListItemCountChanged: onDebugListItemCountChanged,
              ),
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
  List<Message> transientMessages = const <Message>[],
  bool allowPersistentViewportBoot = false,
  Key? chatListKey,
  ValueChanged<int>? onDebugListItemCountChanged,
  ValueChanged<String>? onDebugAutoScrollRequested,
  ValueChanged<int>? onPersistentViewportVisibleCountResolved,
  ValueChanged<bool>? onPersistentViewportHasMoreResolved,
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
                key: chatListKey,
                conversationId: 'conv_test',
                messages: messages,
                transientMessages: transientMessages,
                displayName: '测试AI',
                avatarUrl: null,
                streamingBubbleState: streamingBubbleState,
                allowPersistentViewportBoot: allowPersistentViewportBoot,
                onPersistentViewportVisibleCountResolved:
                    onPersistentViewportVisibleCountResolved,
                onPersistentViewportHasMoreResolved:
                    onPersistentViewportHasMoreResolved,
                onDebugListItemCountChanged: onDebugListItemCountChanged,
                onDebugAutoScrollRequested: onDebugAutoScrollRequested,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

double _distanceToBottom(ScrollController controller) {
  final position = controller.position;
  return position.pixels - position.minScrollExtent;
}

String _buildFormatSignatureForTest(MessageFormatConfig config) {
  final activePunctuations = config.effectiveChunkPunctuations.join(',');
  final filterPunctuations = config.filterPunctuations.join(',');
  return [
    config.enableChunking,
    config.filterPunctuation,
    activePunctuations,
    filterPunctuations,
    config.minSegmentLength,
    config.protectQuotes,
  ].join('|');
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
  late PathProviderPlatform previousPathProvider;
  Directory? tempDir;

  setUp(() async {
    previousPathProvider = PathProviderPlatform.instance;
    tempDir = await Directory.systemTemp.createTemp('chat_list_guard_test');
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir!.path);
    ChatMessageListDisplayCache.clear();
    await ChatMessageListDisplayCache.clearPersistent();
  });

  tearDown(() async {
    ChatMessageListDisplayCache.clear();
    await ChatMessageListDisplayCache.clearPersistent();
    PathProviderPlatform.instance = previousPathProvider;
    if (tempDir != null && await tempDir!.exists()) {
      await tempDir!.delete(recursive: true);
    }
  });

  test('持久快照按最近 5 轮问答收口，并保留同轮多模态拆分消息', () async {
    final baseTime = DateTime(2026, 3, 18, 10, 0, 0);
    Message buildMessage(String id, String role, int minuteOffset) {
      return Message.text(
        id: id,
        role: role,
        content: id,
        createdAt: baseTime.add(Duration(minutes: minuteOffset)),
        status: 'sent',
      );
    }

    final allMessages = <Message>[
      buildMessage('u1', 'user', 0),
      buildMessage('a1', 'assistant', 1),
      buildMessage('u2', 'user', 2),
      buildMessage('a2', 'assistant', 3),
      buildMessage('u3', 'user', 4),
      buildMessage('a3', 'assistant', 5),
      buildMessage('u4', 'user', 6),
      buildMessage('a4', 'assistant', 7),
      buildMessage('u5', 'user', 8),
      buildMessage('a5_text', 'assistant', 9),
      buildMessage('a5_audio', 'assistant', 10),
      buildMessage('u6', 'user', 11),
      buildMessage('a6_text', 'assistant', 12),
      buildMessage('a6_image', 'assistant', 13),
      buildMessage('a6_audio', 'assistant', 14),
    ];

    var loadOlderCalls = 0;
    final window = await resolvePersistentSnapshotWindow(
      currentMessages: allMessages.sublist(allMessages.length - 5),
      hasMoreMessages: true,
      loadOlderPage: ({
        required DateTime beforeCreatedAt,
        required String beforeId,
        required int limit,
      }) async {
        loadOlderCalls += 1;
        expect(beforeId, 'a5_audio');
        expect(beforeCreatedAt, allMessages[10].createdAt);
        return allMessages.sublist(0, allMessages.length - 5);
      },
    );

    expect(loadOlderCalls, 1);
    expect(window.messages.first.id, 'u2');
    expect(
      window.messages.map((message) => message.id).toList(),
      <String>[
        'u2',
        'a2',
        'u3',
        'a3',
        'u4',
        'a4',
        'u5',
        'a5_text',
        'a5_audio',
        'u6',
        'a6_text',
        'a6_image',
        'a6_audio',
      ],
    );
    expect(window.hasMoreMessages, isTrue);
  });

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

  testWidgets('临时流式消息应通过统一消息气泡渲染，不再出现独立挂件', (tester) async {
    await tester.pumpWidget(
      _buildHostWithMessages(
        settings: _buildSettings(),
        messages: const <Message>[],
        transientMessages: <Message>[
          Message.fromBlocks(
            id: 'temp_streaming',
            role: 'assistant',
            blocks: <MessageBlock>[
              TextBlock(
                messageId: 'temp_streaming',
                content: '正在慢慢生成',
                status: BlockStatus.streaming,
              ),
            ],
            createdAt: DateTime(2026, 1, 1, 12, 0, 0),
            status: 'sending',
          ),
        ],
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
        find.byKey(const ValueKey<String>('streaming_bubble')), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('message_bubble_temp_streaming')),
      findsOneWidget,
    );
  });

  testWidgets('语音占位出现后，后续文字仍应继续以消息气泡追加', (tester) async {
    await tester.pumpWidget(
      _buildHostWithMessages(
        settings: _buildSettings(),
        messages: const <Message>[],
        transientMessages: <Message>[
          Message.fromBlocks(
            id: 'temp_voice_pending',
            role: 'assistant',
            blocks: <MessageBlock>[
              AudioBlock(
                messageId: 'temp_voice_pending',
                url: '',
                text: '这是一段语音',
                status: BlockStatus.pending,
              ),
            ],
            createdAt: DateTime(2026, 1, 1, 12, 0, 0),
            status: 'sending',
          ),
          Message.text(
            id: 'temp_follow_text',
            role: 'assistant',
            content: '后续文字继续出现',
            createdAt: DateTime(2026, 1, 1, 12, 0, 1),
            status: 'sent',
          ),
        ],
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('生成中...'), findsOneWidget);
    expect(find.text('后续文字继续出现'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('message_bubble_temp_voice_pending')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('message_bubble_temp_follow_text')),
      findsOneWidget,
    );
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

  testWidgets('首屏快照切真实时间线时，真实消息未到前不应短暂清空列表', (tester) async {
    final settings = _buildSettings().copyWith(
      messageFormatConfig: const MessageFormatConfig(),
    );
    var latestItemCount = -1;
    ChatMessageListDisplayCache.write(
      conversationId: 'conv_test',
      windowSignature: 'viewport_boot_v2',
      formatSignature: _buildFormatSignatureForTest(
        settings.messageFormatConfig,
      ),
      listItems: const <Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'meta',
          'hasMoreMessages': true,
          'visibleTurnCount': 5,
          'lastMessagePreview': '首屏缓存命中',
          'lastMessageTime': 1234,
        },
        <String, dynamic>{
          'type': 'message',
          'messageId': 'm_boot',
          'message': <String, dynamic>{
            'id': 'm_boot',
            'role': 'assistant',
            'content': '首屏缓存命中',
            'createdAt': 1234,
            'status': 'sent',
            'blocks': <Map<String, dynamic>>[],
          },
          'showCorner': false,
          'showAvatar': true,
        },
      ].cast<Object>(),
      chatImages: const [],
    );
    expect(
      ChatMessageListDisplayCache.read(
        conversationId: 'conv_test',
        windowSignature: 'viewport_boot_v2',
        formatSignature: _buildFormatSignatureForTest(
          settings.messageFormatConfig,
        ),
      ),
      isNotNull,
    );

    await tester.pumpWidget(
      _buildHostWithMessages(
        settings: settings,
        messages: const <Message>[],
        allowPersistentViewportBoot: true,
        chatListKey: const ValueKey<String>('boot_list'),
        onDebugListItemCountChanged: (count) => latestItemCount = count,
      ),
    );
    await tester.pumpAndSettle();

    expect(latestItemCount, greaterThan(0));

    await tester.pumpWidget(
      _buildHostWithMessages(
        settings: settings,
        messages: const <Message>[],
        allowPersistentViewportBoot: false,
        chatListKey: const ValueKey<String>('boot_list'),
        onDebugListItemCountChanged: (count) => latestItemCount = count,
      ),
    );
    await tester.pumpAndSettle();

    expect(latestItemCount, greaterThan(0));
  });

  testWidgets('恢复持久快照后应回传缓存窗口大小，联动历史分页状态', (tester) async {
    await ChatMessageListDisplayCache.clearPersistent();
    final settings = _buildSettings().copyWith(
      messageFormatConfig: const MessageFormatConfig(),
    );
    final liveMessages = List<Message>.generate(5, (index) {
      return Message.text(
        id: 'live_$index',
        role: index.isEven ? 'user' : 'assistant',
        content: '实时消息 $index',
        createdAt: DateTime(2026, 3, 18, 12, index),
        status: 'sent',
      );
    });
    final formatSignature =
        _buildFormatSignatureForTest(settings.messageFormatConfig);
    await ChatMessageListDisplayCache.writePersistent(
      conversationId: 'conv_test',
      windowSignature: 'viewport_boot_v2',
      formatSignature: formatSignature,
      listItems: const <Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'meta',
          'hasMoreMessages': true,
          'visibleTurnCount': 12,
          'lastMessagePreview': '缓存窗口',
          'lastMessageTime': 1234,
        },
        <String, dynamic>{
          'type': 'message',
          'messageId': 'cached_tail',
          'message': <String, dynamic>{
            'id': 'cached_tail',
            'role': 'assistant',
            'content': '缓存窗口',
            'createdAt': 1234,
            'status': 'sent',
            'blocks': <Map<String, dynamic>>[],
          },
          'showCorner': false,
          'showAvatar': true,
        },
      ],
    );

    var resolvedVisibleCount = -1;
    bool? resolvedHasMore;
    await tester.pumpWidget(
      _buildHostWithMessages(
        settings: settings,
        messages: liveMessages,
        onPersistentViewportVisibleCountResolved: (count) {
          resolvedVisibleCount = count;
        },
        onPersistentViewportHasMoreResolved: (hasMore) {
          resolvedHasMore = hasMore;
        },
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));

    expect(resolvedVisibleCount, 12);
    expect(resolvedHasMore, isTrue);
  });

  testWidgets('当前尾消息已变化时不应回退到旧的持久快照', (tester) async {
    await ChatMessageListDisplayCache.clearPersistent();
    final settings = _buildSettings().copyWith(
      messageFormatConfig: const MessageFormatConfig(),
    );
    final liveMessages = <Message>[
      Message.text(
        id: 'u_now',
        role: 'user',
        content: '刚发送的新消息',
        createdAt: DateTime(2026, 3, 19, 9, 0, 0),
        status: 'sent',
      ),
      Message.text(
        id: 'a_now',
        role: 'assistant',
        content: '当前真实尾消息',
        createdAt: DateTime(2026, 3, 19, 9, 0, 1),
        status: 'sent',
      ),
    ];
    final formatSignature =
        _buildFormatSignatureForTest(settings.messageFormatConfig);
    await ChatMessageListDisplayCache.writePersistent(
      conversationId: 'conv_test',
      windowSignature: 'viewport_boot_v2',
      formatSignature: formatSignature,
      listItems: const <Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'meta',
          'hasMoreMessages': true,
          'visibleTurnCount': 5,
          'lastMessagePreview': '旧的持久快照',
          'lastMessageTime': 1234,
        },
        <String, dynamic>{
          'type': 'message',
          'messageId': 'cached_old_tail',
          'message': <String, dynamic>{
            'id': 'cached_old_tail',
            'role': 'assistant',
            'content': '旧的持久快照',
            'createdAt': 1234,
            'status': 'sent',
            'blocks': <Map<String, dynamic>>[],
          },
          'showCorner': false,
          'showAvatar': true,
        },
      ],
    );

    await tester.pumpWidget(
      _buildHostWithMessages(
        settings: settings,
        messages: liveMessages,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));

    expect(find.textContaining('当前真实尾消息'), findsWidgets);
    expect(find.textContaining('旧的持久快照'), findsNothing);
  });

  testWidgets('历史分页加载时不应闪回底部，顶部应显示独立 loading overlay', (tester) async {
    final harnessKey = GlobalKey<_PagingChatListHarnessState>();

    await tester.pumpWidget(_buildPagingHost(harnessKey));
    await tester.pumpAndSettle();

    final listFinder = find.byType(ListView);
    expect(listFinder, findsOneWidget);

    await tester.drag(listFinder, const Offset(0, 4000));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(harnessKey.currentState!.loadMoreCallCount, 1);
    expect(find.byKey(const ValueKey<String>('history_loading_overlay')),
        findsOneWidget);

    var controller = tester.widget<ListView>(listFinder).controller!;
    final gapWhileLoading = _distanceToBottom(controller);
    expect(gapWhileLoading, greaterThan(40));

    harnessKey.currentState!.completeLoadMore();
    await tester.pump();
    await tester.pumpAndSettle();

    controller = tester.widget<ListView>(listFinder).controller!;
    expect(_distanceToBottom(controller), greaterThan(40));
    expect(find.byKey(const ValueKey<String>('history_loading_overlay')),
        findsNothing);

    await tester.drag(listFinder, const Offset(0, 260));
    await tester.pumpAndSettle();
    if (find.textContaining('第15条消息').evaluate().isEmpty) {
      await tester.drag(listFinder, const Offset(0, 220));
      await tester.pumpAndSettle();
    }

    expect(find.textContaining('第15条消息'), findsWidgets);
  });

  testWidgets('历史分页期间尾消息变化不应请求回到底部', (tester) async {
    final harnessKey = GlobalKey<_PagingChatListHarnessState>();
    final autoScrollReasons = <String>[];

    await tester.pumpWidget(
      _buildPagingHost(
        harnessKey,
        onDebugAutoScrollRequested: autoScrollReasons.add,
      ),
    );
    await tester.pumpAndSettle();
    autoScrollReasons.clear();

    harnessKey.currentState!.triggerLoadMore();
    await tester.pump();

    harnessKey.currentState!.mutateTailMessage();
    await tester.pump();

    expect(autoScrollReasons, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('历史分页瞬时空窗口不应清空列表或触发回底请求', (tester) async {
    final harnessKey = GlobalKey<_PagingChatListHarnessState>();
    final autoScrollReasons = <String>[];
    var latestItemCount = -1;

    await tester.pumpWidget(
      _buildPagingHost(
        harnessKey,
        onDebugAutoScrollRequested: autoScrollReasons.add,
        onDebugListItemCountChanged: (count) => latestItemCount = count,
      ),
    );
    await tester.pumpAndSettle();

    expect(latestItemCount, greaterThan(0));
    autoScrollReasons.clear();

    harnessKey.currentState!.beginTransientEmptyWindowDuringPaging();
    await tester.pump();

    expect(latestItemCount, greaterThan(0));
    expect(autoScrollReasons, isEmpty);
    expect(tester.takeException(), isNull);

    harnessKey.currentState!.endTransientEmptyWindowDuringPaging();
    await tester.pumpAndSettle();

    expect(latestItemCount, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('流式临时消息切正式落库的交接空窗不应先把尾消息闪掉', (tester) async {
    final settings = _buildSettings().copyWith(
      messageFormatConfig: const MessageFormatConfig(),
    );
    final stableMessages = _buildInitialMessages(6);
    final transientTail = Message.text(
      id: 'stream_commit_tail',
      role: 'assistant',
      content: '刚生成好的最后一段',
      createdAt: stableMessages.last.createdAt.add(const Duration(seconds: 1)),
      status: 'sent',
    );
    var latestItemCount = -1;

    await tester.pumpWidget(
      _buildHostWithMessages(
        settings: settings,
        messages: stableMessages,
        transientMessages: <Message>[transientTail],
        chatListKey: const ValueKey<String>('transient_handoff_list'),
        onDebugListItemCountChanged: (count) => latestItemCount = count,
      ),
    );
    await tester.pumpAndSettle();

    final itemCountWithTransient = latestItemCount;
    expect(find.textContaining('刚生成好的最后一段'), findsWidgets);

    await tester.pumpWidget(
      _buildHostWithMessages(
        settings: settings,
        messages: stableMessages,
        transientMessages: const <Message>[],
        chatListKey: const ValueKey<String>('transient_handoff_list'),
        onDebugListItemCountChanged: (count) => latestItemCount = count,
      ),
    );
    await tester.pump();

    expect(
      find.textContaining('刚生成好的最后一段'),
      findsWidgets,
      reason: '正式消息还没接手前，不应先把整段尾消息撤掉造成闪烁',
    );
    expect(latestItemCount, itemCountWithTransient);

    await tester.pumpWidget(
      _buildHostWithMessages(
        settings: settings,
        messages: <Message>[...stableMessages, transientTail],
        transientMessages: const <Message>[],
        chatListKey: const ValueKey<String>('transient_handoff_list'),
        onDebugListItemCountChanged: (count) => latestItemCount = count,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('刚生成好的最后一段'), findsWidgets);
    expect(latestItemCount, greaterThan(itemCountWithTransient - 1));
  });

  testWidgets('流式临时消息交接若正式消息一直未到，保护窗超时后应释放旧尾消息', (tester) async {
    final settings = _buildSettings().copyWith(
      messageFormatConfig: const MessageFormatConfig(),
    );
    final stableMessages = _buildInitialMessages(6);
    final transientTail = Message.text(
      id: 'stream_commit_tail_timeout',
      role: 'assistant',
      content: '短暂保护后应消失',
      createdAt: stableMessages.last.createdAt.add(const Duration(seconds: 1)),
      status: 'sent',
    );

    await tester.pumpWidget(
      _buildHostWithMessages(
        settings: settings,
        messages: stableMessages,
        transientMessages: <Message>[transientTail],
        chatListKey: const ValueKey<String>('transient_handoff_timeout_list'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('短暂保护后应消失'), findsWidgets);

    await tester.pumpWidget(
      _buildHostWithMessages(
        settings: settings,
        messages: stableMessages,
        transientMessages: const <Message>[],
        chatListKey: const ValueKey<String>('transient_handoff_timeout_list'),
      ),
    );
    await tester.pump();
    expect(find.textContaining('短暂保护后应消失'), findsWidgets);

    await tester.pump(const Duration(milliseconds: 260));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('短暂保护后应消失'),
      findsNothing,
      reason: '如果正式消息最终没有接手，旧的临时尾消息不应一直停留在列表里',
    );
  });

  testWidgets('首屏快照切真实时间线时尾消息一致不应触发 tailChanged 回底', (tester) async {
    final settings = _buildSettings().copyWith(
      messageFormatConfig: const MessageFormatConfig(),
    );
    final autoScrollReasons = <String>[];

    const createdAtMs = 1234;
    ChatMessageListDisplayCache.write(
      conversationId: 'conv_test',
      windowSignature: 'viewport_boot_v2',
      formatSignature: _buildFormatSignatureForTest(
        settings.messageFormatConfig,
      ),
      listItems: const <Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'meta',
          'hasMoreMessages': true,
          'visibleTurnCount': 5,
          'lastMessagePreview': '首屏缓存命中',
          'lastMessageTime': createdAtMs,
        },
        <String, dynamic>{
          'type': 'message',
          'messageId': 'm_boot',
          'message': <String, dynamic>{
            'id': 'm_boot',
            'role': 'assistant',
            'content': '首屏缓存命中',
            'createdAt': createdAtMs,
            'status': 'sent',
            'blocks': <Map<String, dynamic>>[],
          },
          'showCorner': false,
          'showAvatar': true,
        },
      ].cast<Object>(),
      chatImages: const [],
    );

    await tester.pumpWidget(
      _buildHostWithMessages(
        settings: settings,
        messages: const <Message>[],
        allowPersistentViewportBoot: true,
        chatListKey: const ValueKey<String>('boot_tail'),
        onDebugAutoScrollRequested: autoScrollReasons.add,
      ),
    );
    await tester.pumpAndSettle();
    autoScrollReasons.clear();

    await tester.pumpWidget(
      _buildHostWithMessages(
        settings: settings,
        messages: <Message>[
          Message.text(
            id: 'm_boot',
            role: 'assistant',
            content: '首屏缓存命中',
            createdAt: DateTime.fromMillisecondsSinceEpoch(createdAtMs),
            status: 'sent',
          ),
        ],
        allowPersistentViewportBoot: false,
        chatListKey: const ValueKey<String>('boot_tail'),
        onDebugAutoScrollRequested: autoScrollReasons.add,
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(
        autoScrollReasons.where((reason) => reason == 'tailChanged'), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('触顶分页时松手后应轻微回弹回边界，不应卡在中间', (tester) async {
    final harnessKey = GlobalKey<_PagingChatListHarnessState>();

    await tester.pumpWidget(_buildPagingHost(harnessKey));
    await tester.pumpAndSettle();

    final listFinder = find.byType(ListView);
    expect(listFinder, findsOneWidget);

    await tester.drag(listFinder, const Offset(0, 4000));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(harnessKey.currentState!.loadMoreCallCount, 1);

    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump(const Duration(milliseconds: 120));
    expect(tester.takeException(), isNull);

    final controller = tester.widget<ListView>(listFinder).controller!;
    final position = controller.position;
    final distanceToTop = (position.maxScrollExtent - controller.offset).abs();

    expect(
      controller.offset,
      lessThanOrEqualTo(position.maxScrollExtent + 24),
      reason: '松手后只允许很小的顶部回弹，不能停在明显越界的位置',
    );
    expect(
      distanceToTop,
      lessThanOrEqualTo(24),
      reason: '回弹幅度应很小，停留点需要贴近顶部边界，不能被拉回中段',
    );
    expect(
      _distanceToBottom(controller),
      greaterThan(40),
      reason: '触顶分页期间不应被强制拽回到底部',
    );

    harnessKey.currentState!.completeLoadMore();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 320));
    await tester.pumpAndSettle();
  });
}
