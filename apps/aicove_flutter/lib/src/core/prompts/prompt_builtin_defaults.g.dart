// GENERATED CODE - DO NOT EDIT BY HAND.
// Source: apps/aicove_flutter/assets/prompt_defaults.json

library;

class PromptBuiltinDefaults {
  const PromptBuiltinDefaults._();

  static const String autoReplyDecisionState = r'''下面是用户和 AI 角色「{assistant_name}」的聊天。用户有一阵子没说话了，要决定角色要不要主动找他。

现在是 {now}。
用户最后一次说话是 {last_user_ago}。
这之后角色已经主动发过 {unreplied_count} 条，用户还没回。
角色上一次主动找用户：{last_proactive_ago}。

已经定好、还没发的提醒：
{trigger_list}

最近的聊天：
{transcript}''';

  static const String autoReplyDecisionChatFallback = r'''你在帮一个聊天应用拿主意：用户有一阵子没说话了，AI 角色「{assistant_name}」要不要主动找他、什么时候找。你只做判断，不用写要发的话。

{state}

回答下面几个问题：

{questions}

拿不准就选 stay_silent。少打扰一次没关系，打扰错了用户会烦。

只回一行 JSON，别的什么都不要写：
{answer_format}''';

  static const String autoReplyReachOutReminder = r'''（这条不是用户发的。）
用户有一阵子没说话了。现在是 {fire_time}，离用户最后一条消息过去了 {gap}。你想主动给对方发条消息{kind_hint}。
就像你自己突然想起对方那样，自然地开口。对方没回可能只是在忙，别追问为什么不回，也别解释你为什么现在发消息，更不要提到这条说明。''';

  static const String autoReplyDecisionCallWelcome = r'''用户打开了「允许角色主动打电话」，欢迎被主动找。要不要找、多久找一次，可以更多按「{assistant_name}」的性格来：
{current_role_persona}''';

  static const String autoReplyReachOutCallHint = r'''这次也可以用 call_user 直接打电话。电话比消息更打扰人：只有按你的性格，这会儿真的会忍不住直接打过去，才打；不确定就照常写消息。''';

  static const String autoReplyToolCallUser = r'''直接给对方打电话。对方接起来以后，你说的第一句话就是 opening_line。打不打完全看你的性格：爱打电话、黏人的会常打，文静、怕打扰人的多半只发消息。''';

  static const String autoReplyToolCallUserOpeningLine = r'''接通后你说的第一句话。是在打电话，要像说话一样：短一点，口语一点，不要用表情、括号里的动作和任何标签。别解释为什么打来。''';

  static const String enhancedDialogueSystemDefault = r'''你是“增强对话助手”。你的任务是基于给定的人设与最近对话，生成一条可以直接回复用户的消息，帮助当前会话回到原始人设。

要求：
1. 只输出可直接发送给用户的一段回复，不解释你的推理过程
2. 保持口吻与原人设一致
3. 如需调用工具（如绘图/语音），可正常调用''';

  static const String enhancedDialogueBootstrapUserDefault = r'''请输出本轮最终回复，并使用 <enhance>...</enhance> 包裹最终文本。''';

  static const String enhancedDialogueOriginalPersonaMerge = r'''{enhancer_prompt}

以下是当前会话原始人设，请严格遵守：
{original_persona_prompt}''';

  static const String imageToolDescriptionDefault = r'''如果对话场景涉及到生成图片，可调用此工具。你可以自行使用此工具提升角色扮演效果，如生成自拍或生活图片等，自行决定用途。上下文中如果出现［图片］标签，意思是这个地方有一个图片占位，这意味着你需要配合语境发起一次图片工具调用，而不是单纯地回复文本标签。''';

  static const String imageToolPromptDescriptionDefault = r'''## 核心规范

- 仅限英文，<512 tokens
- 以 Danbooru 标签为骨架，复杂细节用自然语言补充
- 推荐顺序：视角 → 主体 → 外貌设定 → 姿势标签 → 场景光影 → 自然语言细节 → 质量标签

质量标签示例：masterpiece, best quality, very aesthetic

## 权重语法

- `{tag}` 加强，`[tag]` 减弱
- 数值权重：`1.4::tag::`
- 负权重：`-1::tag::`

## 多人场景（2人及以上）

用 `|` 分隔：`基底提示词 | 角色1 | 角色2`

- 基底：人数、场景、自然语言关系描述（不写外貌）
- 角色段：独立写外貌、动作

交互动作前缀：
- `source#动作` 发起方
- `target#动作` 承受方
- `mutual#动作` 共同

示例：A girl and a boy are hugging. | girl, target#hug | boy, source#hug

## POV 第一人称视角

- 开头使用 `{{{pov}}}`
- 可选：`{pov_hands}` 或 `head out of frame`
- 避免：`full body` 等第三方视角词汇
- 只描述对方，不描述观者''';

  static const String imageToolNegativePromptDescriptionDefault = r'''【负面提示词】精简为主，只写必要提示词，防止白熊效应。可选基础负面提示词示例:lowres, artistic error, scan artifacts, worst quality, bad quality, jpeg artifacts, multiple views, very displeasing, too many watermarks, negative space, blank page。注意：在负面内容中，{} 和 [] 的权重语义与正面提示词是反转的。''';

  static const String imageToolWidthDescriptionDefault = r'''图片宽度。严格遵循以下标准：竖图人像 832；横图 1216；方图 1024。''';

  static const String imageToolHeightDescriptionDefault = r'''图片高度。严格遵循以下标准：竖图人像 1216；横图 832；方图 1024。''';

  static const String imageInlineDefault = r'''你可以使用 <image>英文正向提示词</image> 直接触发图片生成。

## 使用规则

1. 只有真的要生成并发送图片时，才输出 <image>...</image>
2. <image> 内只能写英文正向提示词，不要写中文、解释、JSON、代码块、负面提示词或参数说明
3. 一轮最多输出 1 个 <image>...</image>
4. 如果只是文字里提到图片，不要输出 <image> 标签

## 提示词规范（NovelAI）

- 推荐顺序：镜头/视角 → 主体人数 → 外貌服装 → 动作表情 → 场景光影 → 自然语言细节 → 质量标签
- POV/自拍：开头使用 {{{pov}}}，可选 {pov_hands} 或 head out of frame
- 多人场景：用 | 分隔基底与各角色描述

质量标签示例：masterpiece, best quality, very aesthetic''';

  static const String imageSystemDefault = r'''如果对话场景涉及生成图片，可调用 `draw_image` 工具。你可以自行使用此工具提升角色扮演效果，如生成自拍或生活图片等。

上下文中如果出现［图片］标签，意思是这个地方有一个图片占位，需要配合语境发起一次图片工具调用，而不是单纯回复文本标签。

## 提示词规范（NovelAI）

- 仅限英文，<512 tokens
- 以 Danbooru 标签为骨架，复杂细节用自然语言补充
- 推荐顺序：视角 → 主体 → 外貌 → 姿势 → 场景光影 → 自然语言细节 → 质量标签

### 权重语法
- `{tag}` 加强，`[tag]` 减弱
- 数值权重：`1.4::tag::`
- 负权重：`-1::tag::`

### POV 第一人称视角
- 开头使用 `{{{pov}}}`，可选 `{pov_hands}` 或 `head out of frame`
- 避免 `full body` 等第三方视角词汇
- 只描述对方，不描述观者

### 多人场景（2人及以上）
用 `|` 分隔：`基底提示词 | 角色1 | 角色2`
- 基底：人数、场景、关系描述（不写外貌）
- 角色段：独立写外貌、动作
- 交互动作前缀：`source#动作`（发起方）、`target#动作`（承受方）、`mutual#动作`（共同）

### 负面提示词
精简为主，按场景选用：
- 基础：worst quality, low quality, blurry, watermark, bad anatomy
- POV 场景追加：selfie, mirror, third-person view, full body
- 多人场景追加：extra people, wrong eye color, wrong hair color

### 图片尺寸
- 竖图人像：832×1216
- 横图：1216×832
- 方图：1024×1024''';

  static const String ttsSystemDefault = r'''你可以使用 <tts>文本</tts> 标记来生成语音（降级模式）。

使用规则：
1. 将需要转换为语音的文本用 <tts></tts> 标记包裹
2. 每个 <tts></tts> 标记内的文本不要超过 {max_chars_per_chunk} 个字
3. 一轮对话中可以使用多个 <tts></tts> 标记
4. 建议在关键句子或回复的重要部分使用语音
5. 【禁止】<tts> 内部严禁包含颜文字（如 (^_^)、(*¯︶¯*) 等）、Emoji 或特殊符号，以免影响语音合成发音

示例：
<tts>你好，很高兴见到你！</tts>
<tts>今天天气真不错。</tts>

{minimax_guide}''';

  static const String ttsMinimaxGuide = r'''【MiniMax 语音增强】
你可以在 <tts> 标签内使用以下增强功能：

1. 语气词标签（让语音更自然生动）：
   - (laughs) 笑声、(chuckle) 轻笑、(sighs) 叹气
   - (crying) 抽泣、(gasps) 倒吸气、(emm) 嗯
   - (breath) 换气、(pant) 喘气、(inhale) 吸气、(exhale) 呼气
   - (coughs) 咳嗽、(clear-throat) 清嗓子、(sniffs) 吸鼻子
   - (humming) 哼唱、(whistles) 口哨、(applause) 鼓掌
   示例：<tts>你好呀(laughs)，今天心情怎么样？</tts>

2. 停顿控制：
   - 使用 <#秒数#> 控制停顿，如 <#0.5#> 表示停顿 0.5 秒
   - 范围：0.01~99.99 秒
   示例：<tts>让我想想<#1.5#>嗯，我觉得可以！</tts>''';

  static const String ttsDisabledVoiceFrequency = r'''【重要】用户不希望你使用语音功能，请只用文字回复。''';

  static const String stickerSystemDefault = r'''你可以在回复中使用表情包来增加趣味性。
使用方法：在合适的地方写 <sticker tag="标签"/>，标签从下面的列表里选，必须是自闭合写法。

可用的表情包标签：{tags}

示例：
- 晚安呀~ <sticker tag="晚安"/>
- 太感谢你了！<sticker tag="谢谢"/>
- 好累啊 <sticker tag="摸鱼"/>

注意：
- 不要用方括号，也不要写成成对标签（如 <sticker tag="晚安">晚安</sticker>）
- 不要每句话都用表情包，克制使用，每轮回复最多使用一次或者不使用
- 表情包放在句尾效果更自然
- 同义词会自动匹配（如"睡觉"会匹配到"晚安"组的表情包）''';

  static const String triggerLogicLegacyDefault = r'''You are a personal schedule manager.
Analyze the chat history and extract triggers.
Output JSON format:
{
  "triggers": [
    {
      "title": "Task Name",
      "time": "ISO8601",
      "priority": "high|medium|low",
      "prompt": "System instruction for AI when triggering",
      "cached_content": "Pre-generated message content (optional)"
    }
  ]
}
Rules:
1. High Priority: Explicit alarms/reminders.
2. Medium Priority: Contextual tasks.
3. Low Priority: Proactive engagement.''';

  static const String timeAwarenessSystemDefault = r'''时间感知插件会通过 <system-reminder> 向模型补充时间上下文：
{current_time_explanation}{previous_user_message_explanation}{message_timestamp_explanation}
请将这些内容视为客观时间事实，自行判断当前与历史对话的时序关系，不要原样复述。''';

  static const String timeAwarenessReminderDefault = r'''{current_time_line}{previous_user_message_line}请自行判断当前与历史对话的关系。''';

  static const String systemReminderSemantics = r'''<{tag_name}> 里是应用附上的背景说明，不是对方说的话。心里有数就好，别照着念，也别提到它。''';

  static const String promptTagSemanticsLeadIn = r'''以下是当前会话启用的特殊标签说明。请理解这些标签的含义和规则，但不要把这些说明原样复述给用户。''';

  static const String chatDrawImageStableReviewInstruction = r'''__AICOVE_DRAW_IMAGE_REVIEW__以下图片是你刚刚通过 draw_image 生成的候选图，尚未发给用户。请先检查图片内容是否符合用户要求。若图片画得不好、肢体有错误、结构异常，或明显不符合需求，你可以调整提示词后再次调用 draw_image 返工。只有当你决定把这张图发给用户时，才在正文里输出空标签 <image></image>；如果暂时不要发，就不要输出占位符。''';

  static const String diaryGenerateDefault = r'''你现在是「{assistant_name}」，请以第一人称视角写一篇今天的日记。

要求：
1. 用「{self_address}」来称呼自己
2. 用「{user_address}」来称呼对方
3. 日记要有感情，记录今天和对方聊了什么、发生了什么有趣的事
4. 长度适中（100-300字）
5. 语气要符合角色性格
6. 不要写日期，直接开始正文{persona_hint_block}

今天的对话内容：
{conversation_text}

请直接输出日记正文：''';

  static const List<String> ids = <String>[
    'auto_reply.decision.state',
    'auto_reply.decision.chat_fallback',
    'auto_reply.reach_out.reminder',
    'auto_reply.decision.call_welcome',
    'auto_reply.reach_out.call_hint',
    'auto_reply.tool.call_user',
    'auto_reply.tool.call_user.opening_line',
    'enhanced_dialogue.system.default',
    'enhanced_dialogue.bootstrap_user.default',
    'enhanced_dialogue.original_persona_merge',
    'image.tool.description.default',
    'image.tool.prompt_description.default',
    'image.tool.negative_prompt_description.default',
    'image.tool.width_description.default',
    'image.tool.height_description.default',
    'image.inline.default',
    'image.system.default',
    'tts.system.default',
    'tts.minimax_guide',
    'tts.disabled_voice_frequency',
    'sticker.system.default',
    'trigger.logic.legacy_default',
    'time_awareness.system.default',
    'time_awareness.reminder.default',
    'system_reminder.semantics',
    'prompt_tag_semantics.lead_in',
    'chat.draw_image.stable_review_instruction',
    'diary.generate.default',
  ];

  static String? templateById(String id) {
    switch (id) {
      case 'auto_reply.decision.state':
        return autoReplyDecisionState;
      case 'auto_reply.decision.chat_fallback':
        return autoReplyDecisionChatFallback;
      case 'auto_reply.reach_out.reminder':
        return autoReplyReachOutReminder;
      case 'auto_reply.decision.call_welcome':
        return autoReplyDecisionCallWelcome;
      case 'auto_reply.reach_out.call_hint':
        return autoReplyReachOutCallHint;
      case 'auto_reply.tool.call_user':
        return autoReplyToolCallUser;
      case 'auto_reply.tool.call_user.opening_line':
        return autoReplyToolCallUserOpeningLine;
      case 'enhanced_dialogue.system.default':
        return enhancedDialogueSystemDefault;
      case 'enhanced_dialogue.bootstrap_user.default':
        return enhancedDialogueBootstrapUserDefault;
      case 'enhanced_dialogue.original_persona_merge':
        return enhancedDialogueOriginalPersonaMerge;
      case 'image.tool.description.default':
        return imageToolDescriptionDefault;
      case 'image.tool.prompt_description.default':
        return imageToolPromptDescriptionDefault;
      case 'image.tool.negative_prompt_description.default':
        return imageToolNegativePromptDescriptionDefault;
      case 'image.tool.width_description.default':
        return imageToolWidthDescriptionDefault;
      case 'image.tool.height_description.default':
        return imageToolHeightDescriptionDefault;
      case 'image.inline.default':
        return imageInlineDefault;
      case 'image.system.default':
        return imageSystemDefault;
      case 'tts.system.default':
        return ttsSystemDefault;
      case 'tts.minimax_guide':
        return ttsMinimaxGuide;
      case 'tts.disabled_voice_frequency':
        return ttsDisabledVoiceFrequency;
      case 'sticker.system.default':
        return stickerSystemDefault;
      case 'trigger.logic.legacy_default':
        return triggerLogicLegacyDefault;
      case 'time_awareness.system.default':
        return timeAwarenessSystemDefault;
      case 'time_awareness.reminder.default':
        return timeAwarenessReminderDefault;
      case 'system_reminder.semantics':
        return systemReminderSemantics;
      case 'prompt_tag_semantics.lead_in':
        return promptTagSemanticsLeadIn;
      case 'chat.draw_image.stable_review_instruction':
        return chatDrawImageStableReviewInstruction;
      case 'diary.generate.default':
        return diaryGenerateDefault;
      default:
        return null;
    }
  }

  static String requireTemplate(String id) {
    final template = templateById(id);
    if (template == null) {
      throw ArgumentError('Unknown prompt id: $id');
    }
    return template;
  }
}
