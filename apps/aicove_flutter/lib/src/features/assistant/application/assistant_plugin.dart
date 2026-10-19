import '../../agent_plugins/aicove_plugin.dart';
import '../../agent_plugins/plugin_request_context.dart';
import '../../agent_plugins/plugin_request_scope.dart';
import '../../plugins/domain/handlers/ai_tool.dart';
import '../../ui_blocks/application/ui_block_state_store.dart';
import '../../ui_blocks/domain/ui_block_catalog.dart';
import '../../ui_blocks/domain/ui_state_context.dart';
import '../domain/aicove_docs.dart';
import '../domain/assistant_onboarding.dart' show kAicoveAssistantId;
import 'assistant_cards.dart';
import 'assistant_checkup.dart';
import 'assistant_review.dart';
import 'assistant_settings_tools.dart';
import 'assistant_toolset.dart';
import 'assistant_write_tools.dart';

const assistantPluginId = 'aicove_assistant';

/// Abilities of the AIcove assistant role (ADR0073). Installed only for the
/// assistant's own conversation, so its role card can be edited freely
/// without losing them; other roles never see these tools.
///
/// [writes] and [settings] are null where calls cannot go through the
/// review gate (the legacy runner); the assistant then stays read-only.
/// [cards] change nothing until the user acts on them.
AicovePlugin assistantAgentPlugin(
  AssistantToolset toolset, {
  AssistantWriteTools? writes,
  AssistantSettingsTools? settings,
  AssistantCardTools? cards,
  AssistantCheckup? checkup,
}) => AicovePlugin(
  id: assistantPluginId,
  name: 'AIcove 助手',
  exposure: PluginExposure.builtin,
  capabilities: const {AppCapability.request},
  setup: (registrar) => registrar.add(
    AppContributions.requestScope,
    (inputs) => AssistantRequestScope(
      toolset,
      writes: writes,
      settings: settings,
      cards: cards,
      checkup: checkup,
      supportsTools: inputs.supportsToolCalling,
      uiState: () => buildUiStateContext(
        inputs.ref.read(uiBlockStateProvider(kAicoveAssistantId)),
        [
          for (final message in inputs.history)
            if (message.role == 'assistant') message.sourceMessageIdOrSelf,
        ],
      ),
    ),
  ),
);

class AssistantRequestScope extends PluginRequestScope {
  AssistantRequestScope(
    this.toolset, {
    this.writes,
    this.settings,
    this.cards,
    this.checkup,
    required this.supportsTools,
    this.uiState,
  });

  final AssistantToolset toolset;
  final AssistantWriteTools? writes;
  final AssistantSettingsTools? settings;
  final AssistantCardTools? cards;
  final AssistantCheckup? checkup;
  final bool supportsTools;

  /// What the user set in interactive blocks of earlier replies (ADR0073
  /// 交互组件), read when the request is assembled.
  final String? Function()? uiState;

  /// After the time reminder; it describes the screen right now.
  static const uiStateReminderOrder = 900;

  @override
  String get pluginId => assistantPluginId;

  @override
  String get pluginName => 'AIcove 助手';

  @override
  bool get active => true;

  @override
  Future<String?> prompt(PluginRequestContext ctx) async => !supportsTools
      ? assistantPromptWithoutTools
      : writes == null
      ? readOnlyPromptText
      : promptText;

  @override
  List<PluginReminder> reminders(DateTime requestTime) {
    final content = uiState?.call();
    return content == null
        ? const []
        : [PluginReminder(uiStateReminderOrder, content)];
  }

  @override
  List<AITool> tools() => supportsTools
      ? [
          ...toolset.tools(),
          ...?writes?.tools(),
          ...?settings?.tools(),
          ...?cards?.tools(),
          ...?checkup?.tools(),
        ]
      : const [];

  static final promptText = '${_prompt(writable: true)}\n\n${uiBlockPrompt()}';

  static final readOnlyPromptText =
      '${_prompt(writable: false)}\n\n${uiBlockPrompt()}';

  static String _prompt({required bool writable}) => [
    '## 你的工作',
    '你是 AIcove 内置的助手。用户找你主要是为了：写新角色卡、改已有角色卡；'
        '排查插件为什么没生效；找出上下文里的问题（太长、缺内容、指令打架）；'
        '理清酒馆预设、正则、世界书这些复杂配置。目标是让用户在 AIcove 里聊得顺。',
    '',
    '## 怎么做',
    '- 先查后答：涉及 AIcove 的功能、位置、规则时，先用 aicove_docs_read 读资料库；'
        '涉及用户自己的角色、预设、上下文时，用 aicove_list_roles／aicove_read_role／'
        'aicove_list_presets／aicove_read_preset／aicove_inspect_context 看真实数据，不要凭印象猜。',
    '- 用户说「哪里有问题」「帮我检查一下」或排查没头绪时，先跑 aicove_checkup 体检，'
        '再按发现的问题逐个深入。',
    '- 排查插件或上下文问题时，先对目标角色调用 aicove_inspect_context，'
        '根据插件注入状态、原因、工具列表和各来源大小下结论；它不给正文，'
        '要看人设或预设原文就再读角色卡和预设，然后给出具体改法。',
    '- 写或改角色卡时，先读原卡，再给出完整的新版本，说明改了哪里、为什么。',
    if (writable) ...[
      '- 用户要你改，就直接用修改工具改（aicove_update_role、aicove_create_role、'
          'aicove_set_role_plugins、aicove_bind_preset、aicove_toggle_preset_item、'
          'aicove_authorize_regex），改完用一两句话说清改了什么；每次修改用户都能在聊天页撤销。',
      '- 只改用户要求的范围。用户只是问「为什么」时，先说原因和打算怎么改，'
          '用户同意再动手。',
      '- 修改会自动审核，重大修改会请用户确认。工具返回「未获允许」时，'
          '照理由换做法或先问用户，不要原样重试。',
      '- 设置项用 aicove_settings_get／aicove_settings_set，只能改资料库 settings 里列出的；'
          '换到另一家渠道的模型会请用户确认。',
      '- 需要 API Key 时用 aicove_request_key 给用户一张输入卡片，绝不让用户把 Key 发在聊天里；'
          '用户该自己去某个页面时，用 aicove_open_page 给一个按钮。',
    ] else
      '- 你现在只能读不能改。需要修改时，把要改的内容整理好，告诉用户在哪个页面、怎么改；'
          '别假装已经改好。',
    '- 资料库没写、数据里也看不到的事，直说不确定。',
    '',
    '## 资料库（aicove_docs_read 的 doc 参数）',
    for (final doc in kAicoveDocs) '- ${doc.id}：${doc.title}（${doc.summary}）',
  ].join('\n');

  /// Risk of a call in the assistant run: its read tools are read-only,
  /// writes rate themselves, anything else runs as in ordinary chat.
  static AssistantRiskOf riskOf(
    AssistantToolset toolset,
    AssistantWriteTools writes, {
    AssistantSettingsTools? settings,
  }) {
    final reads = {
      for (final tool in toolset.tools()) tool.name,
      ...AssistantCardTools.names,
      AssistantCheckup.toolName,
    };
    return (name, args) => reads.contains(name)
        ? AssistantRisk.readOnly
        : settings?.riskOf(name, args) ?? writes.riskOf(name, args);
  }

  static const promptWithoutTools =
      '## 你的工作\n'
      '你是 AIcove 内置的助手，帮用户写角色卡、排查插件和上下文问题。'
      '当前模型不支持工具调用，你读不到资料库和用户的配置；'
      '遇到需要看真实配置的问题，请用户在「设置 · 模型」换一个支持工具调用的模型，'
      '或者让用户把相关内容贴给你。';
}

/// Same text as [AssistantRequestScope.promptWithoutTools] plus interactive
/// blocks, which need no tools.
final assistantPromptWithoutTools =
    '${AssistantRequestScope.promptWithoutTools}\n\n${uiBlockPrompt()}';
