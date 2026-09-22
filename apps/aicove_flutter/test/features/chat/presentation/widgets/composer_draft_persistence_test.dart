import 'dart:convert';
import 'package:aicove_flutter/src/features/smart_reply/application/smart_reply_controller.dart';
import 'dart:async';
import 'package:aicove_flutter/src/features/chat/application/chat_edit.dart';
import 'package:aicove_flutter/src/features/chat/chat_layer_providers.dart';
import 'package:aicove_flutter/src/core/services/attachment_picker_service.dart';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/composer.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/ui/theme/skin_provider.dart';
import 'package:aicove_flutter/src/ui/theme/skins/moetalk_skin.dart';

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

Conversation _buildConversation(String id) {
  final now = DateTime(2026, 3, 23, 21, 0, 0);
  return Conversation(
    id: id,
    title: id,
    displayName: id,
    createdAt: now,
    updatedAt: now,
    lastMessageTime: now,
  );
}

final _liveOwner = StateProvider<String>((ref) => 'conv_a');

Widget _buildHost({
  required Conversation conversation,
  Future<void> Function(ChatEditDraft, String, SelectedAttachment?)?
      onSubmitEdit,
  void Function(String)? onSend,
  bool liveOwner = false,
}) {
  final settings = _buildSettings();
  return ProviderScope(
    key: ValueKey<String>('composer_scope_${conversation.id}'),
    overrides: [
      appSettingsProvider.overrideWith(
        () => _FakeAppSettingsNotifier(settings),
      ),
      activeConversationProvider.overrideWith((ref) =>
          liveOwner ? _buildConversation(ref.watch(_liveOwner)) : conversation),
    ],
    child: SkinScope(
      skin: const MoeTalkSkin(),
      child: MaterialApp(
        home: Scaffold(
          body: Composer(
            onSend: onSend ?? (_) {},
            onSubmitEdit: onSubmitEdit,
            onImageSelected: (_, {String? text}) {},
            onFileSelected: (_, {String? text}) {},
          ),
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('辅助回答按会话填入并保留已有草稿，不发送', (tester) async {
    var sends = 0;
    await tester.pumpWidget(_buildHost(conversation: _buildConversation('conv_a'), onSend: (_) => sends++));
    await _pumpComposerReady(tester);
    final input = find.byType(TextField).first;
    await tester.enterText(input, '已有草稿');
    final container = ProviderScope.containerOf(tester.element(find.byType(Composer)));
    container.read(smartReplyDraftProvider('conv_b').notifier).state = '其他会话';
    await tester.pump();
    expect(tester.widget<TextField>(input).controller!.text, '已有草稿');
    container.read(smartReplyDraftProvider('conv_a').notifier).state = '候选回复';
    await _pumpComposerReady(tester);
    expect(tester.widget<TextField>(input).controller!.text, '已有草稿\n候选回复');
    expect(sends, 0);
    await _disposeComposer(tester);
  });

  const edit = ChatEditDraft(
      conversationId: 'conv_a', messageId: 'm2', historyVersion: 'v1');
  void seedEdit({Map<String, dynamic>? marker}) {
    SharedPreferences.setMockInitialValues({
      composerDraftStorageKey('conv_a'): jsonEncode({
        'version': 1,
        'text': '编辑内容',
        'edit': marker ?? edit.toJson(),
      })
    });
  }

  for (final width in [360.0, 1000.0]) {
    testWidgets('编辑草稿重建后仍有取消入口 $width', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      seedEdit();
      await tester
          .pumpWidget(_buildHost(conversation: _buildConversation('conv_a')));
      await _pumpComposerReady(tester);
      expect(find.text('编辑内容'), findsOneWidget);
      expect(find.byKey(const ValueKey('cancel_message_edit')), findsOneWidget);
      await _disposeComposer(tester);
      await tester
          .pumpWidget(_buildHost(conversation: _buildConversation('conv_a')));
      await _pumpComposerReady(tester);
      expect(find.byKey(const ValueKey('cancel_message_edit')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('cancel_message_edit')));
      await _pumpComposerReady(tester);
      expect(find.text('编辑内容'), findsNothing);
      expect(
          (await SharedPreferences.getInstance())
              .getString(composerDraftStorageKey('conv_a')),
          isNull);
      expect(tester.takeException(), isNull);
      await _disposeComposer(tester);
    });
  }

  testWidgets('未提交及拒绝提交均保留编辑草稿', (tester) async {
    seedEdit();
    final accepted = Completer<void>();
    var calls = 0;
    String? receivedId;
    await tester.pumpWidget(_buildHost(
        conversation: _buildConversation('conv_a'),
        onSubmitEdit: (draft, text, attachment) {
          calls++;
          receivedId = draft.messageId;
          return accepted.future;
        }));
    await _pumpComposerReady(tester);
    tester.widget<TextField>(find.byType(TextField)).onSubmitted!('');
    await _pumpComposerReady(tester);
    tester.widget<TextField>(find.byType(TextField)).onSubmitted!('');
    await _pumpComposerReady(tester);
    expect(calls, 1);
    expect(receivedId, 'm2');
    expect(find.text('编辑内容'), findsOneWidget);
    accepted.completeError(StateError('测试提交拒绝'));
    await _pumpComposerReady(tester);
    expect(find.text('编辑内容'), findsOneWidget);
    expect(
        (await SharedPreferences.getInstance())
            .getString(composerDraftStorageKey('conv_a')),
        contains('m2'));
    await _disposeComposer(tester);
  });

  testWidgets('确认本地提交后才清除编辑草稿', (tester) async {
    seedEdit();
    final accepted = Completer<void>();
    await tester.pumpWidget(_buildHost(
        conversation: _buildConversation('conv_a'),
        onSubmitEdit: (_, __, ___) => accepted.future));
    await _pumpComposerReady(tester);
    tester.widget<TextField>(find.byType(TextField)).onSubmitted!('');
    await _pumpComposerReady(tester);
    expect(find.text('编辑内容'), findsOneWidget);
    accepted.complete();
    await _pumpComposerReady(tester);
    expect(find.text('编辑内容'), findsNothing);
    expect(
        (await SharedPreferences.getInstance())
            .getString(composerDraftStorageKey('conv_a')),
        isNull);
    await _disposeComposer(tester);
  });

  testWidgets('提交期间切角色不清另一角色草稿，也不把编辑标识带过去', (tester) async {
    seedEdit();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(composerDraftStorageKey('conv_b'),
        jsonEncode({'version': 1, 'text': 'B的草稿'}));
    final accepted = Completer<void>();
    await tester.pumpWidget(_buildHost(
        conversation: _buildConversation('conv_a'),
        liveOwner: true,
        onSubmitEdit: (_, __, ___) => accepted.future));
    await _pumpComposerReady(tester);
    final container =
        ProviderScope.containerOf(tester.element(find.byType(Composer)));
    tester.widget<TextField>(find.byType(TextField)).onSubmitted!('');
    await _pumpComposerReady(tester);
    container.read(_liveOwner.notifier).state = 'conv_b';
    await _pumpComposerReady(tester);
    expect(find.text('B的草稿'), findsOneWidget);
    expect(find.byKey(const ValueKey('cancel_message_edit')), findsNothing);
    accepted.complete();
    await _pumpComposerReady(tester);
    expect(find.text('B的草稿'), findsOneWidget);
    expect(prefs.getString(composerDraftStorageKey('conv_a')), isNull);
    expect(
        prefs.getString(composerDraftStorageKey('conv_b')), contains('B的草稿'));
    container.read(_liveOwner.notifier).state = 'conv_a';
    await _pumpComposerReady(tester);
    expect(find.text('编辑内容'), findsNothing);
    await _disposeComposer(tester);
  });

  testWidgets('损坏编辑标识不能降级为普通发送', (tester) async {
    seedEdit(marker: {'messageId': 'm2'});
    var sends = 0;
    await tester.pumpWidget(_buildHost(
        conversation: _buildConversation('conv_a'), onSend: (_) => sends++));
    await _pumpComposerReady(tester);
    tester.widget<TextField>(find.byType(TextField)).onSubmitted!('');
    await _pumpComposerReady(tester);
    expect(sends, 0);
    expect(find.byKey(const ValueKey('cancel_message_edit')), findsOneWidget);
    await _disposeComposer(tester);
  });

  testWidgets('损坏的整份JSON草稿不能把编辑元数据当普通消息发送', (tester) async {
    SharedPreferences.setMockInitialValues({
      composerDraftStorageKey('conv_a'): '{"version":1,"text":"原文","edit":'
    });
    var sends = 0;
    await tester.pumpWidget(_buildHost(
        conversation: _buildConversation('conv_a'), onSend: (_) => sends++));
    await _pumpComposerReady(tester);
    tester.widget<TextField>(find.byType(TextField)).onSubmitted!('');
    await _pumpComposerReady(tester);
    expect(sends, 0);
    expect(find.byKey(const ValueKey('cancel_message_edit')), findsOneWidget);
    await _disposeComposer(tester);
  });

  testWidgets('异步编辑回填按owner隔离且空文本会清旧输入', (tester) async {
    await tester
        .pumpWidget(_buildHost(conversation: _buildConversation('conv_a')));
    await _pumpComposerReady(tester);
    final container =
        ProviderScope.containerOf(tester.element(find.byType(Composer)));
    await tester.enterText(find.byType(TextField), '旧输入');
    container.read(chatEditSeedProvider('conv_b').notifier).state =
        const ChatEditSeed(
            draft: ChatEditDraft(
                conversationId: 'conv_b',
                messageId: 'other',
                historyVersion: 'b'),
            text: '不能出现');
    await _pumpComposerReady(tester);
    expect(find.text('旧输入'), findsOneWidget);
    container.read(chatEditSeedProvider('conv_a').notifier).state =
        const ChatEditSeed(draft: edit, text: '');
    await _pumpComposerReady(tester);
    expect(find.text('旧输入'), findsNothing);
    expect(find.text('不能出现'), findsNothing);
    expect(find.byKey(const ValueKey('cancel_message_edit')), findsOneWidget);
    await _disposeComposer(tester);
  });

  testWidgets('scoped draft restores text when attachment metadata exists',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'composer_draft_v2:conv_a': jsonEncode(<String, Object?>{
        'version': 1,
        'text': '会话 A 草稿',
        'attachment': <String, Object?>{
          'path': r'C:\missing\composer-draft.png',
          'type': 'image',
        },
      }),
    });
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('composer_draft_v2:conv_a'), isNotNull);

    await tester.pumpWidget(
      _buildHost(conversation: _buildConversation('conv_a')),
    );
    await _pumpComposerReady(tester);

    final editable = tester.widget<EditableText>(find.byType(EditableText));
    expect(editable.controller.text, '会话 A 草稿');

    await _disposeComposer(tester);
  });

  testWidgets('scoped drafts stay isolated per conversation', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'composer_draft_v2:conv_a': jsonEncode(<String, Object?>{
        'version': 1,
        'text': '会话 A 草稿',
      }),
      'composer_draft_v2:conv_b': jsonEncode(<String, Object?>{
        'version': 1,
        'text': '会话 B 草稿',
      }),
    });

    await tester.pumpWidget(
      _buildHost(conversation: _buildConversation('conv_a')),
    );
    await _pumpComposerReady(tester);

    expect(find.text('会话 A 草稿'), findsOneWidget);
    expect(find.text('会话 B 草稿'), findsNothing);

    await tester.pumpWidget(
      _buildHost(conversation: _buildConversation('conv_b')),
    );
    await _pumpComposerReady(tester);

    expect(find.text('会话 A 草稿'), findsNothing);
    expect(find.text('会话 B 草稿'), findsOneWidget);

    await _disposeComposer(tester);
  });

  testWidgets('legacy text draft key still restores', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'composer_draft_text': '旧版草稿',
    });

    await tester.pumpWidget(
      _buildHost(conversation: _buildConversation('legacy_conv')),
    );
    await _pumpComposerReady(tester);

    expect(find.text('旧版草稿'), findsOneWidget);

    await _disposeComposer(tester);
  });

  test('image draft attachment decodes and restores when file exists',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'aicove_composer_draft_attachment',
    );
    final imageFile = File('${directory.path}\\draft.png');
    await imageFile.writeAsBytes(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO7Z0ioAAAAASUVORK5CYII=',
      ),
    );

    final attachment = composerDecodeDraftAttachment(<String, Object?>{
      'path': imageFile.path,
      'type': 'image',
    });
    final restored = await composerResolveRestorableDraftAttachment(
      attachment,
    );

    expect(attachment, isNotNull);
    expect(attachment!.type.name, 'image');
    expect(restored?.path, imageFile.path);
  });

  test('image draft attachment drops when file is missing', () async {
    final attachment = composerDecodeDraftAttachment(<String, Object?>{
      'path': r'C:\missing\composer-draft.png',
      'type': 'image',
    });
    final restored = await composerResolveRestorableDraftAttachment(
      attachment,
    );

    expect(attachment, isNotNull);
    expect(restored, isNull);
  });
}

Future<void> _pumpComposerReady(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _disposeComposer(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 4));
}
