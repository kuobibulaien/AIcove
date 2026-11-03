import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/chat/chat_actions.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/role_agent_mode.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/composer.dart';
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

AppSettings _buildSettings() {
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
  );
}

Conversation _buildConversation(String id, RoleAgentMode mode) {
  final now = DateTime(2026, 3, 24, 10, 0, 0);
  return Conversation(
    id: id,
    agentMode: mode,
    title: id,
    displayName: id,
    createdAt: now,
    updatedAt: now,
    lastMessageTime: now,
  );
}

class _Actions extends ChatActions {
  _Actions(super.ref);
  final queued = <(String, bool)>[];
  List<String> toTake = const [];

  @override
  bool queueWhileRunning(String text, {required bool steer, String? convId}) {
    queued.add((text, steer));
    return true;
  }

  @override
  List<String> takeQueuedInputs(String convId) => toTake;
}

const _convId = 'conv_queue';
const _writePreview = bool.fromEnvironment('WRITE_COMPOSER_PREVIEW');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<String> sent;
  late _Actions actions;
  late ProviderContainer container;

  setUpAll(() async {
    if (!_writePreview) return;
    for (final entry in {
      'Preview': '/System/Library/Fonts/STHeiti Medium.ttc',
      'MaterialIcons':
          '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    }.entries) {
      final loader = FontLoader(entry.key);
      loader.addFont(
        File(entry.value).readAsBytes().then(ByteData.sublistView),
      );
      await loader.load();
    }
  });

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    sent = [];
  });

  Future<void> pumpComposer(
    WidgetTester tester, {
    RoleAgentMode mode = RoleAgentMode.tool,
    bool running = false,
    Key? capture,
    bool dark = false,
  }) async {
    final settings = _buildSettings();
    final conversation = _buildConversation(_convId, mode);
    container = ProviderContainer(
      overrides: [
        appSettingsProvider.overrideWith(
          () => _FakeAppSettingsNotifier(settings),
        ),
        activeConversationProvider.overrideWith((ref) => conversation),
        chatActionsProvider.overrideWith((ref) => actions = _Actions(ref)),
      ],
    );
    addTearDown(container.dispose);
    container.read(chatActionsProvider);
    container.read(conversationSendingProvider(_convId).notifier).state =
        running;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: SkinScope(
          skin: const MoeTalkSkin(),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              brightness: dark ? Brightness.dark : Brightness.light,
              fontFamily: _writePreview ? 'Preview' : null,
              extensions: [dark ? MoeColors.dark() : MoeColors.light()],
            ),
            home: Scaffold(
              backgroundColor: dark
                  ? MoeColors.dark().bgMain
                  : MoeColors.light().bgMain,
              body: RepaintBoundary(
                key: capture,
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: Composer(
                disabled: false,
                onSend: (text) async => sent.add(text),
                onImageSelected: (_, {String? text}) async {},
                onFileSelected: (_, {String? text}) async {},
                onHeightChanged: (_) {},
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> type(WidgetTester tester, String text) async {
    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), text);
    await tester.pump();
  }

  Future<void> press(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    LogicalKeyboardKey? modifier,
  }) async {
    if (modifier != null) await tester.sendKeyDownEvent(modifier);
    await tester.sendKeyEvent(key);
    if (modifier != null) await tester.sendKeyUpEvent(modifier);
    await tester.pumpAndSettle();
  }

  String inputText(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField)).controller!.text;

  testWidgets('Agent 空闲时 Enter 发送，Shift+Enter 不发送', (tester) async {
    await pumpComposer(tester);
    await type(tester, '你好');
    await press(
      tester,
      LogicalKeyboardKey.enter,
      modifier: LogicalKeyboardKey.shiftLeft,
    );
    expect(sent, isEmpty);
    await press(tester, LogicalKeyboardKey.enter);
    expect(sent, ['你好']);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('Agent 运行中 Enter 插话、Option+Enter 做完再发', (tester) async {
    await pumpComposer(tester, running: true);
    await type(tester, '改看 c');
    await press(tester, LogicalKeyboardKey.enter);
    await type(tester, '最后总结');
    await press(
      tester,
      LogicalKeyboardKey.enter,
      modifier: LogicalKeyboardKey.altLeft,
    );
    expect(actions.queued, [('改看 c', true), ('最后总结', false)]);
    expect(sent, isEmpty);
    expect(inputText(tester), isEmpty);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('输入法组字中的 Enter 不发送', (tester) async {
    await pumpComposer(tester);
    await tester.tap(find.byType(TextField));
    final controller =
        tester.widget<TextField>(find.byType(TextField)).controller!;
    controller.value = const TextEditingValue(
      text: 'ni',
      selection: TextSelection.collapsed(offset: 2),
      composing: TextRange(start: 0, end: 2),
    );
    await tester.pump();
    await press(tester, LogicalKeyboardKey.enter);
    expect(sent, isEmpty);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('聊天模式的 Enter 不发送', (tester) async {
    await pumpComposer(tester, mode: RoleAgentMode.chat);
    await type(tester, '你好');
    await press(tester, LogicalKeyboardKey.enter);
    expect(sent, isEmpty);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('排队显示在输入框上方，Option+↑ 放回输入框', (tester) async {
    await pumpComposer(tester, running: true);
    container.read(conversationQueuedInputsProvider(_convId).notifier).state =
        const [
          QueuedChatInput('改看 c', steer: true),
          QueuedChatInput('最后总结', steer: false),
        ];
    await tester.pump();
    expect(find.textContaining('改看 c', findRichText: true), findsOneWidget);
    expect(find.textContaining('做完再发', findRichText: true), findsWidgets);

    actions.toTake = ['改看 c', '最后总结'];
    await tester.tap(find.byType(TextField));
    await press(
      tester,
      LogicalKeyboardKey.arrowUp,
      modifier: LogicalKeyboardKey.altLeft,
    );
    expect(inputText(tester), '改看 c\n最后总结');
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('停止后没发出的话标「未发出」，不自动覆盖输入框', (tester) async {
    await pumpComposer(tester);
    await type(tester, '草稿');
    container.read(returnedQueuedInputsProvider(_convId).notifier).state = [
      '插一句',
    ];
    await tester.pump();
    expect(find.textContaining('未发出', findRichText: true), findsOneWidget);
    expect(inputText(tester), '草稿');

    actions.toTake = ['插一句'];
    await tester.tap(find.byIcon(Icons.undo_rounded));
    await tester.pumpAndSettle();
    expect(inputText(tester), '插一句\n草稿');
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('手机运行中有字时点发送是插话，长按是做完再发', (tester) async {
    await pumpComposer(tester, running: true);
    await type(tester, '改看 c');
    await tester.tap(find.byKey(const ValueKey('composer_steer_button')));
    await tester.pumpAndSettle();
    await type(tester, '最后总结');
    await tester.longPress(find.byKey(const ValueKey('composer_steer_button')));
    await tester.pumpAndSettle();
    expect(actions.queued, [('改看 c', true), ('最后总结', false)]);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  // 源码渲染预览：--dart-define=WRITE_COMPOSER_PREVIEW=true 时写到
  // scratch/agent-steer-20261024/。Mac 窄屏，运行中有排队、输入框分空与有字两态。
  for (final (name, dark, typed) in [
    ('running-queue-light', false, ''),
    ('running-typed-light', false, '顺便把 c.json 也看一下'),
    ('running-queue-dark', true, ''),
  ]) {
    testWidgets('preview $name', (tester) async {
      if (!_writePreview) return;
      tester.view.physicalSize = const Size(400, 260);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final capture = GlobalKey();
      await pumpComposer(tester, running: true, capture: capture, dark: dark);
      container.read(conversationQueuedInputsProvider(_convId).notifier).state =
          const [
            QueuedChatInput('先别改测试，改看 b.json 的配置', steer: true),
            QueuedChatInput('做完后写一份改动总结', steer: false),
          ];
      if (name == 'running-queue-light') {
        container.read(returnedQueuedInputsProvider(_convId).notifier).state =
            const ['上次停止时没发出的一句'];
      }
      if (typed.isNotEmpty) await type(tester, typed);
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final boundary =
            capture.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('../../scratch/agent-steer-20261024/$name.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
      });
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  }
}
