import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/core/models/block_status.dart';
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_message_list.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_message_list_display_cache.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_viewport_controller.dart';
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

List<Message> _buildCompactMessages({
  required int startIndex,
  required int count,
}) {
  final baseTime = DateTime(2026, 1, 1, 12, 0, 0);
  return List<Message>.generate(count, (offset) {
    final index = startIndex + offset;
    final role = index.isEven ? 'assistant' : 'user';
    return Message.text(
      id: 'm_$index',
      role: role,
      content: '短消息$index',
      createdAt: baseTime.add(Duration(minutes: index)),
      status: 'sent',
    );
  });
}

class _ChatListHarness extends StatefulWidget {
  const _ChatListHarness({
    super.key,
    this.onDebugAutoScrollRequested,
    this.onDebugListItemCountChanged,
  });

  final ValueChanged<String>? onDebugAutoScrollRequested;
  final ValueChanged<int>? onDebugListItemCountChanged;

  @override
  State<_ChatListHarness> createState() => _ChatListHarnessState();
}

class _ChatListHarnessState extends State<_ChatListHarness> {
  late List<Message> _messages;
  late final ChatViewportController _viewportController;
  String? _streamingAssistantId;
  double _bottomOverlayHeight = 0;

  @override
  void initState() {
    super.initState();
    _viewportController = ChatViewportController();
    _messages = _buildInitialMessages(40);
  }

  @override
  void dispose() {
    _viewportController.dispose();
    super.dispose();
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
          .map((m) => m.id == streamId
              ? _replaceMessageText(
                  m,
                  '${m.displayText} · 继续生成',
                  status: 'sending',
                )
              : m)
          .toList();
    });
  }

  void growAssistantStreamingChunkLarge() {
    final streamId = _streamingAssistantId;
    if (streamId == null) return;
    const fragment = '继续生成内容用于撑高列表，继续生成内容用于撑高列表，继续生成内容用于撑高列表';
    setState(() {
      _messages = _messages
          .map((m) => m.id == streamId
              ? _replaceMessageText(
                  m,
                  '${m.displayText}\n$fragment',
                  status: 'sending',
                )
              : m)
          .toList();
    });
  }

  void resumeAutoScrollFromInputTap() {
    _viewportController.onComposerTapped();
  }

  void forceScrollToBottomFromSend() {
    _viewportController.onUserSend();
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
      viewportController: _viewportController,
      onDebugAutoScrollRequested: widget.onDebugAutoScrollRequested,
      onDebugListItemCountChanged: widget.onDebugListItemCountChanged,
    );
  }
}

class _PagingChatListHarness extends StatefulWidget {
  const _PagingChatListHarness({
    super.key,
    this.onDebugAutoScrollRequested,
    this.onDebugListItemCountChanged,
    this.initialMessages,
    this.messageBuilder,
  });

  final ValueChanged<String>? onDebugAutoScrollRequested;
  final ValueChanged<int>? onDebugListItemCountChanged;
  final List<Message>? initialMessages;
  final Message Function(int messageIndex, DateTime createdAt)? messageBuilder;

  @override
  State<_PagingChatListHarness> createState() => _PagingChatListHarnessState();
}

class _PagingChatListHarnessState extends State<_PagingChatListHarness> {
  late List<Message> _messages;
  late final ChatViewportController _viewportController;
  bool _isLoadingMore = false;
  bool _hasMoreMessages = true;
  List<Message> _transientMessages = const <Message>[];
  Completer<void>? _pendingLoadMore;
  List<Message>? _transientEmptyBackupMessages;
  int loadMoreCallCount = 0;

  @override
  void initState() {
    super.initState();
    _viewportController = ChatViewportController();
    _messages = widget.initialMessages ?? _buildInitialMessages(40).sublist(20);
  }

  @override
  void dispose() {
    _viewportController.dispose();
    super.dispose();
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

  void releaseLoadingBeforeMessages() {
    final completer = _pendingLoadMore;
    if (completer == null) return;
    setState(() {
      _isLoadingMore = false;
      _pendingLoadMore = null;
    });
    completer.complete();
  }

  List<Message> _buildOlderMessagesFromOldest(
    Message oldest, {
    required int count,
  }) {
    final oldestIndex =
        int.tryParse(oldest.id.replaceFirst('m_', '')) ?? _messages.length;
    return List<Message>.generate(count, (index) {
      final messageIndex = oldestIndex - count + index;
      final createdAt =
          oldest.createdAt.subtract(Duration(minutes: count - index));
      final builder = widget.messageBuilder;
      if (builder != null) {
        return builder(messageIndex, createdAt);
      }
      final role = messageIndex.isEven ? 'assistant' : 'user';
      final longText = List.filled(12, '用于撑高列表').join('，');
      return Message.text(
        id: 'm_$messageIndex',
        role: role,
        content: '第$messageIndex条消息：$longText',
        createdAt: createdAt,
        status: 'sent',
      );
    });
  }

  void appendOlderMessages({
    int count = 5,
    bool hasMoreMessages = false,
  }) {
    final oldest = _messages.first;
    final olderMessages = _buildOlderMessagesFromOldest(
      oldest,
      count: count,
    );

    setState(() {
      _messages = [...olderMessages, ..._messages];
      _hasMoreMessages = hasMoreMessages;
    });
  }

  void completeLoadMore({
    int count = 5,
    bool hasMoreMessages = false,
  }) {
    final completer = _pendingLoadMore;
    if (completer == null) return;
    appendOlderMessages(
      count: count,
      hasMoreMessages: hasMoreMessages,
    );
    setState(() {
      _isLoadingMore = false;
      _hasMoreMessages = hasMoreMessages;
      _pendingLoadMore = null;
    });
    completer.complete();
  }

  void completeLoadMoreWithTailMutation() {
    final completer = _pendingLoadMore;
    if (completer == null) return;
    final tail = _messages.last;
    appendOlderMessages();
    setState(() {
      _messages = [
        ..._messages.sublist(0, _messages.length - 1),
        _replaceMessageText(
          tail,
          '${tail.displayText} · 分页归档后同步',
          status: 'sent',
        ),
      ];
      _isLoadingMore = false;
      _hasMoreMessages = false;
      _pendingLoadMore = null;
    });
    completer.complete();
  }

  void updateStreamingBubble(String text) {
    final createdAt = _messages.isNotEmpty
        ? _messages.last.createdAt.add(const Duration(milliseconds: 1))
        : DateTime(2026, 1, 1, 12, 0, 0);
    setState(() {
      _transientMessages = <Message>[
        Message.fromBlocks(
          id: 'temp_streaming',
          role: 'assistant',
          blocks: <MessageBlock>[
            TextBlock(
              messageId: 'temp_streaming',
              content: text,
              status: BlockStatus.streaming,
            ),
          ],
          createdAt: createdAt,
          status: 'sending',
        ),
      ];
    });
  }

  void mutateTailMessage() {
    final last = _messages.last;
    setState(() {
      _messages = [
        ..._messages.sublist(0, _messages.length - 1),
        _replaceMessageText(
          last,
          '${last.displayText} · 尾消息更新',
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

  void beginTransientEmptyWindowAfterLoadingReleased() {
    _transientEmptyBackupMessages = List<Message>.from(_messages);
    setState(() {
      _isLoadingMore = false;
      _hasMoreMessages = true;
      _messages = const <Message>[];
    });
  }

  void endTransientEmptyWindowAfterLoadingReleased({
    int count = 5,
    bool hasMoreMessages = false,
  }) {
    final backup = _transientEmptyBackupMessages;
    if (backup == null || backup.isEmpty) return;
    final olderMessages = _buildOlderMessagesFromOldest(
      backup.first,
      count: count,
    );
    setState(() {
      _messages = <Message>[
        ...olderMessages,
        ...backup,
      ];
      _hasMoreMessages = hasMoreMessages;
      _transientEmptyBackupMessages = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ChatMessageList(
      conversationId: 'conv_paging_test',
      messages: _messages,
      transientMessages: _transientMessages,
      displayName: '测试AI',
      avatarUrl: null,
      viewportController: _viewportController,
      onLoadMore: triggerLoadMore,
      isLoadingMore: _isLoadingMore,
      hasMoreMessages: _hasMoreMessages,
      onDebugAutoScrollRequested: widget.onDebugAutoScrollRequested,
      onDebugListItemCountChanged: widget.onDebugListItemCountChanged,
    );
  }
}

Message _replaceMessageText(
  Message message,
  String text, {
  String? status,
}) {
  return Message.text(
    id: message.id,
    role: message.role,
    content: text,
    createdAt: message.createdAt,
    status: status ?? message.status,
  );
}

Widget _buildHost(
  GlobalKey<_ChatListHarnessState> harnessKey, {
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
              child: _ChatListHarness(
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

Widget _buildPagingHost(
  GlobalKey<_PagingChatListHarnessState> harnessKey, {
  ValueChanged<String>? onDebugAutoScrollRequested,
  ValueChanged<int>? onDebugListItemCountChanged,
  List<Message>? initialMessages,
  Message Function(int messageIndex, DateTime createdAt)? messageBuilder,
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
                initialMessages: initialMessages,
                messageBuilder: messageBuilder,
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
  List<Message> transientMessages = const <Message>[],
  bool allowPersistentViewportBoot = false,
  Future<void> Function()? onLoadMore,
  bool isLoadingMore = false,
  bool hasMoreMessages = true,
  double bottomOverlayHeight = 0,
  Key? chatListKey,
  ChatViewportController? viewportController,
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
                bottomOverlayHeight: bottomOverlayHeight,
                viewportController:
                    viewportController ?? ChatViewportController(),
                onLoadMore: onLoadMore,
                isLoadingMore: isLoadingMore,
                hasMoreMessages: hasMoreMessages,
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

    final listFinder = find.byType(CustomScrollView);
    expect(listFinder, findsOneWidget);

    await tester.drag(listFinder, const Offset(0, 320));
    await tester.pumpAndSettle();

    var controller = tester.widget<CustomScrollView>(listFinder).controller!;
    var gapAfterManual = _distanceToBottom(controller);
    if (gapAfterManual <= 40) {
      await tester.drag(listFinder, const Offset(0, -320));
      await tester.pumpAndSettle();
      controller = tester.widget<CustomScrollView>(listFinder).controller!;
      gapAfterManual = _distanceToBottom(controller);
    }
    expect(gapAfterManual, greaterThan(40));

    harnessKey.currentState!.appendAssistantMessage();
    await tester.pump();
    await tester.pumpAndSettle();

    controller = tester.widget<CustomScrollView>(listFinder).controller!;
    expect(_distanceToBottom(controller), greaterThan(40));
  });

  testWidgets('用户远离底部后，应显示回到底部箭头且不受新消息影响', (tester) async {
    final harnessKey = GlobalKey<_ChatListHarnessState>();

    await tester.pumpWidget(_buildHost(harnessKey));
    await tester.pumpAndSettle();

    final listFinder = find.byType(CustomScrollView);
    expect(listFinder, findsOneWidget);

    await tester.drag(listFinder, const Offset(0, 320));
    await tester.pumpAndSettle();

    var controller = tester.widget<CustomScrollView>(listFinder).controller!;
    var gapAfterManual = _distanceToBottom(controller);
    if (gapAfterManual <= 40) {
      await tester.drag(listFinder, const Offset(0, -320));
      await tester.pumpAndSettle();
      controller = tester.widget<CustomScrollView>(listFinder).controller!;
      gapAfterManual = _distanceToBottom(controller);
    }
    expect(gapAfterManual, greaterThan(120));
    expect(
      find.byKey(const ValueKey<String>('chat_jump_to_latest_badge')),
      findsOneWidget,
      reason: '只要用户已经离底部比较远，就应该直接提供回到底部的小箭头',
    );

    harnessKey.currentState!.appendAssistantMessage();
    await tester.pump();
    await tester.pumpAndSettle();

    controller = tester.widget<CustomScrollView>(listFinder).controller!;
    expect(
      _distanceToBottom(controller),
      greaterThan(40),
      reason: '阅读历史时收到新消息不应强制回到底部',
    );
    expect(
      find.byKey(const ValueKey<String>('chat_jump_to_latest_badge')),
      findsOneWidget,
      reason: '箭头显示条件应继续只由离底部距离决定，而不是由新消息触发',
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('chat_jump_to_latest_badge')),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    controller = tester.widget<CustomScrollView>(listFinder).controller!;
    expect(_distanceToBottom(controller), lessThanOrEqualTo(8));
    expect(
      find.byKey(const ValueKey<String>('chat_jump_to_latest_badge')),
      findsNothing,
      reason: '回到底部后，箭头应自动消失',
    );
  });

  testWidgets('用户点击输入框时，若不在底部不应强制回到底部', (tester) async {
    final harnessKey = GlobalKey<_ChatListHarnessState>();

    await tester.pumpWidget(_buildHost(harnessKey));
    await tester.pumpAndSettle();

    final listFinder = find.byType(CustomScrollView);
    expect(listFinder, findsOneWidget);

    await tester.drag(listFinder, const Offset(0, 320));
    await tester.pumpAndSettle();

    var controller = tester.widget<CustomScrollView>(listFinder).controller!;
    var gapAfterManual = _distanceToBottom(controller);
    if (gapAfterManual <= 40) {
      await tester.drag(listFinder, const Offset(0, -320));
      await tester.pumpAndSettle();
      controller = tester.widget<CustomScrollView>(listFinder).controller!;
      gapAfterManual = _distanceToBottom(controller);
    }
    expect(gapAfterManual, greaterThan(40));

    harnessKey.currentState!.appendAssistantMessage();
    await tester.pump();
    await tester.pumpAndSettle();

    controller = tester.widget<CustomScrollView>(listFinder).controller!;
    expect(_distanceToBottom(controller), greaterThan(40));

    harnessKey.currentState!.resumeAutoScrollFromInputTap();
    await tester.pump();
    await tester.pumpAndSettle();

    controller = tester.widget<CustomScrollView>(listFinder).controller!;
    expect(_distanceToBottom(controller), greaterThan(40));
  });

  testWidgets('点击输入框不应解除阅读锁，只有发送消息才恢复自动跟随', (tester) async {
    final harnessKey = GlobalKey<_ChatListHarnessState>();

    await tester.pumpWidget(_buildHost(harnessKey));
    await tester.pumpAndSettle();

    final listFinder = find.byType(CustomScrollView);
    expect(listFinder, findsOneWidget);

    await tester.drag(listFinder, const Offset(0, 320));
    await tester.pumpAndSettle();

    expect(
      harnessKey.currentState!._viewportController.shouldFollowLatest,
      isFalse,
      reason: '用户手势介入后，应进入阅读锁定态',
    );

    harnessKey.currentState!.resumeAutoScrollFromInputTap();
    await tester.pumpAndSettle();

    expect(
      harnessKey.currentState!._viewportController.shouldFollowLatest,
      isFalse,
      reason: '点击输入框不应解除阅读锁，避免程序重新接管视窗',
    );

    harnessKey.currentState!.forceScrollToBottomFromSend();
    await tester.pumpAndSettle();

    expect(
      harnessKey.currentState!._viewportController.shouldFollowLatest,
      isTrue,
      reason: '只有用户再次发送消息后，才应恢复自动跟随',
    );
  });

  testWidgets('用户发送后应立即回到底部查看最新消息', (tester) async {
    final harnessKey = GlobalKey<_ChatListHarnessState>();

    await tester.pumpWidget(_buildHost(harnessKey));
    await tester.pumpAndSettle();

    final listFinder = find.byType(CustomScrollView);
    expect(listFinder, findsOneWidget);

    await tester.drag(listFinder, const Offset(0, 320));
    await tester.pumpAndSettle();

    var controller = tester.widget<CustomScrollView>(listFinder).controller!;
    var gapAfterManual = _distanceToBottom(controller);
    if (gapAfterManual <= 40) {
      await tester.drag(listFinder, const Offset(0, -320));
      await tester.pumpAndSettle();
      controller = tester.widget<CustomScrollView>(listFinder).controller!;
      gapAfterManual = _distanceToBottom(controller);
    }
    expect(gapAfterManual, greaterThan(40));

    harnessKey.currentState!.forceScrollToBottomFromSend();
    harnessKey.currentState!.appendUserMessage();
    await tester.pump();
    await tester.pumpAndSettle();

    controller = tester.widget<CustomScrollView>(listFinder).controller!;
    expect(_distanceToBottom(controller), lessThanOrEqualTo(8));
  });

  testWidgets('贴底状态下，AI 新消息不应自动请求回底', (tester) async {
    final harnessKey = GlobalKey<_ChatListHarnessState>();
    final autoScrollReasons = <String>[];

    await tester.pumpWidget(
      _buildHost(
        harnessKey,
        onDebugAutoScrollRequested: autoScrollReasons.add,
      ),
    );
    await tester.pumpAndSettle();
    autoScrollReasons.clear();

    final listFinder = find.byType(CustomScrollView);
    expect(listFinder, findsOneWidget);

    harnessKey.currentState!.appendAssistantMessage();
    await tester.pump();
    await tester.pumpAndSettle();

    final controller = tester.widget<CustomScrollView>(listFinder).controller!;
    expect(
      _distanceToBottom(controller),
      greaterThan(40),
      reason: 'AI 新消息到达后，视口不应继续由程序维持在底部',
    );
    expect(autoScrollReasons, isEmpty);
  });

  testWidgets('贴底状态下，临时流式消息变化不应自动请求回底', (tester) async {
    final settings = _buildSettings();
    final autoScrollReasons = <String>[];
    final viewportController = ChatViewportController();
    final baseMessages = _buildInitialMessages(40);
    final transientMessage = Message.text(
      id: 'temp_streaming',
      role: 'assistant',
      content: List.filled(10, '流式临时内容').join('，'),
      createdAt: baseMessages.last.createdAt.add(const Duration(minutes: 1)),
      status: 'sending',
    );

    await tester.pumpWidget(
      _buildHostWithMessages(
        settings: settings,
        messages: baseMessages,
        viewportController: viewportController,
        onDebugAutoScrollRequested: autoScrollReasons.add,
      ),
    );
    await tester.pumpAndSettle();
    autoScrollReasons.clear();

    await tester.pumpWidget(
      _buildHostWithMessages(
        settings: settings,
        messages: baseMessages,
        transientMessages: <Message>[transientMessage],
        viewportController: viewportController,
        onDebugAutoScrollRequested: autoScrollReasons.add,
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    final listFinder = find.byType(CustomScrollView);
    final controller = tester.widget<CustomScrollView>(listFinder).controller!;
    expect(
      _distanceToBottom(controller),
      greaterThan(40),
      reason: '临时流式消息出现后，也不应由程序继续贴底',
    );
    expect(autoScrollReasons, isEmpty);
    viewportController.dispose();
  });

  testWidgets('贴底状态下，输入区高度变化不应自动请求回底', (tester) async {
    final harnessKey = GlobalKey<_ChatListHarnessState>();
    final autoScrollReasons = <String>[];

    await tester.pumpWidget(
      _buildHost(
        harnessKey,
        onDebugAutoScrollRequested: autoScrollReasons.add,
      ),
    );
    await tester.pumpAndSettle();
    autoScrollReasons.clear();

    harnessKey.currentState!.setBottomOverlayHeight(180);
    await tester.pump();
    await tester.pumpAndSettle();

    expect(autoScrollReasons, isEmpty);
  });

  testWidgets('空时间线里临时消息变化也不应自动请求回底', (tester) async {
    final settings = _buildSettings();
    final autoScrollReasons = <String>[];
    final viewportController = ChatViewportController();
    final transientMessage = Message.text(
      id: 'temp_empty_timeline',
      role: 'assistant',
      content: List.filled(10, '空会话流式内容').join('，'),
      createdAt: DateTime(2026, 1, 1, 12, 0, 0),
      status: 'sending',
    );

    await tester.pumpWidget(
      _buildHostWithMessages(
        settings: settings,
        messages: const <Message>[],
        viewportController: viewportController,
        onDebugAutoScrollRequested: autoScrollReasons.add,
      ),
    );
    await tester.pumpAndSettle();
    autoScrollReasons.clear();

    await tester.pumpWidget(
      _buildHostWithMessages(
        settings: settings,
        messages: const <Message>[],
        transientMessages: <Message>[transientMessage],
        viewportController: viewportController,
        onDebugAutoScrollRequested: autoScrollReasons.add,
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    expect(autoScrollReasons, isEmpty);
    viewportController.dispose();
  });

  testWidgets('AI流式生成期间用户手势仍应能立即接管列表', (tester) async {
    final harnessKey = GlobalKey<_ChatListHarnessState>();

    await tester.pumpWidget(_buildHost(harnessKey));
    await tester.pumpAndSettle();

    final listFinder = find.byType(CustomScrollView);
    expect(listFinder, findsOneWidget);

    harnessKey.currentState!.appendAssistantStreamingMessage();
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(tester.getCenter(listFinder));
    harnessKey.currentState!.growAssistantStreamingChunkLarge();
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.moveBy(const Offset(0, 80));
    await tester.pump(const Duration(milliseconds: 16));
    harnessKey.currentState!.growAssistantStreamingChunkLarge();
    await gesture.moveBy(const Offset(0, 180));
    await tester.pump(const Duration(milliseconds: 16));

    expect(
      harnessKey.currentState!._viewportController.shouldFollowLatest,
      isFalse,
      reason: 'AI 正在流式生成时，用户手势一旦介入就应立即关闭自动回底',
    );

    var controller = tester.widget<CustomScrollView>(listFinder).controller!;
    var gapAfterTakeover = _distanceToBottom(controller);
    if (gapAfterTakeover <= 40) {
      await gesture.up();
      await tester.pump();
      await tester.drag(listFinder, const Offset(0, 320));
      await tester.pumpAndSettle();
      controller = tester.widget<CustomScrollView>(listFinder).controller!;
      gapAfterTakeover = _distanceToBottom(controller);
    } else {
      await gesture.up();
      await tester.pumpAndSettle();
    }
    expect(gapAfterTakeover, greaterThan(40));

    final gaps = <double>[gapAfterTakeover];
    for (var i = 0; i < 6; i++) {
      harnessKey.currentState!.growAssistantStreamingChunkLarge();
      await tester.pump(const Duration(milliseconds: 16));
      controller = tester.widget<CustomScrollView>(listFinder).controller!;
      gaps.add(_distanceToBottom(controller));
    }
    await tester.pumpAndSettle();

    for (final gap in gaps.skip(1)) {
      expect(
        gap,
        greaterThan(40),
        reason: '用户接管后，后续流式增量不应再把列表强行拽回到底部',
      );
    }
  });

  testWidgets('贴底状态下轻微手势接管后，旧消息不应继续被新消息向上顶走', (tester) async {
    final harnessKey = GlobalKey<_ChatListHarnessState>();

    await tester.pumpWidget(_buildHost(harnessKey));
    await tester.pumpAndSettle();

    final listFinder = find.byType(CustomScrollView);
    expect(listFinder, findsOneWidget);

    harnessKey.currentState!.appendAssistantStreamingMessage();
    await tester.pumpAndSettle();

    final anchorFinder = find.textContaining('第39条消息');
    expect(anchorFinder, findsWidgets);

    final gesture = await tester.startGesture(tester.getCenter(listFinder));
    await gesture.moveBy(const Offset(0, 12));
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      harnessKey.currentState!._viewportController.shouldFollowLatest,
      isFalse,
      reason: '轻微手势后也应立即进入阅读锁定态',
    );

    final dyBeforeGrowth = tester.getCenter(anchorFinder.first).dy;

    for (var i = 0; i < 4; i++) {
      harnessKey.currentState!.growAssistantStreamingChunkLarge();
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pumpAndSettle();

    final dyAfterGrowth = tester.getCenter(anchorFinder.first).dy;
    expect(
      (dyAfterGrowth - dyBeforeGrowth).abs(),
      lessThan(18.0),
      reason: '用户已接管时，尾消息继续增长不应把旧消息持续向上顶走',
    );
  });

  testWidgets('贴底状态下轻微手势接管后，新消息插入也不应推动当前视窗', (tester) async {
    final harnessKey = GlobalKey<_ChatListHarnessState>();

    await tester.pumpWidget(_buildHost(harnessKey));
    await tester.pumpAndSettle();

    final listFinder = find.byType(CustomScrollView);
    expect(listFinder, findsOneWidget);

    final anchorFinder = find.textContaining('第39条消息');
    expect(anchorFinder, findsWidgets);

    final gesture = await tester.startGesture(tester.getCenter(listFinder));
    await gesture.moveBy(const Offset(0, 12));
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      harnessKey.currentState!._viewportController.shouldFollowLatest,
      isFalse,
      reason: '轻微手势后也应立即进入阅读锁定态',
    );

    final dyBeforeInsert = tester.getCenter(anchorFinder.first).dy;
    harnessKey.currentState!.appendAssistantMessage();
    await tester.pump();
    await tester.pumpAndSettle();

    final dyAfterInsert = tester.getCenter(anchorFinder.first).dy;
    expect(
      (dyAfterInsert - dyBeforeInsert).abs(),
      lessThan(18.0),
      reason: '用户已接管时，新消息插入不应推动当前视窗里的旧消息',
    );
  });

  testWidgets('轻微手势脱离后，靠近底部也不应自动恢复贴底跟随', (tester) async {
    final harnessKey = GlobalKey<_ChatListHarnessState>();

    await tester.pumpWidget(_buildHost(harnessKey));
    await tester.pumpAndSettle();

    final listFinder = find.byType(CustomScrollView);
    expect(listFinder, findsOneWidget);

    final gesture = await tester.startGesture(tester.getCenter(listFinder));
    await gesture.moveBy(const Offset(0, 8));
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      harnessKey.currentState!._viewportController.shouldFollowLatest,
      isFalse,
      reason: '用户只要明确开始手势接管，就不应因为仍靠近底部而自动恢复贴底',
    );
    expect(
      find.byKey(const ValueKey<String>('chat_jump_to_latest_badge')),
      findsNothing,
    );

    harnessKey.currentState!.appendAssistantMessage();
    await tester.pump();
    await tester.pumpAndSettle();

    expect(
      harnessKey.currentState!._viewportController.shouldFollowLatest,
      isFalse,
      reason: '轻微手势脱离后，收到AI新消息也不应悄悄恢复自动跟随',
    );
    expect(
      find.byKey(const ValueKey<String>('chat_jump_to_latest_badge')),
      findsNothing,
      reason: '轻微脱离且仍靠近底部时，不应因为收到新消息就出现回到底部箭头',
    );
  });

  testWidgets('静止态下流式生成时，列表锚点应保持稳定', (tester) async {
    final harnessKey = GlobalKey<_ChatListHarnessState>();

    await tester.pumpWidget(_buildHost(harnessKey));
    await tester.pumpAndSettle();

    final listFinder = find.byType(CustomScrollView);
    expect(listFinder, findsOneWidget);

    await tester.drag(listFinder, const Offset(0, 320));
    await tester.pumpAndSettle();

    var controller = tester.widget<CustomScrollView>(listFinder).controller!;
    var gapAfterManual = _distanceToBottom(controller);
    if (gapAfterManual <= 40) {
      await tester.drag(listFinder, const Offset(0, -320));
      await tester.pumpAndSettle();
      controller = tester.widget<CustomScrollView>(listFinder).controller!;
      gapAfterManual = _distanceToBottom(controller);
    }
    expect(gapAfterManual, greaterThan(40));

    harnessKey.currentState!.appendAssistantStreamingMessage();
    await tester.pumpAndSettle();

    final gaps = <double>[];
    for (var i = 0; i < 12; i++) {
      harnessKey.currentState!.growAssistantStreamingChunk();
      await tester.pump(const Duration(milliseconds: 16));
      final controller =
          tester.widget<CustomScrollView>(listFinder).controller!;
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

  testWidgets('阅读中点击输入框后，输入框升高不应触发自动回底', (tester) async {
    final harnessKey = GlobalKey<_ChatListHarnessState>();
    final autoScrollReasons = <String>[];

    await tester.pumpWidget(
      _buildHost(
        harnessKey,
        onDebugAutoScrollRequested: autoScrollReasons.add,
      ),
    );
    await tester.pumpAndSettle();

    final listFinder = find.byType(CustomScrollView);
    expect(listFinder, findsOneWidget);

    await tester.drag(listFinder, const Offset(0, 320));
    await tester.pumpAndSettle();

    var controller = tester.widget<CustomScrollView>(listFinder).controller!;
    expect(_distanceToBottom(controller), greaterThan(40));

    harnessKey.currentState!.resumeAutoScrollFromInputTap();
    await tester.pump();
    await tester.pumpAndSettle();

    controller = tester.widget<CustomScrollView>(listFinder).controller!;
    var gapBeforeOverlay = _distanceToBottom(controller);
    expect(gapBeforeOverlay, greaterThan(40));
    autoScrollReasons.clear();

    harnessKey.currentState!.setBottomOverlayHeight(260);
    await tester.pump();
    await tester.pumpAndSettle();

    controller = tester.widget<CustomScrollView>(listFinder).controller!;
    final gapAfterOverlay = _distanceToBottom(controller);
    expect(gapAfterOverlay, greaterThan(40));
    expect(
      autoScrollReasons,
      isEmpty,
      reason: '阅读态下输入区高度变化不应触发自动回底请求',
    );
    expect(
      harnessKey.currentState!._viewportController.shouldFollowLatest,
      isFalse,
      reason: '阅读态下输入区升高后，列表仍应保持手势接管状态',
    );
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

    final listFinder = find.byType(CustomScrollView);
    expect(listFinder, findsOneWidget);

    await tester.drag(listFinder, const Offset(0, 4000));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(harnessKey.currentState!.loadMoreCallCount, 1);
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.byKey(const ValueKey<String>('history_loading_overlay')),
        findsOneWidget);

    var controller = tester.widget<CustomScrollView>(listFinder).controller!;
    final gapWhileLoading = _distanceToBottom(controller);
    final offsetWhileLoading = controller.offset;
    final distanceToTopWhileLoading =
        (controller.position.maxScrollExtent - controller.offset).abs();
    expect(gapWhileLoading, greaterThan(40));
    expect(
      distanceToTopWhileLoading,
      lessThanOrEqualTo(24),
      reason: '出现 loading overlay 后应只做轻微回弹，并停在历史顶部边界附近等待',
    );

    harnessKey.currentState!.completeLoadMore(count: 20);
    await tester.pump();
    await tester.pumpAndSettle();

    controller = tester.widget<CustomScrollView>(listFinder).controller!;
    final distanceToTopAfterLoad =
        (controller.position.maxScrollExtent - controller.offset).abs();
    expect(_distanceToBottom(controller), greaterThan(40));
    expect(find.byKey(const ValueKey<String>('history_loading_overlay')),
        findsNothing);
    expect(
      controller.offset,
      closeTo(offsetWhileLoading, 1),
      reason: '历史分页完成后应保持当前阅读位置，不应自动把视口继续推向更早消息',
    );
    expect(
      distanceToTopAfterLoad,
      greaterThan(distanceToTopWhileLoading + 40),
      reason: '分页完成后只移除 loading overlay，更早消息应继续留在上方等待用户手动上滑',
    );
  });

  testWidgets('短历史窗口在上滑过冲时也应触发加载更多', (tester) async {
    final settings = _buildSettings().copyWith(
      messageChunkingEnabled: false,
      messageFormatConfig: const MessageFormatConfig(enableChunking: false),
    );
    final baseTime = DateTime(2026, 1, 1, 12, 0, 0);
    final compactMessages = List<Message>.generate(5, (index) {
      final role = index.isEven ? 'assistant' : 'user';
      return Message.text(
        id: 'compact_$index',
        role: role,
        content: '短消息$index',
        createdAt: baseTime.add(Duration(minutes: index)),
        status: 'sent',
      );
    });
    var loadMoreCallCount = 0;
    final loadMoreCompleter = Completer<void>();

    await tester.pumpWidget(
      _buildHostWithMessages(
        settings: settings,
        messages: compactMessages,
        hasMoreMessages: true,
        onLoadMore: () async {
          loadMoreCallCount += 1;
          return loadMoreCompleter.future;
        },
      ),
    );
    await tester.pumpAndSettle();

    final listFinder = find.byType(CustomScrollView);
    expect(listFinder, findsOneWidget);
    final controller = tester.widget<CustomScrollView>(listFinder).controller!;
    expect(
      controller.position.maxScrollExtent,
      lessThanOrEqualTo(200),
      reason: '复现前提：5 条短消息不足以触发原来的 200 像素阈值',
    );

    await tester.drag(listFinder, const Offset(0, 320));
    await tester.pump();

    expect(loadMoreCallCount, 1);
  });

  testWidgets('短历史分页完成后不应回到底部', (tester) async {
    final harnessKey = GlobalKey<_PagingChatListHarnessState>();
    final autoScrollReasons = <String>[];

    await tester.pumpWidget(
      _buildPagingHost(
        harnessKey,
        onDebugAutoScrollRequested: autoScrollReasons.add,
        initialMessages: _buildCompactMessages(startIndex: 20, count: 5),
        messageBuilder: (messageIndex, createdAt) {
          final role = messageIndex.isEven ? 'assistant' : 'user';
          return Message.text(
            id: 'm_$messageIndex',
            role: role,
            content: '短消息$messageIndex',
            createdAt: createdAt,
            status: 'sent',
          );
        },
      ),
    );
    await tester.pumpAndSettle();
    autoScrollReasons.clear();

    final listFinder = find.byType(CustomScrollView);
    expect(listFinder, findsOneWidget);
    final initialController =
        tester.widget<CustomScrollView>(listFinder).controller!;
    expect(initialController.position.maxScrollExtent, lessThanOrEqualTo(200));

    await tester.drag(listFinder, const Offset(0, 320));
    await tester.pump();

    expect(harnessKey.currentState!.loadMoreCallCount, 1);

    harnessKey.currentState!.completeLoadMore();
    await tester.pump();
    await tester.pumpAndSettle();

    final controller = tester.widget<CustomScrollView>(listFinder).controller!;
    expect(
      _distanceToBottom(controller),
      greaterThan(40),
      reason: '历史分页补齐后，视口应继续停留在历史侧而不是回到底部',
    );
    expect(autoScrollReasons, isEmpty);
  });

  testWidgets('历史分页即使先释放加载锁，补历史后也不应回到底部', (tester) async {
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

    final listFinder = find.byType(CustomScrollView);
    expect(listFinder, findsOneWidget);

    await tester.drag(listFinder, const Offset(0, 4000));
    await tester.pump();

    expect(harnessKey.currentState!.loadMoreCallCount, 1);

    harnessKey.currentState!.releaseLoadingBeforeMessages();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 160));

    harnessKey.currentState!.appendOlderMessages();
    await tester.pump();
    await tester.pumpAndSettle();

    final controller = tester.widget<CustomScrollView>(listFinder).controller!;
    expect(
      _distanceToBottom(controller),
      greaterThan(40),
      reason: '即使页面层先结束 loading，再补进历史消息时也不应把视口拉回到底部',
    );
    expect(autoScrollReasons, isEmpty);
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

  testWidgets('历史 prepend 与尾消息归档同帧到达时，不应误判成 tailChanged 回底', (tester) async {
    final settings = _buildSettings();
    final autoScrollReasons = <String>[];
    final viewportController = ChatViewportController();
    final baseMessages = _buildInitialMessages(40).sublist(20);
    final expandedMessages = List<Message>.from(
      _buildInitialMessages(40).sublist(15),
    );
    final tail = expandedMessages.last;
    expandedMessages[expandedMessages.length - 1] = _replaceMessageText(
      tail,
      '${tail.displayText} · 数据库归档同步',
      status: 'sent',
    );

    await tester.pumpWidget(
      _buildHostWithMessages(
        settings: settings,
        messages: baseMessages,
        chatListKey: const ValueKey<String>('history_prepend_tail_sync'),
        viewportController: viewportController,
        onDebugAutoScrollRequested: autoScrollReasons.add,
      ),
    );
    await tester.pumpAndSettle();
    autoScrollReasons.clear();

    await tester.pumpWidget(
      _buildHostWithMessages(
        settings: settings,
        messages: expandedMessages,
        chatListKey: const ValueKey<String>('history_prepend_tail_sync'),
        viewportController: viewportController,
        onDebugAutoScrollRequested: autoScrollReasons.add,
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    expect(
      autoScrollReasons.where((reason) => reason == 'tailChanged'),
      isEmpty,
      reason: '同一帧如果主要变化是 prepend 历史，就不应把尾消息同步误判成需要回到底部',
    );
    expect(tester.takeException(), isNull);
    viewportController.dispose();
  });

  testWidgets('历史分页若同帧完成并伴随尾消息归档，也不应误触发回底', (tester) async {
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

    final listFinder = find.byType(CustomScrollView);
    expect(listFinder, findsOneWidget);

    await tester.drag(listFinder, const Offset(0, 4000));

    expect(
      harnessKey.currentState!.loadMoreCallCount,
      1,
      reason: '真实上滑到历史侧后，应立即触发一次分页加载请求',
    );

    harnessKey.currentState!.completeLoadMoreWithTailMutation();
    await tester.pump();
    await tester.pumpAndSettle();

    final updatedController =
        tester.widget<CustomScrollView>(listFinder).controller!;
    expect(
      _distanceToBottom(updatedController),
      greaterThan(40),
      reason: '即使分页与尾消息归档在同帧抵达，也应继续保留当前历史阅读位置',
    );
    expect(
      autoScrollReasons,
      isEmpty,
      reason: '分页补历史不应因为尾消息同步而误判成需要自动回底',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('历史分页瞬时空窗口不应清空列表或触发回底请求', (tester) async {
    final harnessKey = GlobalKey<_PagingChatListHarnessState>();
    final autoScrollReasons = <String>[];
    var latestItemCount = -1;

    await tester.pumpWidget(
      _buildPagingHost(
        harnessKey,
        initialMessages: _buildInitialMessages(60),
        onDebugAutoScrollRequested: autoScrollReasons.add,
        onDebugListItemCountChanged: (count) => latestItemCount = count,
      ),
    );
    await tester.pumpAndSettle();
    for (var index = 0; index < 20 && latestItemCount <= 0; index++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

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

  testWidgets('历史分页若先结束 loading 再出现空窗口，补历史后也不应回到底部', (tester) async {
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

    final listFinder = find.byType(CustomScrollView);
    expect(listFinder, findsOneWidget);

    await tester.drag(listFinder, const Offset(0, 4000));
    await tester.pump();
    expect(harnessKey.currentState!.loadMoreCallCount, 1);
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump(const Duration(milliseconds: 120));
    final baselineController =
        tester.widget<CustomScrollView>(listFinder).controller!;
    final offsetBeforeRecovery = baselineController.offset;
    final distanceToTopBeforeRecovery =
        (baselineController.position.maxScrollExtent -
                baselineController.offset)
            .abs();

    harnessKey.currentState!.releaseLoadingBeforeMessages();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 160));

    harnessKey.currentState!.beginTransientEmptyWindowAfterLoadingReleased();
    await tester.pump();

    harnessKey.currentState!.endTransientEmptyWindowAfterLoadingReleased();
    await tester.pump();
    await tester.pumpAndSettle();

    final controller = tester.widget<CustomScrollView>(listFinder).controller!;
    final distanceToTopAfterRecovery =
        (controller.position.maxScrollExtent - controller.offset).abs();
    expect(
      _distanceToBottom(controller),
      greaterThan(40),
      reason: '即使 loading 先结束又出现瞬时空窗口，历史补齐后也应继续停留在历史阅读位置',
    );
    expect(
      controller.offset,
      closeTo(offsetBeforeRecovery, 1),
      reason: '空窗口恢复后也应保持原位置，不应自动继续上翻',
    );
    expect(
      distanceToTopAfterRecovery,
      greaterThan(distanceToTopBeforeRecovery + 40),
      reason: '空窗口恢复后只搬开 loading，更早消息应继续留给用户手动上滑',
    );
    expect(
      autoScrollReasons,
      isEmpty,
      reason: '空窗口补历史链路不应触发任何回底请求',
    );
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

    final listFinder = find.byType(CustomScrollView);
    expect(listFinder, findsOneWidget);

    await tester.drag(listFinder, const Offset(0, 4000));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(harnessKey.currentState!.loadMoreCallCount, 1);

    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump(const Duration(milliseconds: 120));
    expect(tester.takeException(), isNull);

    final controller = tester.widget<CustomScrollView>(listFinder).controller!;
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
