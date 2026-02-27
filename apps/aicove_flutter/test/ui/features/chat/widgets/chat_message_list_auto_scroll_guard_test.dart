import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/settings/settings_models.dart';
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
    messageFormatConfig: MessageFormatConfig(),
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
  int _resumeAutoScrollToken = 0;

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

  void appendUserMessageAndResumeAutoScroll() {
    final nextIndex = _messages.length;
    final lastTime = _messages.last.createdAt;
    final longText = List.filled(8, '用户新消息').join('，');
    setState(() {
      _resumeAutoScrollToken++;
      _messages = [
        ..._messages,
        Message.text(
          id: 'm_$nextIndex',
          role: 'user',
          content: '用户发送：$longText',
          createdAt: lastTime.add(const Duration(minutes: 1)),
          status: 'sent',
        ),
      ];
    });
  }

  @override
  Widget build(BuildContext context) {
    return ChatMessageList(
      conversationId: 'conv_test',
      messages: _messages,
      displayName: '测试AI',
      avatarUrl: null,
      resumeAutoScrollToken: _resumeAutoScrollToken,
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('用户上滑后，AI新增消息不应强制回到底部', (tester) async {
    final harnessKey = GlobalKey<_ChatListHarnessState>();

    await tester.pumpWidget(_buildHost(harnessKey));
    await tester.pumpAndSettle();

    final listFinder = find.byType(ListView);
    expect(listFinder, findsOneWidget);

    await tester.drag(listFinder, const Offset(0, 320));
    await tester.pumpAndSettle();

    var controller = tester.widget<ListView>(listFinder).controller!;
    expect(controller.offset, greaterThan(40));

    harnessKey.currentState!.appendAssistantMessage();
    await tester.pump();
    await tester.pumpAndSettle();

    controller = tester.widget<ListView>(listFinder).controller!;
    expect(controller.offset, greaterThan(40));
  });

  testWidgets('用户再次发送消息后，应恢复自动回到底部', (tester) async {
    final harnessKey = GlobalKey<_ChatListHarnessState>();

    await tester.pumpWidget(_buildHost(harnessKey));
    await tester.pumpAndSettle();

    final listFinder = find.byType(ListView);
    expect(listFinder, findsOneWidget);

    await tester.drag(listFinder, const Offset(0, 320));
    await tester.pumpAndSettle();

    var controller = tester.widget<ListView>(listFinder).controller!;
    expect(controller.offset, greaterThan(40));

    harnessKey.currentState!.appendAssistantMessage();
    await tester.pump();
    await tester.pumpAndSettle();

    controller = tester.widget<ListView>(listFinder).controller!;
    expect(controller.offset, greaterThan(40));

    harnessKey.currentState!.appendUserMessageAndResumeAutoScroll();
    await tester.pump();
    await tester.pumpAndSettle();

    controller = tester.widget<ListView>(listFinder).controller!;
    expect(controller.offset, lessThanOrEqualTo(1));
  });
}
