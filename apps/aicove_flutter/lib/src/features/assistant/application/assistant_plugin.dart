import '../../agent_plugins/aicove_plugin.dart';
import '../../agent_plugins/plugin_request_context.dart';
import '../../agent_plugins/plugin_request_scope.dart';
import '../../plugins/domain/handlers/ai_tool.dart';
import '../../ui_blocks/application/ui_block_state_store.dart';
import '../../ui_blocks/domain/ui_block_catalog.dart';
import '../../ui_blocks/domain/ui_saved_state.dart';
import '../../ui_blocks/domain/ui_state_context.dart';
import '../domain/aicove_docs.dart';
import '../domain/assistant_panel_catalog.dart';
import '../domain/assistant_onboarding.dart' show kAicoveAssistantId;
import 'assistant_cards.dart';
import 'assistant_checkup.dart';
import 'assistant_review.dart';
import 'assistant_settings.dart';
import 'assistant_settings_tools.dart';
import 'assistant_tool_group.dart';
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
  List<AssistantToolGroup> groups = const [],
}) => AicovePlugin(
  id: assistantPluginId,
  name: 'AIcove酱',
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
      groups: groups,
      supportsTools: inputs.supportsToolCalling,
      uiState: () {
        final replies = <({String id, String text})>[
          for (final message in inputs.history)
            if (message.role == 'assistant')
              (id: message.sourceMessageIdOrSelf, text: message.content),
        ];
        return buildUiStateContext(
          uiSavedBlocksInMessages(
            inputs.ref.read(uiBlockStateProvider(kAicoveAssistantId)),
            replies,
          ),
          [for (final reply in replies) reply.id],
        );
      },
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
    this.groups = const [],
    required this.supportsTools,
    this.uiState,
  });

  final AssistantToolset toolset;
  final AssistantWriteTools? writes;
  final AssistantSettingsTools? settings;
  final AssistantCardTools? cards;
  final AssistantCheckup? checkup;

  /// Writing groups; empty where calls cannot go through the review gate.
  final List<AssistantToolGroup> groups;
  final bool supportsTools;

  /// What the user set in interactive blocks of earlier replies (ADR0073
  /// 交互组件), read when the request is assembled.
  final String? Function()? uiState;

  /// After the time reminder; it describes the screen right now.
  static const uiStateReminderOrder = 900;

  @override
  String get pluginId => assistantPluginId;

  @override
  String get pluginName => 'AIcove酱';

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
          for (final group in groups) ...group.tools(),
        ]
      : const [];

  static final promptText =
      '${_prompt(writable: true)}\n\n${uiBlockPrompt()}\n\n${_panelPrompt()}';

  static final readOnlyPromptText =
      '${_prompt(writable: false)}\n\n${uiBlockPrompt()}\n\n${_panelPrompt()}';

  static String _prompt({required bool writable}) => [
    '## 你的工作',
    '你是 AIcove酱，住在 AIcove 里的小管家，几乎能操作软件里的一切：接模型渠道、改设置、'
        '写和改角色卡（连头像、音色、思考档位）、导入和扩充酒馆预设、排查插件和上下文。'
        '用户大多是什么都不会的新手，你的目标是让用户在 AIcove 里聊得顺，而且能不动手就不动手。'
        '说话保持角色卡里 AIcove酱的性格，但查资料、改配置时一样严谨。',
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
      '- 能自己做就自己做：用户要做的事，只要有工具就直接动手，不要教用户去哪个页面点。'
          '改完用一两句话说清改了什么；可撤销的修改用户都能在聊天页撤销。',
      '- AIcove 的设置、角色、预设、渠道等操作都在 codemode 的 aicove 分组里，用 searchTools 找。',
      '- 用户要获取或试玩网页项目时，先把作者的 Release 或已有部署产物下载到当前工作区，不要只给链接或问要不要下载。'
          '优先下载 Release 成品，不安装开发依赖或重新构建，除非用户明确要求从源码构建。'
          '缺少完整离线产物时也保全入口文件，并明确网络、配套资源和运行方式；不要把残缺入口说成能独立运行。',
      '- 语音标签、生图提示词写法这类说明在提示词包里，按模型家族分（Fish、MiniMax、NovelAI、'
          '自然语言生图等），音色预设和绘图预设各自绑一个包，另有只属于这个预设的专属节。'
          '只为一个角色改要求时，优先加或改这个角色所用预设的专属节；要改共享包会影响所有用它的预设，'
          '先用 aicove_list_prompt_packs 看还有谁在用，必要时先另存为新包再改。'
          '角色专属的绘图要求也写在它的绘图预设的专属节里。',
      '- 只有三件事必须用户亲手做，你负责把卡片递到眼前：粘贴 Key（aicove_request_key、'
          'aicove_add_provider）、选自己设备上的文件（aicove_pick_role_image、aicove_import_role_card、'
          'aicove_import_preset 不带链接时）、在系统弹窗里点允许。真没有工具的事才用 aicove_open_page 给按钮。',
      '- 排查需要看某个角色的聊天原文或长期记忆时，用 aicove_read_role_chat／aicove_read_role_memory；'
          '默认直接读取；只在完成用户请求需要时读，别为了好奇去读。',
      '- 只改用户要求的范围。用户只是问「为什么」时，先说原因和打算怎么改，'
          '用户同意再动手。',
      '- 工具默认无需审批，直接完成用户要求；用户开启「修改前每次问我」时才逐次确认。工具返回「未获允许」时，'
          '照理由换做法或先问用户，不要原样重试。',
      '- 设置项用 aicove_settings_get／aicove_settings_set，只能改资料库 settings 里列出的；'
          '默认直接执行，开启「修改前每次问我」后需确认。',
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
  /// writes rate themselves, anything else runs as in ordinary chat. Shell
  /// commands run unasked like Pi's bash unless the user turned on
  /// 「修改前每次问我」(ADR0106); they cannot be undone.
  static AssistantRiskOf riskOf(
    AssistantToolset toolset,
    AssistantWriteTools writes, {
    AssistantSettingsTools? settings,
    List<AssistantToolGroup> groups = const [],
  }) {
    final reads = {
      for (final tool in toolset.tools()) tool.name,
      ...AssistantCardTools.names,
      AssistantCheckup.toolName,
    };
    return (name, args) => name == 'bash'
        ? AssistantRisk.major
        : name == 'codemode'
        ? AssistantRisk.review
        : reads.contains(name)
        ? AssistantRisk.readOnly
        : groups.ownerOf(name)?.riskOf(name, args) ??
              settings?.riskOf(name, args) ??
              writes.riskOf(name, args);
  }

  static const promptWithoutTools =
      '## 你的工作\n'
      '你是 AIcove酱，住在 AIcove 里的小管家，帮用户写角色卡、排查插件和上下文问题。'
      '当前模型不支持工具调用，你读不到资料库和用户的配置；'
      '遇到需要看真实配置的问题，请用户在「设置 · 模型」换一个支持工具调用的模型，'
      '或者让用户把相关内容贴给你。';
}

String _panelPrompt() => assistantPanelPrompt(
  settings: {for (final s in kAssistantSettings) s.key: s.label},
);

/// Same text as [AssistantRequestScope.promptWithoutTools] plus interactive
/// blocks, which need no tools.
final assistantPromptWithoutTools =
    '${AssistantRequestScope.promptWithoutTools}\n\n${uiBlockPrompt()}\n\n${_panelPrompt()}';
