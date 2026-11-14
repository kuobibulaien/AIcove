import 'package:aicove_agent_kernel/aicove_agent_kernel.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/proactive_reply_generator.dart';
import 'package:aicove_flutter/src/features/auto_reply/domain/proactive_action.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/auto_reply_agent_helpers.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/context_analyzer.dart';
import 'package:aicove_flutter/src/features/auto_reply/domain/proactive_decision.dart';
import 'package:aicove_flutter/src/features/background_agent/background_agent_service.dart';
import 'package:aicove_flutter/src/features/background_agent/domain/background_agent_definition.dart';
import 'package:aicove_flutter/src/features/background_agent/domain/background_agent_run_result.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/plugins/domain/handlers/ai_tool.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_service.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Settings extends AppSettingsNotifier {
  _Settings(this.value);
  final AppSettings value;
  @override
  Future<AppSettings> build() async => value;
}

class _Generator extends ProactiveReplyGenerator {
  _Generator(super.ref, this.settings, this.prepared);
  final AppSettings settings;
  final List<String> prepared;
  String? failPrepare;
  @override
  Future<ApiConfig> prepare({
    required Conversation conversation,
    required String? reminder,
    DateTime? requestTime,
    String? modelRef,
  }) async {
    final model = modelRef ?? settings.defaultChatModels.first;
    prepared.add(model);
    if (model == failPrepare) throw StateError('prepare failed');
    return ApiConfig(
      settings: settings,
      modelFullId: model,
      providerApiBase: '',
      providerApiKey: null,
      customConfig: const {},
      messages: const [],
      tools: null,
      enabledPluginIds: null,
      modelTemperature: null,
      modelTopP: null,
      modelContextMessageLimit: null,
    );
  }
}

class _DecisionService extends BackgroundAgentService {
  _DecisionService(this.reply)
    : super(
        loadRecentMessages: (_, _) async => [],
        loadSettings: () async => mapUiModelsToAppSettings(const {}),
      );
  final Future<String> Function(String) reply;
  @override
  Future<BackgroundAgentRunResult> run({
    required BackgroundAgentDefinition definition,
    required String conversationId,
    String? extraInstruction,
    List<Message>? contextMessages,
    List<AITool> additionalTools = const [],
    int? maxOutputTokens,
  }) async {
    final text = await reply(definition.modelRef!);
    return BackgroundAgentRunResult(
      sessionId: 'test',
      replyText: text,
      processedText: text,
      toolResults: const [],
      toolCalls: const [],
      rawToolResults: const [],
      usedMessages: const [],
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  final settings = mapUiModelsToAppSettings(
    const {},
  ).copyWith(defaultModelName: 'p:a', defaultChatModels: const ['p:a', 'p:b']);
  final now = DateTime(2026);
  final conversation = Conversation(
    id: 'c',
    title: 'c',
    displayName: 'c',
    createdAt: now,
    updatedAt: now,
  );
  test('generation retries the next model after executor failure', () async {
    final prepared = <String>[];
    final container = ProviderContainer(
      overrides: [
        appSettingsProvider.overrideWith(() => _Settings(settings)),
        proactiveReplyGeneratorProvider.overrideWith(
          (ref) => _Generator(ref, settings, prepared),
        ),
        proactiveReplyExecutorProvider.overrideWithValue(({
          required config,
          required sessionId,
          required userText,
          required turnId,
        }) async {
          if (config.modelFullId == 'p:a') throw StateError('first failed');
          return const ApiCallResult(
            replyText: 'ok',
            processedText: 'ok',
            pluginEvents: [],
            toolResults: [],
          );
        }),
      ],
    );
    addTearDown(container.dispose);
    expect(
      await container
          .read(proactiveReplyGeneratorProvider)
          .generate(conversation: conversation, reminder: 'hello', turnId: 't'),
      'ok',
    );
    expect(prepared, ['p:a', 'p:b']);
  });

  test('candidates keep the session first and remove duplicates', () {
    final value = settings.copyWith(
      modelList: ['p:c'],
      defaultChatModels: ['p:a', 'p:c', 'p:b', 'p:a'],
    );
    expect(
      resolveAutoReplyAgentModelCandidates(
        value,
        conversation.copyWith(sessionProvider: 'p:c'),
      ),
      ['p:c', 'p:a', 'p:b'],
    );
    expect(
      resolveAutoReplyAgentModelCandidates(
        settings.copyWith(defaultChatModels: []),
        conversation,
      ),
      ['p:a'],
    );
    expect(
      resolveJudgmentModelCandidates(
        value,
        conversation.copyWith(sessionProvider: 'p:c'),
      ),
      ['p:c', 'p:a', 'p:b'],
    );
    expect(
      resolveJudgmentModelCandidates(
        value.copyWith(
          autoReplySettings: value.autoReplySettings.copyWith(
            analyzerProvider: 'judge',
            analyzerModel: 'solo',
          ),
        ),
        conversation,
      ),
      ['judge:solo'],
    );
  });

  for (final scenario in ['prepare', 'all fail', 'cancel', 'draft state']) {
    test('generation handles $scenario', () async {
      final prepared = <String>[];
      final failures = [StateError('first'), StateError('last')];
      const cancelled = KernelCancelledException();
      var attempts = 0;
      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWith(() => _Settings(settings)),
          proactiveReplyGeneratorProvider.overrideWith((ref) {
            final generator = _Generator(ref, settings, prepared);
            if (scenario == 'prepare') generator.failPrepare = 'p:a';
            return generator;
          }),
          proactiveReplyExecutorProvider.overrideWithValue(({
            required config,
            required sessionId,
            required userText,
            required turnId,
          }) async {
            attempts++;
            if (scenario == 'cancel') throw cancelled;
            if (scenario == 'all fail') throw failures[attempts - 1];
            if (scenario == 'draft state' && attempts == 1) {
              await config.boundTools!.single.handler({
                'opening_line': 'stale',
              });
              throw failures.first;
            }
            return const ApiCallResult(
              replyText: 'ok',
              processedText: 'ok',
              pluginEvents: [],
              toolResults: [],
            );
          }),
        ],
      );
      addTearDown(container.dispose);
      final generator = container.read(proactiveReplyGeneratorProvider);
      final result = scenario == 'draft state'
          ? generator.generateDraft(
              conversation: conversation,
              reminder: 'hello',
              turnId: 't',
              requestTime: now,
              allowCall: true,
            )
          : generator.generate(
              conversation: conversation,
              reminder: 'hello',
              turnId: 't',
            );
      if (scenario == 'cancel' || scenario == 'all fail') {
        await expectLater(
          result,
          throwsA(same(scenario == 'cancel' ? cancelled : failures.last)),
        );
        expect(prepared, scenario == 'cancel' ? ['p:a'] : ['p:a', 'p:b']);
      } else {
        final value = await result;
        if (value is String) {
          expect(value, 'ok');
        } else {
          final draft = value as ProactiveDraft;
          expect(draft.text, 'ok');
          expect(draft.isCall, false);
        }
        expect(prepared, ['p:a', 'p:b']);
      }
    });
  }

  for (final scenario in [
    'request',
    'parse',
    'cancel',
    'all fail',
    'explicit',
  ]) {
    test('judgment handles $scenario', () async {
      final models = <String>[];
      final failures = [StateError('first'), StateError('last')];
      const cancelled = KernelCancelledException();
      final value = scenario == 'explicit'
          ? settings.copyWith(
              autoReplySettings: settings.autoReplySettings.copyWith(
                analyzerModel: 'judge:solo',
              ),
            )
          : settings;
      final container = ProviderContainer(
        overrides: [
          backgroundAgentServiceProvider.overrideWithValue(
            _DecisionService((model) async {
              models.add(model);
              if (scenario == 'cancel') throw cancelled;
              if (scenario == 'all fail') throw failures[models.length - 1];
              if (scenario == 'explicit') throw failures.first;
              if (scenario == 'parse') return 'not json';
              if (models.length == 1) throw failures.first;
              return '{"kind":"stay_silent"}';
            }),
          ),
        ],
      );
      addTearDown(container.dispose);
      final port = container.read(proactiveDecisionPortResolverProvider)(
        value,
        conversation,
      );
      final result = port.answer(
        state: 'test',
        questions: const [
          ProactiveQuestion.choice(
            id: 'kind',
            instruction: 'kind',
            options: {'stay_silent': 'silent'},
          ),
        ],
      );
      if (scenario == 'request') {
        expect((await result)['kind']!.choice, 'stay_silent');
        expect(models, ['p:a', 'p:b']);
      } else {
        await expectLater(
          result,
          throwsA(
            scenario == 'parse'
                ? isFormatException
                : same(
                    scenario == 'cancel'
                        ? cancelled
                        : scenario == 'explicit'
                        ? failures.first
                        : failures.last,
                  ),
          ),
        );
        expect(
          models,
          scenario == 'all fail'
              ? ['p:a', 'p:b']
              : scenario == 'explicit'
              ? ['judge:solo']
              : ['p:a'],
        );
      }
    });
  }
}
