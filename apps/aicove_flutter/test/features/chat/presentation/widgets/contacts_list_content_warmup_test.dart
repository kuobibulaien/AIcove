import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/chat/application/chat_page_send_support.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/conversation_timeline_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/contacts_list_content.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/ui/features/chat/pages/chat_page.dart';
import 'package:aicove_flutter/src/ui/features/home/pages/contacts_page.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/settings_drawer_wrapper.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';

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
    historyMessageLimit: 100,
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
