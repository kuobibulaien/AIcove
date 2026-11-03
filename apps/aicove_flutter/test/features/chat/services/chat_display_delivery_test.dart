import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/agent_context/domain/silly_tavern_preset.dart';
import 'package:aicove_flutter/src/features/agent_context/domain/silly_tavern_preset_parser.dart';
import 'package:aicove_flutter/src/features/agent_context/domain/tavern_compatibility_port.dart';
import 'package:aicove_flutter/src/features/agent_context/providers/preset_recipe_provider.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_history_store.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_message_projection_codec.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_service.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_tts_handler.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/features/plugins/domain/plugin.dart';
import 'package:aicove_flutter/src/features/plugins/plugin_manager.dart';
import 'package:aicove_flutter/src/features/plugins/plugin_providers.dart';
import 'package:aicove_flutter/src/features/plugins/tts/voice_preset_application.dart';
import 'package:aicove_flutter/src/features/plugins/tts/voice_request.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';

import '../../../../tool/chat_segmented_fixture.dart';

class _Settings extends AppSettingsNotifier {
  @override
  Future<AppSettings> build() async =>
      segmentedProbeSettings.copyWith(streamSegmentDelaySeconds: 0);
}

class _PresetPort implements TavernCompatibilityPort {
  _PresetPort(this.preset);
  final SillyTavernPreset preset;
  @override
  Future<SillyTavernPreset?> resolvePreset(String? explicitId) async => preset;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _VoicePort implements VoicePresetApplicationPort {
  @override
  Future<VoiceRequest> forRole(Conversation owner) async =>
      VoiceRequest(ownerId: owner.id, error: 'disabled');
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _History implements ChatHistoryStore {
  final messages = <Message>[];
  @override
  Future<void> appendAssistantRawMessage({
    required String conversationId,
    required String userMessageId,
    required Message rawMessage,
    required List<Message> projectedMessages,
    required String lastMessagePreview,
    bool updateShortWindow = true,
    bool updateSummary = true,
    FutureOr<bool> Function()? shouldCommit,
  }) async {}
  @override
  Future<void> appendMessage({
    required String conversationId,
    required Message message,
    String? lastMessagePreview,
    FutureOr<bool> Function()? shouldCommit,
  }) async {
    messages.add(message);
  }

  @override
  Future<void> markMessageStatus({
    required String conversationId,
    required String messageId,
    required String status,
  }) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'cached proactive replies use display regex after extracting think',
    () async {
      final preset = const SillyTavernPresetParser().parseMap(
        {
          'prompts': [
            {'identifier': 'main', 'role': 'system', 'content': ''},
          ],
          'prompt_order': [
            {
              'order': [
                {'identifier': 'main', 'enabled': true},
              ],
            },
          ],
          'extensions': {
            'regex_scripts': [
              {
                'id': 'display',
                'scriptName': 'display',
                'findRegex': '/SECRET/g',
                'replaceString': 'VISIBLE',
                'placement': [2],
                'disabled': false,
                'markdownOnly': false,
                'promptOnly': false,
              },
            ],
          },
        },
        sourceFileName: 'display.json',
        regexAuthorized: true,
      );
      final container = ProviderContainer(
        overrides: [
          tavernCompatibilityPortProvider.overrideWithValue(
            _PresetPort(preset),
          ),
          voicePresetApplicationProvider.overrideWithValue(_VoicePort()),
          pluginManagerProvider.overrideWithValue(PluginManager()),
        ],
      );
      addTearDown(container.dispose);
      final result = await container
          .read(chatSendServiceProvider)
          .processAssistantReplyWithPlugins(
            conv: Conversation(
              id: 'c',
              title: '角色',
              displayName: '角色',
              createdAt: DateTime(2026),
              updatedAt: DateTime(2026),
            ),
            rawReplyText: '<think>私有思考</think>SECRET <tts>SECRET</tts>',
          );
      expect(result.reasoning, '私有思考');
      expect(result.rawReplyText, 'SECRET <tts>SECRET</tts>');
      expect(result.replyText, 'VISIBLE <tts>SECRET</tts>');
      expect(result.processedText, result.replyText);
    },
  );

  test(
    'tool audio uses round-aware projection without restoring erased raw',
    () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final result = container
          .read(chatSendServiceProvider)
          .buildAssistantMessages(
            settings: segmentedProbeSettings,
            apiResult: const ApiCallResult(
              rawReplyText: 'SECRET准备\nSECRET完成',
              replyText: 'VISIBLE准备',
              processedText: 'VISIBLE准备',
              pluginEvents: [],
              toolResults: [],
              toolAudioResults: [
                ToolAudioResult(
                  audioUrl: 'https://example.test/a.wav',
                  text: '声音',
                ),
              ],
              replyRounds: [
                ReplyRound(
                  rawText: 'SECRET准备',
                  replyText: 'VISIBLE准备',
                  processedText: 'VISIBLE准备',
                  reasoning: '第一轮思考',
                ),
                ReplyRound(
                  rawText: 'SECRET完成',
                  replyText: '',
                  processedText: '',
                  reasoning: '最后思考',
                ),
              ],
            ),
          );
      expect(
        result.messages.map((message) => message.displayText).join(),
        isNot(contains('SECRET')),
      );
      expect(
        result.messages.map((message) => message.displayText).join(),
        contains('VISIBLE准备'),
      );
      expect(
        result.messages
            .expand((message) => message.blocks ?? <MessageBlock>[])
            .whereType<ThinkingBlock>()
            .map((block) => block.content),
        ['第一轮思考', '最后思考'],
      );
      expect(
        result.messages
            .expand((message) => message.blocks ?? <MessageBlock>[])
            .whereType<AudioBlock>(),
        hasLength(1),
      );
      expect(
        ChatMessageProjectionCodec.replyRounds(
          result.rawMessage!.rawPayload,
        ).last.rawText,
        'SECRET完成',
      );
      expect(
        result.messages.every(
          (message) => message.id.startsWith(result.rawMessage!.id),
        ),
        isTrue,
      );
      expect(result.rawMessage!.createdAt.year, greaterThan(1970));
      expect(
        result.messages.every(
          (message) => message.createdAt == result.rawMessage!.createdAt,
        ),
        isTrue,
      );
    },
  );

  for (final displayText in ['VISIBLE', '']) {
    test(
      'background planner uses stored display copy "$displayText"',
      () async {
        final container = ProviderContainer(
          overrides: [ttsPlayerManagerProvider.overrideWithValue(null)],
        );
        addTearDown(container.dispose);
        final build = container
            .read(chatSendServiceProvider)
            .buildAssistantMessages(
              settings: segmentedProbeSettings,
              apiResult: ApiCallResult(
                rawReplyText: 'SECRET',
                replyText: displayText,
                processedText: displayText,
                pluginEvents: const [],
                toolResults: const [],
              ),
            );
        final messages = await container
            .read(chatTtsHandlerProvider)
            .prepareBackgroundSnapshot(
              convId: 'c',
              rawMessage: build.rawMessage!,
              buildResult: build,
              replyText: 'SECRET',
              ttsEnabled: false,
              pluginEvents: [
                PluginEvent(
                  pluginId: 'image',
                  type: 'image_generate',
                  data: {},
                ),
              ],
            );
        expect(
          messages.map((message) => message.displayText).join(),
          displayText,
        );
      },
    );

    test(
      'segmented delivery uses stored display copy "$displayText" instead of raw argument',
      () async {
        final history = _History();
        final container = ProviderContainer(
          overrides: [
            appSettingsProvider.overrideWith(_Settings.new),
            chatHistoryStoreProvider.overrideWithValue(history),
            ttsPlayerManagerProvider.overrideWithValue(null),
          ],
        );
        addTearDown(container.dispose);
        final build = container
            .read(chatSendServiceProvider)
            .buildAssistantMessages(
              settings: segmentedProbeSettings,
              apiResult: ApiCallResult(
                rawReplyText: 'SECRET',
                replyText: displayText,
                processedText: displayText,
                pluginEvents: const [],
                toolResults: const [],
              ),
            );
        await container
            .read(chatTtsHandlerProvider)
            .deliverSegmentedMessages(
              convId: 'c',
              userMsgId: 'user',
              buildResult: build,
              replyText: 'SECRET',
              ttsEnabled: false,
              pluginEvents: [
                PluginEvent(
                  pluginId: 'image',
                  type: 'image_generate',
                  data: {},
                ),
              ],
            );
        expect(
          history.messages.map((message) => message.displayText).join(),
          displayText,
        );
      },
    );
  }
}
