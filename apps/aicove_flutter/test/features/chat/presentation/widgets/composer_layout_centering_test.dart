import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/composer.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
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

Conversation _buildConversation() {
  final now = DateTime(2026, 3, 24, 10, 0, 0);
  return Conversation(
    id: 'conv_layout_test',
    title: 'layout_test',
    displayName: 'layout_test',
    createdAt: now,
    updatedAt: now,
    lastMessageTime: now,
  );
}

Widget _buildHost({
  required Conversation conversation,
  TargetPlatform platform = TargetPlatform.macOS,
}) {
  final settings = _buildSettings();
  return ProviderScope(
    overrides: [
      appSettingsProvider.overrideWith(
        () => _FakeAppSettingsNotifier(settings),
      ),
      activeConversationProvider.overrideWith((ref) => conversation),
    ],
    child: MaterialApp(
      theme: ThemeData(
        platform: platform,
        useMaterial3: true,
        extensions: [MoeColors.light()],
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          visualDensity: VisualDensity.standard,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
        ),
      ),
      home: Scaffold(
        body: Composer(
          onSend: (_) async {},
          onImageSelected: (_, {String? text}) async {},
          onFileSelected: (_, {String? text}) async {},
        ),
      ),
    ),
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  for (final platform in [TargetPlatform.macOS, TargetPlatform.android]) {
    testWidgets('聊天输入框在单行与多行时均垂直居中，且与两侧按钮间隔紧凑 ($platform)', (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 2;
      addTearDown(() {
        tester.view.reset();
      });

      final conversation = _buildConversation();
      await tester.pumpWidget(_buildHost(
        conversation: conversation,
        platform: platform,
      ));
      await tester.pumpAndSettle();

      final moreButton = find.byType(IconButton).first;
      final sendButton = find.byType(IconButton).last;
      final textField = find.byType(TextField);
      final hintText = find.text('消息');

      expect(moreButton, findsOneWidget);
      expect(sendButton, findsOneWidget);
      expect(textField, findsOneWidget);
      expect(hintText, findsOneWidget);

      final moreRect = tester.getRect(moreButton);
      final sendRect = tester.getRect(sendButton);
      final textRect = tester.getRect(textField);
      final hintRect = tester.getRect(hintText);

      // 1. 验证间距紧凑（按钮与输入框边缘间距 <= 10px）
      final leftGap = textRect.left - moreRect.right;
      final rightGap = sendRect.left - textRect.right;
      expect(leftGap, lessThanOrEqualTo(10.0),
          reason: '左侧加号按钮与输入框间距过大');
      expect(rightGap, lessThanOrEqualTo(10.0),
          reason: '右侧发送按钮与输入框间距过大');
      expect((leftGap - rightGap).abs(), lessThanOrEqualTo(2.0),
          reason: '输入框在加号与发送按钮之间应水平对称居中');

      // 2. 验证单行时垂直居中（包含占位文本本身）
      expect((moreRect.center.dy - textRect.center.dy).abs(), lessThanOrEqualTo(1.5),
          reason: '单行时加号按钮与输入框应垂直居中对齐');
      expect((sendRect.center.dy - textRect.center.dy).abs(), lessThanOrEqualTo(1.5),
          reason: '单行时发送按钮与输入框应垂直居中对齐');
      expect((hintRect.center.dy - moreRect.center.dy).abs(), lessThanOrEqualTo(1.5),
          reason: '单行时占位文字“消息”应与按钮垂直居中对齐');

      // 3. 验证输入单行文本时，文字与按钮垂直居中
      await tester.enterText(textField, '测试消息');
      await tester.pumpAndSettle();
      final moreRectSingle = tester.getRect(moreButton);
      final sendRectSingle = tester.getRect(sendButton);
      final textRectSingle = tester.getRect(textField);
      expect((textRectSingle.center.dy - moreRectSingle.center.dy).abs(), lessThanOrEqualTo(1.5),
          reason: '单行输入文本应与加号按钮垂直居中对齐');
      expect((textRectSingle.center.dy - sendRectSingle.center.dy).abs(), lessThanOrEqualTo(1.5),
          reason: '单行输入文本应与发送按钮垂直居中对齐');

      // 4. 验证两行文本时，按钮依然居中于输入框
      await tester.enterText(
        textField,
        '111111111111111111111111111111111111111111111111111\n11111',
      );
      await tester.pumpAndSettle();

      final moreRectMulti = tester.getRect(moreButton);
      final sendRectMulti = tester.getRect(sendButton);
      final textRectMulti = tester.getRect(textField);

      expect(textRectMulti.height, greaterThan(moreRectMulti.height),
          reason: '两行输入时输入框高度应大于按钮');
      expect((moreRectMulti.center.dy - textRectMulti.center.dy).abs(), lessThanOrEqualTo(2.0),
          reason: '多行时加号按钮应垂直居中对齐于输入框');
      expect((sendRectMulti.center.dy - textRectMulti.center.dy).abs(), lessThanOrEqualTo(2.0),
          reason: '多行时发送按钮应垂直居中对齐于输入框');
    });
  }
}
