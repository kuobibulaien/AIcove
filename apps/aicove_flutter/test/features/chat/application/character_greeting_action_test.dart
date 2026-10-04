import 'dart:io';

import 'package:aicove_flutter/src/features/agent_context/data/silly_tavern_preset_store.dart';
import 'package:aicove_flutter/src/features/agent_context/providers/preset_recipe_provider.dart';
import 'package:aicove_flutter/src/features/chat/application/chat_page_conversation_actions.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_history_store.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_message_projection_codec.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Appended {
  _Appended(this.conversationId, this.raw, this.projected, this.preview);
  final String conversationId;
  final Message raw;
  final List<Message> projected;
  final String preview;
}

class _RecordingHistoryStore extends ChatHistoryStore {
  _RecordingHistoryStore(super.ref);

  final appended = <_Appended>[];

  @override
  Future<void> appendAssistantRawMessage({
    required String conversationId,
    required String userMessageId,
    required Message rawMessage,
    required List<Message> projectedMessages,
    required String lastMessagePreview,
    bool updateShortWindow = true,
  }) async {
    appended.add(
      _Appended(
        conversationId,
        rawMessage,
        projectedMessages,
        lastMessagePreview,
      ),
    );
  }
}

class _Settings extends AppSettingsNotifier {
  _Settings(this.userName);

  final String? userName;

  @override
  Future<AppSettings> build() async =>
      mapUiModelsToAppSettings({}).copyWith(userName: userName);
}

const _presetSource = '''{"name":"变量卡","prompts":[
{"identifier":"chatHistory","marker":true}],"prompt_order":[
{"identifier":"chatHistory","enabled":true}],
"extensions":{"regex_scripts":[{"id":"hide","scriptName":"去除变量更新",
"findRegex":"/<UpdateVariable>[\\\\s\\\\S]*?<\\\\/UpdateVariable>/g",
"replaceString":"","placement":[2],"markdownOnly":true,"promptOnly":true}]}}''';

void main() {
  late Directory directory;
  late SillyTavernPresetStore presets;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('greeting_action_');
    presets = SillyTavernPresetStore(
      documentsDirectoryResolver: () async => directory,
    );
  });
  tearDown(() => directory.delete(recursive: true));

  Future<_Appended> appendGreeting(
    String greeting, {
    String? userName = '旅行者',
    String? recipeId,
  }) async {
    late _RecordingHistoryStore store;
    final container = ProviderContainer(
      overrides: [
        appSettingsProvider.overrideWith(() => _Settings(userName)),
        sillyTavernPresetStoreProvider.overrideWithValue(presets),
        chatHistoryStoreProvider.overrideWith(
          (ref) => store = _RecordingHistoryStore(ref),
        ),
      ],
    );
    addTearDown(container.dispose);
    final actions = container.read(chatPageConversationActionsProvider);
    await actions.appendCharacterGreeting(
      'conv_1',
      greeting: greeting,
      charName: '纳西妲',
      recipeId: recipeId,
    );
    // 重试覆盖同一条消息，不会新增第二条开场白。
    expect(
      store.appended.single.raw.id,
      ChatPageConversationActions.greetingMessageId('conv_1'),
    );
    return store.appended.single;
  }

  test('writes greeting as a sent assistant raw message with names', () async {
    final result = await appendGreeting('{{char}}朝{{user}}挥手。');
    expect(result.conversationId, 'conv_1');
    expect(result.raw.role, 'assistant');
    expect(result.raw.status, 'sent');
    expect(result.raw.content, '纳西妲朝旅行者挥手。');
    expect(result.projected.single.displayText, '纳西妲朝旅行者挥手。');
    expect(
      ChatPageConversationActions.isCharacterGreeting(result.projected.single),
      isTrue,
    );
  });

  test('falls back to neutral user name when unset', () async {
    final result = await appendGreeting('{{char}}朝{{user}}挥手。', userName: null);
    expect(result.raw.content, '纳西妲朝用户挥手。');
  });

  test('display copy runs authorized preset regex while raw keeps original',
      () async {
    final preset = await presets.importSource(
      _presetSource,
      sourceFileName: 'v.json',
      regexAuthorized: true,
    );
    await presets.setUserNameMacroEnabled(preset.id, false);
    const vars = '<UpdateVariable>{"op":"replace"}</UpdateVariable>';
    final result = await appendGreeting(
      '{{user}}，早。$vars',
      recipeId: preset.id,
    );
    expect(result.raw.content, '用户，早。$vars');
    expect(
      ChatMessageProjectionCodec.displayReplyText(result.raw.rawPayload),
      '用户，早。',
    );
    expect(result.projected.map((m) => m.displayText).join(), '用户，早。');
    expect(result.preview, '用户，早。');
  });

  test('fully hidden greeting does not leak raw text into the timeline',
      () async {
    final preset = await presets.importSource(
      _presetSource,
      sourceFileName: 'v.json',
      regexAuthorized: true,
    );
    final result = await appendGreeting(
      '<UpdateVariable>{"op":"replace"}</UpdateVariable>',
      recipeId: preset.id,
    );
    expect(result.projected, isEmpty);
    expect(result.preview, isEmpty);
  });

  test('unauthorized preset regex leaves display unchanged', () async {
    final preset = await presets.importSource(
      _presetSource,
      sourceFileName: 'v.json',
    );
    const text = '早。<UpdateVariable>x</UpdateVariable>';
    final result = await appendGreeting(text, recipeId: preset.id);
    expect(
      ChatMessageProjectionCodec.displayReplyText(result.raw.rawPayload),
      text,
    );
  });
}
