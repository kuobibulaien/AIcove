import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/chat/application/chat_view_prefs.dart';
import 'package:aicove_flutter/src/features/chat/chat_actions.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/domain/role_agent_mode.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/composer.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/message_bubble.dart';
import 'package:aicove_flutter/src/features/dialogue_options/application/dialogue_options_providers.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/ui/theme/skin_provider.dart';
import 'package:aicove_flutter/src/ui/theme/skins/moetalk_skin.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';

class _FakeAppSettingsNotifier extends AppSettingsNotifier {
  _FakeAppSettingsNotifier(this._settings);

  final AppSettings _settings;

  @override
  Future<AppSettings> build() async => _settings;
}

AppSettings _buildSettings({bool allowMultiMessageSend = false}) {
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
    providers: const <ProviderAuth>[],
    modelProviderMap: const <String, String>{},
    backendApiKey: '',
    messageChunkingEnabled: false,
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
    allowMultiMessageSend: allowMultiMessageSend,
  );
}

Conversation _buildConversation(String id) {
  final now = DateTime(2026, 3, 24, 10, 0, 0);
  return Conversation(
    id: id,
    agentMode: RoleAgentMode.chat,
    title: '纳西妲',
    displayName: '纳西妲',
    createdAt: now,
    updatedAt: now,
    lastMessageTime: now,
  );
}

const _convId = 'conv_multi_send';
const _writePreview = bool.fromEnvironment('WRITE_MULTI_SEND_PREVIEW');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    if (!_writePreview) return;
    for (final entry in {
      'Preview': '/System/Library/Fonts/STHeiti Medium.ttc',
      'MaterialIcons':
          '${Platform.environment['HOME']}/dev-sdks/flutter-3.44.6/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    }.entries) {
      final file = File(entry.value);
      if (!file.existsSync()) continue;
      final loader = FontLoader(entry.key);
      loader.addFont(file.readAsBytes().then(ByteData.sublistView));
      await loader.load();
    }
  });

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('输入状态下软键盘提交和点发送按钮后保持焦点不收起', (tester) async {
    final sent = <String>[];
    final conversation = _buildConversation(_convId);
    final container = ProviderContainer(
      overrides: [
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(_buildSettings()),
        ),
        activeConversationProvider.overrideWith((ref) => conversation),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: SkinScope(
          skin: const MoeTalkSkin(),
          child: MaterialApp(
            theme: ThemeData(extensions: [MoeColors.light()]),
            home: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: Composer(
                  onSend: (text) async => sent.add(text),
                  onSubmitText: (text) {
                    sent.add(text);
                    return true;
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(TextField));
    await tester.pump();
    final editable = tester.widget<EditableText>(find.byType(EditableText));
    expect(editable.focusNode.hasFocus, isTrue);

    // 1. 软键盘回车提交（以往默认 onEditingComplete 会触发失焦收起）
    await tester.enterText(find.byType(TextField), '第一条消息');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(sent, ['第一条消息']);
    expect(editable.controller.text, isEmpty);
    expect(editable.focusNode.hasFocus, isTrue);

    // 2. 点击发送按钮提交
    await tester.enterText(find.byType(TextField), '接着发第二条');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();

    expect(sent, ['第一条消息', '接着发第二条']);
    expect(editable.controller.text, isEmpty);
    expect(editable.focusNode.hasFocus, isTrue);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('选中辅助生成回答填入输入框时不唤起键盘，不点编辑可直接发送', (
    tester,
  ) async {
    final sent = <String>[];
    final conversation = _buildConversation(_convId);
    final container = ProviderContainer(
      overrides: [
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(_buildSettings()),
        ),
        activeConversationProvider.overrideWith((ref) => conversation),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: SkinScope(
          skin: const MoeTalkSkin(),
          child: MaterialApp(
            theme: ThemeData(extensions: [MoeColors.light()]),
            home: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: Composer(
                  onSend: (text) async => sent.add(text),
                  onSubmitText: (text) {
                    sent.add(text);
                    return true;
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final editable = tester.widget<EditableText>(find.byType(EditableText));
    expect(editable.focusNode.hasFocus, isFalse);
    tester.testTextInput.log.clear();

    // 1. 选中辅助生成的回答：只填入底部输入框，不夺取焦点、不弹键盘
    container.read(dialogueOptionPickProvider(_convId).notifier).state =
        const DialogueOptionPick(text: '好呀，那我们出发吧', signature: 'sig_1');
    await tester.pumpAndSettle();

    expect(editable.controller.text, '好呀，那我们出发吧');
    expect(editable.focusNode.hasFocus, isFalse);
    expect(tester.testTextInput.isVisible, isFalse);
    expect(
      tester.testTextInput.log.where((call) => call.method == 'TextInput.show'),
      isEmpty,
    );

    // 2. 用户不点编辑、直接点发送：消息发出且键盘依然保持收起
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();

    expect(sent, ['好呀，那我们出发吧']);
    expect(editable.controller.text, isEmpty);
    expect(editable.focusNode.hasFocus, isFalse);
    expect(tester.testTextInput.isVisible, isFalse);

    // 3. 若用户主动点击输入框编辑，则正常唤起键盘
    container.read(dialogueOptionPickProvider(_convId).notifier).state =
        const DialogueOptionPick(text: '再等一下下', signature: 'sig_2');
    await tester.pumpAndSettle();
    expect(editable.focusNode.hasFocus, isFalse);

    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(editable.focusNode.hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('开启单次发多条时，点发送先暂存并出现上方确认小气泡，点确认完成发送',
      (tester) async {
    var confirmedCount = 0;
    final conversation = _buildConversation(_convId);
    final container = ProviderContainer(
      overrides: [
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(
            _buildSettings(allowMultiMessageSend: true),
          ),
        ),
        activeConversationProvider.overrideWith((ref) => conversation),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: SkinScope(
          skin: const MoeTalkSkin(),
          child: MaterialApp(
            theme: ThemeData(extensions: [MoeColors.light()]),
            home: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: Composer(
                  onSend: (_) async {},
                  onSubmitText: (text) {
                    container
                        .read(chatActionsProvider)
                        .stageComposerText(text, convId: _convId);
                    return true;
                  },
                  onConfirmStagedSend: () {
                    confirmedCount++;
                    container
                        .read(stagedUserMessagesProvider(_convId).notifier)
                        .state = const <Message>[];
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('composer_confirm_staged_button')),
      findsNothing,
    );

    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '今天遇到一件趣事');
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();

    expect(
      container.read(stagedUserMessagesProvider(_convId)).map((m) => m.content),
      ['今天遇到一件趣事'],
    );
    expect(
      find.byKey(const ValueKey('composer_confirm_staged_button')),
      findsOneWidget,
    );
    expect(find.text('确认发送'), findsOneWidget);

    // 确认小气泡位于发送按钮正上方
    final confirmRect = tester.getRect(
      find.byKey(const ValueKey('composer_confirm_staged_button')),
    );
    final sendRect = tester.getRect(find.byTooltip('发送'));
    expect(confirmRect.bottom, lessThanOrEqualTo(sendRect.top));

    // 继续暂存第二条，焦点始终保持
    final editable = tester.widget<EditableText>(find.byType(EditableText));
    expect(editable.focusNode.hasFocus, isTrue);
    await tester.enterText(find.byType(TextField), '路上看到一只超可爱的三花猫');
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();

    expect(
      container.read(stagedUserMessagesProvider(_convId)).map((m) => m.content),
      ['今天遇到一件趣事', '路上看到一只超可爱的三花猫'],
    );

    // 点击确认发送小气泡
    await tester.tap(
      find.byKey(const ValueKey('composer_confirm_staged_button')),
    );
    await tester.pumpAndSettle();

    expect(confirmedCount, 1);
    expect(
      find.byKey(const ValueKey('composer_confirm_staged_button')),
      findsNothing,
    );
    expect(editable.focusNode.hasFocus, isTrue);
  });

  testWidgets('暂存气泡支持编辑放回输入框、单条删除，且非发送中状态', (tester) async {
    final conversation = _buildConversation(_convId);
    final container = ProviderContainer(
      overrides: [
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(
            _buildSettings(allowMultiMessageSend: true),
          ),
        ),
        activeConversationProvider.overrideWith((ref) => conversation),
      ],
    );
    addTearDown(container.dispose);

    final actions = container.read(chatActionsProvider);
    actions.stageComposerText('第一句暂存', convId: _convId);
    actions.stageComposerText('第二句暂存', convId: _convId);

    final staged = container.read(stagedUserMessagesProvider(_convId));
    expect(staged, hasLength(2));
    // 暂存气泡状态为 staged 而非 sending，允许前端长按删除或多选
    expect(staged[0].status, 'staged');
    expect(staged[1].status, 'staged');

    // 对暂存气泡点「编辑」：从暂存队列移除并把文字放回 editingTextProvider
    final restoredText = await actions.editMessage(staged[0].id);
    expect(restoredText, '第一句暂存');
    expect(container.read(editingTextProvider), '第一句暂存');
    expect(
      container.read(stagedUserMessagesProvider(_convId)).map((m) => m.id),
      [staged[1].id],
    );

    // 引用第二条暂存气泡后删除它：引用同步清空
    container.read(quotedMessageProvider.notifier).state = QuotedMessage(
      id: staged[1].id,
      content: staged[1].content,
      isUser: true,
    );
    await actions.deleteMessage(staged[1].id);
    expect(container.read(stagedUserMessagesProvider(_convId)), isEmpty);
    expect(container.read(quotedMessageProvider), isNull);
  });

  testWidgets('preview chat-staged-confirm', (tester) async {
    if (!_writePreview) return;
    tester.view.physicalSize = const Size(390, 560) * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final conversation = _buildConversation(_convId);
    final container = ProviderContainer(
      overrides: [
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(
            _buildSettings(allowMultiMessageSend: true),
          ),
        ),
        activeConversationProvider.overrideWith((ref) => conversation),
      ],
    );
    addTearDown(container.dispose);

    final now = DateTime(2026, 10, 26, 14, 20);
    final assistantMsg = Message(
      id: 'm_1',
      role: 'assistant',
      content: '今天出门散步感觉怎么样呀？我在家里泡好热茶等你回来聊～',
      createdAt: now,
    );
    final staged1 = Message(
      id: 'm_2',
      role: 'user',
      content: '刚走到街角，遇到一件特别好玩的事！',
      createdAt: now.add(const Duration(minutes: 1)),
    );
    final staged2 = Message(
      id: 'm_3',
      role: 'user',
      content: '有一只小三花猫主动蹭了我的裤脚，还跟着我走了半条街',
      createdAt: now.add(const Duration(minutes: 1, seconds: 5)),
    );
    container.read(stagedUserMessagesProvider(_convId).notifier).state = [
      staged1,
      staged2,
    ];

    final captureKey = GlobalKey();
    final settings = _buildSettings(allowMultiMessageSend: true);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: SkinScope(
          skin: const MoeTalkSkin(),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              fontFamily: 'Preview',
              extensions: [MoeColors.light()],
            ),
            home: RepaintBoundary(
              key: captureKey,
              child: Scaffold(
                backgroundColor: const Color(0xFFF6F2F4),
                body: ChatViewScope(
                  prefs: ChatViewPrefs.resolve(conversation, settings),
                  child: Column(
                    children: [
                      Expanded(
                        child: ListView(
                          padding: const EdgeInsets.fromLTRB(8, 24, 8, 12),
                          children: [
                            MessageBubble(
                              message: assistantMsg,
                              isMe: false,
                              displayName: '纳西妲',
                            ),
                            MessageBubble(
                              message: staged1,
                              isMe: true,
                              displayName: '纳西妲',
                            ),
                            MessageBubble(
                              message: staged2,
                              isMe: true,
                              displayName: '纳西妲',
                            ),
                          ],
                        ),
                      ),
                      Composer(
                        onSend: (_) async {},
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), '我还拍了照片给你看');
    await tester.pumpAndSettle();

    await tester.runAsync(() async {
      final boundary = captureKey.currentContext!.findRenderObject()!
          as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final dir = Directory('../../scratch/multi-send')
        ..createSync(recursive: true);
      await File('${dir.path}/chat-staged-confirm.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
