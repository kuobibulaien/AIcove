import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/chat/application/chat_page_send_support.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/conversation_timeline_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/conversation_short_window_store.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/contacts_list_content.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/ui/features/chat/pages/chat_page.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/animated_message_item.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/message_bubble.dart';
import 'package:aicove_flutter/src/ui/features/home/pages/contacts_page.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/settings_drawer_wrapper.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';

class _RecordingTimelineCache extends ConversationTimelineCache {
  _RecordingTimelineCache(super.ref);

  final reads = <String>[];
  final windows = <String, ConversationTimelineWindowState>{};

  @override
  ConversationTimelineWindowState? peekWindow({
    required String conversationId,
    required int limit,
  }) =>
      windows[conversationId];

  @override
  Stream<ConversationTimelineWindowState> watchWindow({
    required String conversationId,
    required int limit,
  }) {
    reads.add(conversationId);
    return Stream.value(const ConversationTimelineWindowState(
      messages: [],
      hasMoreMessages: false,
    ));
  }
}

class _FakeConversationsNotifier extends ConversationsNotifier {
  _FakeConversationsNotifier(this._conversations);

  final List<Conversation> _conversations;

  @override
  Future<List<Conversation>> build() async => _conversations;
}

class _FakeAppSettingsNotifier extends AppSettingsNotifier {
  _FakeAppSettingsNotifier(this._settings);

  final AppSettings _settings;

  @override
  Future<AppSettings> build() async => _settings;
}

class _AlwaysAllowChatPageSendSupport extends ChatPageSendSupport {
  _AlwaysAllowChatPageSendSupport(super.ref);

  @override
  Future<ChatPageVisionCompatibilityDecision> resolveVisionCompatibility({
    required Conversation conversation,
    bool currentMessageHasImage = false,
  }) async {
    return const ChatPageVisionCompatibilityDecision.allow();
  }
}

AppSettings _buildTestSettings() {
  const defaultModelRef = 'openai:gpt-4o-mini';
  return AppSettings(
    ttsEnabled: true,
    defaultModelName: defaultModelRef,
    defaultPersonaPrompt: '',
    modelList: const <String>[defaultModelRef],
    allKnownModels: const <String>[defaultModelRef],
    modelDisplayNames: const <String, String>{},
    modelTypes: const <String, String>{},
    modelConfigs: const <String, ModelConfig>{},
    apiKey: '',
    apiBaseUrl: 'https://api.openai.com/v1',
    imageGenerationEnabled: false,
    maxFileUploadMB: 10,
    contextWindowTokens: 272000,
    customModels: const <CustomModel>[],
    providers: const <ProviderAuth>[
      ProviderAuth(
        id: 'openai',
        apiKeys: <String>['test-key'],
        apiBaseUrl: 'https://api.openai.com/v1',
      ),
    ],
    modelProviderMap: const <String, String>{
      defaultModelRef: 'openai',
      'gpt-4o-mini': 'openai',
    },
    backendApiKey: '',
    messageChunkingEnabled: true,
    messageFormatConfig: const MessageFormatConfig(),
    textScaleFactor: 1.0,
    uiScaleFactor: 1.0,
    imagePreviewScale: 1.0,
    autoReplySettings: const AutoReplySettings(),
    globalBackgroundColor: GlobalBackgroundColor.white,
    chatBackgroundColor: ChatBackgroundColor.defaultColor,
    isDarkMode: false,
    useSystemTheme: true,
    accentColor: 'FC96AA',
    hideUserAvatar: true,
    defaultChatModels: const <String>[defaultModelRef],
    streamSegmentDelaySeconds: 0,
  );
}

GoRouter _buildRouter(Conversation conversation) {
  return GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => SettingsDrawerWrapper(
          settingsBuilder: (_) => const SizedBox.shrink(),
          child: const ContactsPage(),
        ),
        routes: [
          GoRoute(
            path: 'chat/:id',
            builder: (context, state) => ChatPage(
              conversationId: state.pathParameters['id'],
              initialConversation: state.extra is Conversation
                  ? state.extra as Conversation
                  : conversation,
            ),
          ),
        ],
      ),
    ],
  );
}

Future<void> _pumpRouteTransition(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('带 #top 标记的头像预热 provider 会清理资源路径', () {
    final now = DateTime(2026, 3, 19);
    final conversation = Conversation(
      id: 'preset_nahida',
      title: '纳西妲',
      displayName: '纳西妲',
      avatarUrl: 'assets/characters/images/nahida.jpg#top',
      createdAt: now,
      updatedAt: now,
    );

    final provider = buildConversationAvatarProvider(conversation);

    expect(provider, isA<AssetImage>());
    expect((provider! as AssetImage).assetName,
        'assets/characters/images/nahida.jpg');
  });

  testWidgets('联系人点击预热会延后到下一帧之后再执行', (tester) async {
    late BuildContext context;
    var called = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) {
            context = ctx;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    scheduleConversationTapWarmup(
      context,
      () => called = true,
      delay: const Duration(milliseconds: 80),
    );

    expect(called, isFalse);

    await tester.pump();
    expect(called, isFalse);

    await tester.pump(const Duration(milliseconds: 79));
    expect(called, isFalse);

    await tester.pump(const Duration(milliseconds: 1));
    expect(called, isTrue);
  });

  testWidgets('联系人点击预热被取消后不再执行', (tester) async {
    late BuildContext context;
    var called = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) {
            context = ctx;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    final cancel = scheduleConversationTapWarmup(
      context,
      () => called = true,
      delay: const Duration(milliseconds: 80),
    );

    cancel();

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));

    expect(called, isFalse);
  });

  testWidgets('联系人显示后预读最近三场会话，不用等点击且不会全量预读', (tester) async {
    final now = DateTime(2026, 9, 5);
    final conversations = List.generate(
        8,
        (i) => Conversation(
              id: 'recent_$i',
              title: '联系人 $i',
              displayName: '联系人 $i',
              createdAt: now,
              updatedAt: now.add(Duration(minutes: i)),
            ));
    late _RecordingTimelineCache cache;
    final container = ProviderContainer(overrides: [
      conversationsProvider.overrideWith(
        () => _FakeConversationsNotifier(conversations),
      ),
      conversationTimelineCacheProvider.overrideWith((ref) {
        cache = _RecordingTimelineCache(ref);
        return cache;
      }),
    ]);
    addTearDown(container.dispose);
    container.read(conversationTimelineCacheProvider);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: ThemeData(extensions: [MoeColors.light()]),
        home: const Scaffold(body: ContactsListContent()),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    expect(cache.reads, ['recent_7', 'recent_6', 'recent_5']);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('聊天路由覆盖联系人页时不预读其他历史，返回后仍可预读', (tester) async {
    final now = DateTime(2026, 9, 6);
    final conversations = [
      Conversation(
          id: 'hidden',
          title: 'hidden',
          displayName: 'hidden',
          createdAt: now,
          updatedAt: now)
    ];
    late _RecordingTimelineCache cache;
    final container = ProviderContainer(overrides: [
      conversationsProvider
          .overrideWith(() => _FakeConversationsNotifier(conversations)),
      conversationTimelineCacheProvider
          .overrideWith((ref) => cache = _RecordingTimelineCache(ref)),
    ]);
    addTearDown(container.dispose);
    container.read(conversationTimelineCacheProvider);
    final router = GoRouter(initialLocation: '/', routes: [
      GoRoute(
          path: '/',
          pageBuilder: (_, state) => CupertinoPage<void>(
              key: state.pageKey,
              child: const Scaffold(body: ContactsListContent())),
          routes: [
            GoRoute(
                path: 'chat',
                pageBuilder: (_, state) => CupertinoPage<void>(
                    key: state.pageKey,
                    child: const Scaffold(body: Text('聊天')))),
          ]),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        theme: ThemeData(extensions: [MoeColors.light()]),
      ),
    ));
    // 联系人异步首值已返回但尚未绘制，先进入聊天；根路由仍在转场中挂载。
    router.go('/chat');
    await tester.pumpAndSettle();
    final hiddenReads = List.of(cache.reads);
    router.pop();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 16));
    final returnedReads = List.of(cache.reads);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(hiddenReads, isEmpty, reason: '不可见的联系人页不能抢前台冷加载的数据库连接');
    expect(returnedReads, ['hidden']);
  });

  for (final width in <double>[360, 1000]) {
    for (final preloaded in [false, true]) {
      testWidgets('首批历史直接显示且首帧停在最后一条 AI 消息底部：$width，预读=$preloaded',
          (tester) async {
        tester.view.physicalSize = Size(width, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final now = DateTime(2026, 4, 3, 10);
        final conversation = Conversation(
          id: 'cold_entry_$width',
          title: '历史会话',
          displayName: '历史会话',
          createdAt: now,
          updatedAt: now,
        );
        final history = List<Message>.generate(
            20,
            (index) => Message.text(
                  id: 'history_$index',
                  role: index.isEven ? 'user' : 'assistant',
                  content: index == 19
                      ? '${List.filled(90, '长回复内容用于验证末尾位置').join('，')}\n最后一句'
                      : '历史消息 $index',
                  createdAt: now.add(Duration(minutes: index)),
                  status: 'sent',
                ));
        final source = StateProvider<AsyncValue<List<Message>>>(
          (ref) => const AsyncLoading(),
        );
        final container = ProviderContainer(overrides: [
          conversationTimelineCacheProvider.overrideWith((ref) {
            final cache = _RecordingTimelineCache(ref);
            if (preloaded) {
              cache.windows[conversation.id] = ConversationTimelineWindowState(
                messages: history,
                hasMoreMessages: true,
              );
            }
            return cache;
          }),
          conversationsProvider.overrideWith(
            () => _FakeConversationsNotifier([conversation]),
          ),
          appSettingsProvider.overrideWith(
            () => _FakeAppSettingsNotifier(_buildTestSettings()),
          ),
          resolvedConversationByIdProvider(conversation.id)
              .overrideWith((ref) => conversation),
          conversationMessagesProvider(conversation.id)
              .overrideWith((ref) => ref.watch(source)),
          conversationHasMoreProvider(conversation.id)
              .overrideWith((ref) => true),
        ]);
        addTearDown(container.dispose);
        await tester.pumpWidget(UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: ThemeData(extensions: [MoeColors.light()]),
            home: ChatPage(
              conversationId: conversation.id,
              initialConversation: conversation,
            ),
          ),
        ));
        if (!preloaded) {
          await tester.pump(const Duration(milliseconds: 350));
          expect(tester.takeException(), isNull);
          container.read(source.notifier).state = AsyncData(history);
          await tester.pump();
        }
        expect(
          find.byType(AnimatedMessageItem, skipOffstage: false),
          findsNothing,
          reason: '首批历史不是新收到的消息，不应从零高逐条展开',
        );
        final tail = find
            .byWidgetPredicate(
              (widget) =>
                  widget is MessageBubble &&
                  widget.message.displayText.contains('最后一句'),
              skipOffstage: false,
            )
            .last;
        expect(tail, findsOneWidget);
        final scrollView = find.byType(CustomScrollView).first;
        final tailBottom = tester.getBottomLeft(tail).dy;
        final viewportBottom = tester.getBottomLeft(scrollView).dy;
        expect(tailBottom, lessThanOrEqualTo(viewportBottom));
        expect(tailBottom, greaterThan(viewportBottom - 180),
            reason: '必须检查首帧渲染位置，而非帧后已经更新的滚动数值');
        await tester.pump(const Duration(milliseconds: 500));
        final controller =
            tester.widget<CustomScrollView>(scrollView).controller!;
        expect(controller.position.pixels - controller.position.minScrollExtent,
            closeTo(0, 0.5));
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('联系人点击后可以稳定进入聊天页且不抛框架异常', (tester) async {
    final now = DateTime(2026, 4, 3, 10, 0);
    final conversation = Conversation(
      id: 'conv_entry',
      title: '测试会话',
      displayName: '测试会话',
      createdAt: now,
      updatedAt: now,
    );
    final container = ProviderContainer(
      overrides: [
        conversationTimelineCacheProvider.overrideWith(
          (ref) => _RecordingTimelineCache(ref),
        ),
        conversationsProvider.overrideWith(
          () => _FakeConversationsNotifier(<Conversation>[conversation]),
        ),
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(_buildTestSettings()),
        ),
        chatPageSendSupportProvider.overrideWith(
          (ref) => _AlwaysAllowChatPageSendSupport(ref),
        ),
        resolvedConversationByIdProvider(conversation.id)
            .overrideWith((ref) => conversation),
        conversationMessagesProvider(conversation.id).overrideWith(
          (ref) => const AsyncValue.data(<Message>[]),
        ),
        conversationHasMoreProvider(conversation.id).overrideWith(
          (ref) => false,
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: _buildRouter(conversation),
          theme: ThemeData(
            extensions: <ThemeExtension<dynamic>>[
              MoeColors.light(),
            ],
          ),
        ),
      ),
    );
    await _pumpRouteTransition(tester);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('测试会话').first);
    await _pumpRouteTransition(tester);

    expect(tester.takeException(), isNull);
    expect(container.read(activeConversationIdProvider), conversation.id);
    expect(find.byType(ChatPage), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
