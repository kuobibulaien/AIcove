import 'dart:convert';

import 'package:aicove_flutter/src/core/prompts/prompt_builtin_defaults.g.dart';
import 'package:aicove_flutter/src/core/services/system_reminder_service.dart';
import 'package:aicove_flutter/src/features/agent_plugins/plugin_request_context.dart';
import 'package:aicove_flutter/src/features/agent_plugins/plugin_request_scope.dart';
import 'package:aicove_flutter/src/features/agent_plugins/plugin_runtime.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/context_analyzer.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/proactive_call.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/proactive_reply_generator.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_service.dart';
import 'package:aicove_flutter/src/features/auto_reply/domain/proactive_decision.dart';
import 'package:aicove_flutter/src/features/plugins/time_awareness/time_awareness_plugin.dart';
import 'package:aicove_flutter/src/features/plugins/trigger/trigger_config.dart';
import 'package:aicove_flutter/src/features/plugins/trigger/trigger_plugin.dart';
import 'package:aicove_flutter/src/features/plugins/web_search/web_search_config.dart';
import 'package:aicove_flutter/src/features/plugins/web_search/web_search_plugin.dart';
import 'package:aicove_flutter/src/features/plugins/tts/voice_request.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:aicove_flutter/src/features/plugins/image/drawing_preset.dart';
import 'package:aicove_flutter/src/features/plugins/image/drawing_preset_provider.dart';
import 'package:aicove_flutter/src/features/plugins/image/image_config.dart';
import 'package:aicove_flutter/src/features/plugins/prompts/plugin_prompts.dart';
import 'package:aicove_flutter/src/features/plugins/sticker/sticker_config.dart';
import 'package:aicove_flutter/src/features/plugins/time_awareness/time_awareness_config.dart';
import 'package:aicove_flutter/src/features/plugins/tts/tts_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

ImageConfig _drawing(String inline) => const ImageConfig().copyWith(
  fastPromptPresets: [DrawingPromptPreset(name: '辅助提示词', content: inline)],
  selectedFastPromptPresetName: '辅助提示词',
);

final _refProvider = Provider<Ref>((ref) => ref);

class _PromptStore implements PluginPromptStore {
  _PromptStore(this.prompts);
  final PluginPrompts prompts;
  @override
  Future<PluginPrompts> load() async => prompts;
  @override
  Future<void> save(PluginPrompts prompts) async {}
}

class _DraftGenerator extends ProactiveReplyGenerator {
  _DraftGenerator(super.ref);
  String? reminder;

  @override
  Future<ApiConfig> prepare({
    required Conversation conversation,
    required String? reminder,
    DateTime? requestTime,
    String? modelRef,
  }) async {
    this.reminder = reminder;
    return ApiConfig(
      settings: mapUiModelsToAppSettings(const {}),
      modelFullId: 'test',
      providerApiBase: '',
      customConfig: const {},
      messages: const [],
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('迁移只收表情包与时间感知，与默认相同的不保存，旧键不动', () async {
    final catalog = DrawingPresetCatalog(
      presets: [
        DrawingPreset(id: 'a', name: '默认', config: _drawing('默认预设的画图说明')),
        DrawingPreset(id: 'b', name: '其它', config: _drawing('其它预设的画图说明')),
      ],
      defaultPresetId: 'a',
      legacyConfig: const ImageConfig(),
    );
    final voice = VoicePreset.defaultPreset.copyWith(
      synthesis: const VoiceSynthesisSettings(
        providerId: 'p',
        modelId: 'm',
        systemPromptTemplate: '默认音色的语音说明',
      ),
    );
    final tts = TtsConfig(
      enabled: true,
      voicePresets: [voice],
      defaultVoicePresetId: voice.id,
      systemPromptTemplate: '旧全局语音说明',
    );
    final values = <String, Object>{
      PreferencesDrawingPresetStore.storageKey: jsonEncode(catalog.toJson()),
      'aicove.plugins.tts.config': jsonEncode(tts.toJson()),
      'aicove.plugins.sticker.config': jsonEncode(
        const StickerConfig().toJson(),
      ),
      'aicove.plugins.time_awareness.config': jsonEncode(
        TimeAwarenessConfig(
          currentTimePromptTemplate: '现在是{datetime}',
        ).toJson(),
      ),
    };
    SharedPreferences.setMockInitialValues(values);

    final prompts = await PreferencesPluginPromptStore().load();

    // 语音、绘图已迁到提示词包（ADR0092），不再进全局槽位。
    expect(prompts.toJson().keys, isNot(contains('image')));
    expect(prompts.toJson().keys, isNot(contains('tts')));
    expect(prompts.of(PluginPromptSlot.currentTime), '现在是{datetime}');
    expect(prompts.isDefault(PluginPromptSlot.sticker), isTrue);
    final prefs = await SharedPreferences.getInstance();
    for (final entry in values.entries) {
      expect(prefs.getString(entry.key), entry.value);
    }
    // 已迁移后不再从旧键读取。
    await prefs.setString(
      'aicove.plugins.time_awareness.config',
      jsonEncode(TimeAwarenessConfig().toJson()),
    );
    expect(
      (await PreferencesPluginPromptStore().load()).of(
        PluginPromptSlot.currentTime,
      ),
      '现在是{datetime}',
    );
  });

  test('没有旧数据时全部为出厂默认；清空或填回默认即恢复默认', () async {
    SharedPreferences.setMockInitialValues({});
    final prompts = await PreferencesPluginPromptStore().load();
    for (final slot in PluginPromptSlot.values) {
      expect(prompts.isDefault(slot), isTrue);
      expect(prompts.of(slot), slot.defaultText);
    }
    final edited = prompts.withText(PluginPromptSlot.sticker, '少发表情包');
    expect(edited.of(PluginPromptSlot.sticker), '少发表情包');
    expect(edited.withText(PluginPromptSlot.sticker, '  ').overrides, isEmpty);
    expect(
      edited
          .withText(
            PluginPromptSlot.sticker,
            StickerConfig.defaultSystemPromptTemplate,
          )
          .overrides,
      isEmpty,
    );
  });

  test('反序列化保留未知槽位，清除空值和已知默认值', () {
    final prompts = PluginPrompts.fromJson({
      'sticker': '  ${PluginPromptSlot.sticker.defaultText}  ',
      'currentTime': '  自定义时间  ',
      'timeContextGuide': '  ',
      'futureSlot': '  新版本内容  ',
      'futureEmpty': '  ',
      'invalid': 1,
    });
    expect(prompts.toJson(), {
      'currentTime': '  自定义时间  ',
      'futureSlot': '  新版本内容  ',
    });
    expect(
      prompts.withText(PluginPromptSlot.sticker, '新表情').toJson()['futureSlot'],
      '  新版本内容  ',
    );
    expect(PluginPromptSlot.forPlugin('time_awareness'), [
      PluginPromptSlot.currentTime,
      PluginPromptSlot.timeContextGuide,
    ]);
    expect(PluginPromptSlot.forPlugin('unknown'), isEmpty);
    expect(
      TimeAwarenessConfig.defaultSystemGuidePromptTemplate,
      PromptBuiltinDefaults.requireTemplate('time_awareness.system.default'),
    );
  });

  test('请求快照将时间、联网和提醒槽位传给对应插件', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final ref = container.read(_refProvider);
    final prompts = PluginPrompts.fromJson({
      'timeContextGuide': '时间指南 {current_time_explanation}',
      'webSearchTool': '自定义搜索',
      'webFetchTool': '自定义读取',
      'reminderTool': '自定义提醒',
    });
    final time = TimeAwarenessPlugin(TimeAwarenessConfig());
    final web = WebSearchPlugin(
      const WebSearchConfig(
        providers: [
          WebSearchProviderEntry(
            id: 'test',
            type: WebSearchProviderType.exa,
            apiKey: 'test',
          ),
        ],
      ),
    );
    final trigger = TriggerPlugin(const TriggerConfig(), ref);
    final runtime = PluginRuntime.fromPlugins([time, web, trigger]);
    final inputs = PluginRequestInputs(
      ref: ref,
      settings: mapUiModelsToAppSettings(const {}),
      imageConfig: const ImageConfig(),
      voiceRequest: VoiceRequest(ownerId: 'role'),
      pluginPrompts: prompts,
      history: const [],
      previousUserMessageTime: null,
      useFastImageRoute: false,
      useStableImageRoute: true,
      supportsToolCalling: true,
      reminders: const SystemReminderService(),
    );
    final scopes = runtime.requestScopes(
      runtime.snapshot(),
      runtime.selectForRole(null),
      inputs,
    );
    final timeScope = scopes.singleWhere((s) => s.pluginId == 'time_awareness');
    expect(
      await timeScope.prompt(
        const PluginRequestContext(
          userMessage: 'hi',
          supportsToolCalling: true,
        ),
      ),
      contains('时间指南'),
    );
    expect(
      timeScope.timeContextTrace!.config['systemGuidePromptTemplate'],
      '时间指南 {current_time_explanation}',
    );
    expect(
      scopes
          .singleWhere((s) => s.pluginId == 'web_search')
          .tools()
          .map((t) => t.description),
      ['自定义搜索', '自定义读取'],
    );
    expect(
      scopes
          .singleWhere((s) => s.pluginId == 'trigger')
          .tools()
          .map((t) => t.description),
      ['自定义提醒'],
    );
    expect(
      web.getTools().first.description,
      WebSearchPlugin.defaultSearchToolDescription,
    );
    expect(
      trigger.getTools().first.description,
      TriggerPlugin.defaultReminderDescription,
    );
    final config = TimeAwarenessConfig(systemGuidePromptTemplate: '自定义');
    expect(
      TimeAwarenessConfig.fromJson(
        config.toJson(),
      ).copyWith().systemGuidePromptTemplate,
      '自定义',
    );
    expect(
      TimeAwarenessPlugin(
        TimeAwarenessConfig(systemGuidePromptTemplate: '  '),
      ).buildSystemReminderFieldGuide(),
      TimeAwarenessPlugin(
        TimeAwarenessConfig(),
      ).buildSystemReminderFieldGuide(),
    );
  });

  test('主动联系和来电工具支持自定义模板及默认值', () {
    final reminder = ContextAnalyzer.buildReachOutReminder(
      kind: ProactiveReachOutKind.continueChat,
      fireAt: DateTime(2026, 1, 1, 8),
      lastUserAt: null,
      reminderTemplate: '发于 {fire_time}，间隔 {gap}{kind_hint}',
    );
    expect(reminder, contains('间隔 一段时间'));
    expect(reminder, contains('接着刚才没聊完的说'));
    expect(
      buildCallUserTool(onCall: (_) {}, description: '自定义来电').description,
      '自定义来电',
    );
    expect(
      buildCallUserTool(onCall: (_) {}, description: ' ').description,
      PromptBuiltinDefaults.requireTemplate('auto_reply.tool.call_user'),
    );
  });

  test('主动来电草稿使用保存的引导和工具说明', () async {
    final prompts = PluginPrompts.fromJson({
      'proactiveCallHint': '自定义来电引导',
      'proactiveCallTool': '自定义来电工具',
    });
    ApiConfig? sent;
    final container = ProviderContainer(
      overrides: [
        pluginPromptStoreProvider.overrideWithValue(_PromptStore(prompts)),
        proactiveReplyExecutorProvider.overrideWithValue(({
          required config,
          required sessionId,
          required userText,
          required turnId,
        }) async {
          sent = config;
          return const ApiCallResult(
            replyText: '回复',
            processedText: '回复',
            pluginEvents: [],
            toolResults: [],
          );
        }),
      ],
    );
    addTearDown(container.dispose);
    final generator = _DraftGenerator(container.read(_refProvider));
    final now = DateTime(2026);
    await generator.generateDraft(
      conversation: Conversation(
        id: 'test',
        title: 'test',
        displayName: 'test',
        createdAt: now,
        updatedAt: now,
      ),
      reminder: '提醒',
      turnId: 'turn',
      requestTime: now,
      allowCall: true,
    );
    expect(generator.reminder, '提醒\n自定义来电引导');
    expect(sent!.boundTools!.single.description, '自定义来电工具');
  });
}
