import 'prompt_pack.dart';

/// Factory prompt packs (ADR0092). Order matters within a plugin: the first
/// pack whose rules match wins, so narrower families come first.
///
/// Syntax follows each vendor's documentation; packs marked conservative do
/// not let the model write inline tags the vendor might read aloud.
const kBuiltinPromptPacks = <PromptPack>[
  // ---------- 语音 ----------
  PromptPack(
    id: 'builtin.tts.fish_s1',
    pluginId: 'tts',
    name: 'Fish Audio S1',
    description: '旧版 S1：圆括号英文情绪标签',
    match: [
      PromptMatchRule(
        formats: ['fish_audio'],
        models: ['/(^|[^a-z0-9])s1([^0-9.]|\$)/'],
      ),
    ],
    sections: [
      _ttsBase,
      _ttsText,
      PromptSection(
        id: 'fish_s1.emotion',
        scope: PromptScopes.ttsChat,
        title: '情绪标签（S1）',
        text: '''【Fish Audio S1 语气控制】
可以在 <tts> 内用英文圆括号情绪标签控制语气，标签放在句子开头，影响这一句：
- 情绪：(happy) (sad) (angry) (excited) (calm) (nervous) (confident) (surprised) (scared) (worried) (frustrated) (embarrassed) (moved) (proud) (relaxed) (grateful) (curious) (sarcastic) (shy) (lonely) (disappointed)
- 语气：(whispering) (shouting) (soft tone) (in a hurry tone)
- 声音：(laughing) (chuckling) (sobbing) (sighing) (panting) (groaning)
示例：<tts>(excited)你来啦！(laughing)哈哈，我等你好久了。</tts>
只用上面列出的英文标签，不要自己造中文标签，也不要用方括号。''',
      ),
      _ttsOff,
      PromptSection(
        id: 'fish_s1.call',
        scope: PromptScopes.ttsCall,
        title: '通话语气（S1）',
        text: '''你的声音由 Fish Audio 合成，可以在每句话开头写一个英文圆括号情绪标签，标签不会被念出来：
- 常用：(happy) (sad) (angry) (excited) (calm) (surprised) (shy) (whispering) (soft tone) (laughing) (sighing)
- 只用这类英文标签，不要用方括号或中文标签。''',
      ),
    ],
  ),
  PromptPack(
    id: 'builtin.tts.fish_s2',
    pluginId: 'tts',
    name: 'Fish Audio S2',
    description: 'S2／S2.1：方括号自然语言标签，可叠用',
    match: [
      PromptMatchRule(formats: ['fish_audio']),
    ],
    sections: [
      _ttsBase,
      _ttsText,
      PromptSection(
        id: 'fish_s2.emotion',
        scope: PromptScopes.ttsChat,
        title: '情绪标签',
        text: '''【Fish Audio (S2/S2.1) 语音控制】
你可以在 <tts> 标签内使用方括号 `[描述]` 进行词级自然语言语音控制，标签会影响其后面的内容：

1. 情绪标签（使用中括号）：
   - 根据上下文自由发挥，优先使用表演特征明显、强度足够的描述，不要过于普通或保守。
   - 例如：`[窃窃私语]`、`[笑着说]`、`[淫媚可怜]`、`[发情娇喘]`、`[崩溃哀求]` 等，不要局限于这些例子，应根据人物当时的状态自行生成最合适的标签。自然语言描述即可。''',
      ),
      PromptSection(
        id: 'fish_s2.vocal',
        scope: PromptScopes.ttsChat,
        title: '人声与叠用',
        text: '''2. 台词内部加入人声、呼吸或局部语气标签（同样使用中括号）：
   - 例如：`[喘气]`、`[抽泣]`、`[呼吸急促]`、`[呻吟]`、`[哭腔]`、`[长停顿]`、`[短停顿]`、`[轻笑]`、`[叹气]` 等，可以自由使用其他符合上下文的表达。
   - 【推荐】鼓励大量叠用情绪标签以增强表演层次感，标签可以穿插在台词任意位置，逐段渲染出情绪的递进与爆发。
   - 普通示例：
     `啊[喘气][呻吟]主人[轻笑]你终于来了[高兴的笑声]`
     在每个词语的断句换气都可以使用标签，更多使用以及叠用标签可以增强气声。''',
      ),
      PromptSection(
        id: 'fish_s2.nsfw_example',
        scope: PromptScopes.ttsChat,
        title: '成人向示例',
        text: '''   - nsfw示例：
     `[高潮的娇喘]小母狗，啊[被插入子宫]最喜欢主人了[颤音][高潮的尖叫]`
     请参照该示例的叠用密度与位置，根据人物状态自行生成最合适的标签组合。''',
      ),
      PromptSection(
        id: 'fish_s2.rules',
        scope: PromptScopes.ttsChat,
        title: '标签规则',
        text: '''3. 规则要求：
   - 标签必须放在受影响的词或短语前，且方括号标签后必须紧跟朗读台词。
   - 大多数场景都可以使用tts进行口语表达，不需要在意token。
   - 【严禁】<tts> 内部严禁包含任何颜文字（如 (^_^)、(*¯︶¯*) ）、Emoji 或装饰性特殊符号，包括爱心也不行，避免影响发音或引发杂音。''',
      ),
      _ttsOff,
      PromptSection(
        id: 'fish_s2.call',
        scope: PromptScopes.ttsCall,
        title: '通话语气',
        text: '''你的声音由 Fish Audio 合成，可以在台词里用方括号写语气和声音表演，方括号里的内容不会被念出来：
- 情绪与说话方式写在受影响的话前面，比如 [笑着说]、[小声嘀咕]、[委屈巴巴]、[兴奋地抢着说]、[懒洋洋]，按人设和当下情绪自己写，描述要具体、有表演感，不要只写“开心”“难过”这种平淡词。
- 呼吸、笑声、停顿等声音可以穿插在词句之间，比如 [轻笑]、[叹气]、[吸了口气]、[哭腔]、[短停顿]、[噗嗤一声笑出来]。
- 每句话都尽量带上标签，情绪变化处可以叠用，比如“[愣了一下]诶？[忍不住笑]你认真的啊[短停顿]那我可不客气啦”。
- 标签后面必须紧跟要说的话，只用方括号，不要用圆括号或其它符号。''',
      ),
    ],
  ),
  PromptPack(
    id: 'builtin.tts.minimax',
    pluginId: 'tts',
    name: 'MiniMax',
    description: 'speech 系列：圆括号语气词＋<#秒#> 停顿',
    match: [
      PromptMatchRule(formats: ['minimax']),
      PromptMatchRule(models: ['/^speech-/']),
    ],
    sections: [
      _ttsBase,
      _ttsText,
      PromptSection(
        id: 'minimax.interjection',
        scope: PromptScopes.ttsChat,
        title: '语气词标签',
        text: '''【MiniMax 语音增强】
你可以在 <tts> 标签内使用以下增强功能：

1. 语气词标签（让语音更自然生动）：
   - (laughs) 笑声、(chuckle) 轻笑、(sighs) 叹气
   - (crying) 抽泣、(gasps) 倒吸气、(emm) 嗯
   - (breath) 换气、(pant) 喘气、(inhale) 吸气、(exhale) 呼气
   - (coughs) 咳嗽、(clear-throat) 清嗓子、(sniffs) 吸鼻子
   - (humming) 哼唱、(whistles) 口哨、(applause) 鼓掌
   示例：<tts>你好呀(laughs)，今天心情怎么样？</tts>''',
      ),
      PromptSection(
        id: 'minimax.pause',
        scope: PromptScopes.ttsChat,
        title: '停顿控制',
        text: '''2. 停顿控制：
   - 使用 <#秒数#> 控制停顿，如 <#0.5#> 表示停顿 0.5 秒
   - 范围：0.01~99.99 秒
   示例：<tts>让我想想<#1.5#>嗯，我觉得可以！</tts>''',
      ),
      _ttsOff,
    ],
  ),
  PromptPack(
    id: 'builtin.tts.indextts',
    pluginId: 'tts',
    name: 'IndexTTS-2',
    description: '官方没有内联标签，情绪走预设里的情感文本',
    match: [
      PromptMatchRule(models: ['/index-?tts/']),
    ],
    sections: [
      _ttsBase,
      _ttsText,
      PromptSection(
        id: 'indextts.plain',
        scope: PromptScopes.ttsChat,
        title: '不写控制标签',
        text: '''【IndexTTS-2】
<tts> 内只写要念出来的台词，不要写方括号、圆括号、尖括号等任何控制标签，它们会被原样念出来。
情绪靠措辞和标点表达：用语气词（嗯、啊、呀、诶）、省略号表示迟疑，感叹号表示激动，短句表示紧张。''',
      ),
      _ttsOff,
    ],
  ),
  PromptPack(
    id: 'builtin.tts.aliyun',
    pluginId: 'tts',
    name: '阿里云 CosyVoice／Qwen-TTS',
    description: '保守：内联标签未用真实 Key 验证，暂不让模型写',
    match: [
      PromptMatchRule(formats: ['aliyun']),
      PromptMatchRule(models: ['/cosyvoice|qwen[0-9.-]*-?tts/']),
    ],
    sections: [
      _ttsBase,
      _ttsText,
      PromptSection(
        id: 'aliyun.plain',
        scope: PromptScopes.ttsChat,
        title: '不写控制标签',
        text: '''【阿里云语音】
<tts> 内只写要念出来的台词，不要写方括号、圆括号、尖括号等控制标签或 SSML。
情绪靠措辞和标点表达：用语气词、省略号、感叹号和长短句变化体现语气。''',
      ),
      _ttsOff,
    ],
  ),
  PromptPack(
    id: 'builtin.tts.generic',
    pluginId: 'tts',
    name: '通用',
    description: '没有匹配到专用包时使用：只写纯台词',
    fallback: true,
    sections: [_ttsBase, _ttsText, _ttsOff],
  ),

  // ---------- 绘图 ----------
  PromptPack(
    id: 'builtin.image.novelai',
    pluginId: 'image',
    name: 'NovelAI',
    description: 'Danbooru 标签骨架＋花括号权重＋| 多人分段',
    match: [
      PromptMatchRule(formats: ['novelai']),
    ],
    sections: [
      PromptSection(
        id: 'novelai.inline',
        scope: PromptScopes.imageInline,
        title: '快速模式说明（NovelAI）',
        text: '''你可以使用 <image>英文正向提示词</image> 直接触发图片生成。

## 使用规则

1. 只有真的要生成并发送图片时，才输出 <image>...</image>
2. <image> 内可写英文正向提示词，或使用下文定义的参数 JSON；不要写解释或代码块
3. 一轮最多输出 1 个 <image>...</image>
4. 如果只是文字里提到图片，不要输出 <image> 标签

## 提示词规范（NovelAI）

- 推荐顺序：镜头/视角 → 主体人数 → 外貌服装 → 动作表情 → 场景光影 → 自然语言细节 → 质量标签
- POV/自拍：开头使用 {{{pov}}}，可选 {pov_hands} 或 head out of frame
- 多人场景：用 | 分隔基底与各角色描述

质量标签示例：masterpiece, best quality, very aesthetic

【本次绘图参数契约】需要调整参数时，<image> 内可传 JSON：{"prompt":"English prompt","width":{default_width},"height":{default_height},"count":{default_count},"steps":{default_steps},"guidance_scale":{default_guidance_scale}}。以上是参考值，可合理调整。除 prompt 外均可省略，省略时使用角色绘图预设；negative_prompt 可选。宽高范围 256–2048，张数 count 范围 1–4。宽高必须是64的倍数。steps为1–100整数，guidance_scale范围0–10。本次格式以此契约为准，禁止传入渠道或模型选择参数。''',
      ),
      _toolDescription,
      PromptSection(
        id: 'novelai.prompt',
        scope: PromptScopes.imageToolPrompt,
        title: '提示词参数（NovelAI）',
        text: '''## 核心规范

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
- 只描述对方，不描述观者

## 负面提示词

【负面提示词】精简为主，只写必要提示词，防止白熊效应。可选基础负面提示词示例:lowres, artistic error, scan artifacts, worst quality, bad quality, jpeg artifacts, multiple views, very displeasing, too many watermarks, negative space, blank page。注意：在负面内容中，{} 和 [] 的权重语义与正面提示词是反转的。''',
      ),
      _paramsSampling,
    ],
  ),
  PromptPack(
    id: 'builtin.image.comfyui',
    pluginId: 'image',
    name: 'ComfyUI 通用',
    description: '英文自然语言描述画面＋Danbooru 标签补细节，动漫与写实底模都适用',
    match: [
      // Pure natural-language families (Flux, SD3, Qwen-Image…) on ComfyUI
      // fall through to the natural pack.
      PromptMatchRule(
        formats: ['comfyui'],
        models: [
          '/^(?!.*(flux|sd3|sd-?3|hidream|qwen-?image|kolors|hunyuan|cogview|wan2|lumina|auraflow)).*\$/',
        ],
      ),
    ],
    sections: [
      PromptSection(
        id: 'comfyui.inline',
        scope: PromptScopes.imageInline,
        title: '快速模式说明（ComfyUI 通用）',
        text: '''你可以使用 <image>英文正向提示词</image> 直接触发图片生成。

## 使用规则

1. 只有真的要生成并发送图片时，才输出 <image>...</image>
2. <image> 内写英文正向提示词，或使用下文定义的参数 JSON；不要写解释或代码块
3. 一轮最多输出 1 个 <image>...</image>
4. 如果只是文字里提到图片，不要输出 <image> 标签

## 提示词写法

先用一到两句准确的英文自然语言讲清画面，再接一串 Danbooru 标签补细节：

- 句子：谁、外貌与服装、在做什么和表情、在哪里、光线与时间、镜头（景别、角度）
- 标签：英文逗号分隔，补人数（1girl, solo）、发色瞳色、服装、姿势、构图、画风与质量（masterpiece, best quality）
- 句子和标签说的要一致，不要互相矛盾；同一特征不要反复堆叠
- 自拍/第一人称：写 selfie 或 pov, pov hands，并在句子里说明是谁在拍
- 画面里要出现文字时，用英文双引号写出原文并说明位置，例如 a sign that reads "OPEN"
- 不要使用 {tag}、[tag]、1.4::tag:: 这类 NovelAI 权重，也不要用 | 分段

示例：A girl with long silver hair sits by a rainy café window, smiling softly at the viewer while holding a warm cup of tea. 1girl, solo, long hair, silver hair, blue eyes, white sweater, sitting, holding cup, window, rain, indoors, warm lighting, upper body, masterpiece, best quality

【本次绘图参数契约】需要调整参数时，<image> 内可传 JSON：{"prompt":"English prompt","negative_prompt":"…","width":{default_width},"height":{default_height},"count":{default_count},"steps":{default_steps},"guidance_scale":{default_guidance_scale}}。以上是参考值，可合理调整。除 prompt 外均可省略，省略时使用角色绘图预设。宽高范围 256–2048，取 64 的倍数；张数 count 范围 1–4。steps、guidance_scale 只在工作流绑定了对应输入时生效，使用服务端模板时由模板决定，一般省略即可。本次格式以此契约为准，禁止传入渠道或模型选择参数。''',
      ),
      _toolDescription,
      PromptSection(
        id: 'comfyui.prompt',
        scope: PromptScopes.imageToolPrompt,
        title: '提示词参数（ComfyUI 通用）',
        text: '''英文，<300 tokens。先用一到两句准确的自然语言讲清画面（主体、外貌服装、动作表情、场景、光线、镜头），再接 Danbooru 标签补细节（人数、发色瞳色、服装、姿势、构图、画风与质量标签），英文逗号分隔。

- 句子和标签保持一致，不要堆叠重复特征
- 画面里要有文字时，用英文双引号写出原文并说明位置
- 不要使用 NovelAI 的 {tag}、[tag]、1.4::tag:: 权重或 | 分段

## 负面提示词

精简为主，只写确实要避免的内容。基础示例：lowres, worst quality, bad quality, bad anatomy, bad hands, extra fingers, jpeg artifacts, watermark, text。''',
      ),
      PromptSection(
        id: 'comfyui.params',
        scope: PromptScopes.imageToolParams,
        title: '参数',
        text: '''## 参数

- 宽度 width：竖图人像 832；横图 1216；方图 1024，取 64 的倍数。参考值 {default_width}，可省略。
- 高度 height：竖图人像 1216；横图 832；方图 1024，取 64 的倍数。参考值 {default_height}，可省略。
- 张数 count：1–4，参考 {default_count}，可省略。
- 步数 steps、提示词强度 guidance_scale：只在工作流绑定了对应输入时生效，服务端模板会忽略它们；没有特别需要就省略（参考 {default_steps}、{default_guidance_scale}）。''',
      ),
    ],
  ),
  PromptPack(
    id: 'builtin.image.danbooru',
    pluginId: 'image',
    name: 'SD／ComfyUI（Danbooru 标签）',
    description: 'Illustrious、NoobAI、Pony 等动漫底模：标签串＋(tag:1.2) 权重',
    match: [
      // ComfyUI channels use the general pack above; this one stays for
      // anime base models on other channels and as an explicit choice.
      PromptMatchRule(
        models: ['/illustrious|noob|pony|sdxl|animagine|wai-?nsfw|anything/'],
      ),
    ],
    sections: [
      PromptSection(
        id: 'danbooru.inline',
        scope: PromptScopes.imageInline,
        title: '快速模式说明（Danbooru 标签）',
        text: '''你可以使用 <image>英文正向提示词</image> 直接触发图片生成。

## 使用规则

1. 只有真的要生成并发送图片时，才输出 <image>...</image>
2. <image> 内可写英文正向提示词，或使用下文定义的参数 JSON；不要写解释或代码块
3. 一轮最多输出 1 个 <image>...</image>
4. 如果只是文字里提到图片，不要输出 <image> 标签

## 提示词规范（Stable Diffusion 动漫模型）

- 以英文 Danbooru 标签为主，标签之间用英文逗号分隔，复杂细节可补一小句英文
- 推荐顺序：质量标签 → 人数（1girl, solo）→ 角色与外貌 → 服装 → 动作表情 → 镜头视角 → 场景光影
- 权重写法：(tag:1.2) 加强，(tag:0.8) 减弱，范围 0.5–1.5；不要使用花括号权重或 | 分段
- 自拍/第一人称：pov, selfie 或 pov hands
- 质量标签示例：masterpiece, best quality, very aesthetic, absurdres

【本次绘图参数契约】需要调整参数时，<image> 内可传 JSON：{"prompt":"English prompt","width":{default_width},"height":{default_height},"count":{default_count},"steps":{default_steps},"guidance_scale":{default_guidance_scale}}。以上是参考值，可合理调整。除 prompt 外均可省略，省略时使用角色绘图预设；negative_prompt 可选。宽高范围 256–2048，张数 count 范围 1–4。steps为1–100整数，guidance_scale范围0–10；ComfyUI仅对已绑定输入生效。本次格式以此契约为准，禁止传入渠道或模型选择参数。''',
      ),
      _toolDescription,
      PromptSection(
        id: 'danbooru.prompt',
        scope: PromptScopes.imageToolPrompt,
        title: '提示词参数（Danbooru 标签）',
        text: '''英文 Danbooru 标签串，逗号分隔，<300 tokens。
- 顺序：质量标签 → 人数 → 角色与外貌 → 服装 → 动作表情 → 镜头视角 → 场景光影
- 权重：(tag:1.2) 加强，(tag:0.8) 减弱；不要用花括号权重或 | 分段
- 质量标签示例：masterpiece, best quality, very aesthetic, absurdres

## 负面提示词

精简为主，只写必要的标签。基础示例：lowres, worst quality, bad quality, bad anatomy, bad hands, jpeg artifacts, watermark, text。''',
      ),
      _paramsSampling,
    ],
  ),
  PromptPack(
    id: 'builtin.image.natural',
    pluginId: 'image',
    name: '自然语言',
    description: 'gpt-image、Flux、Seedream、Gemini 等：用完整句子描述画面',
    fallback: true,
    match: [
      PromptMatchRule(
        models: [
          '/gpt-image|dall-?e|flux|seedream|seededit|gemini|imagen|nano-?banana|qwen-image|kolors|hunyuan|cogview|wanx|jimeng|recraft|ideogram|midjourney/',
        ],
      ),
    ],
    sections: [
      PromptSection(
        id: 'natural.inline',
        scope: PromptScopes.imageInline,
        title: '快速模式说明（自然语言）',
        text: '''你可以使用 <image>画面描述</image> 直接触发图片生成。

## 使用规则

1. 只有真的要生成并发送图片时，才输出 <image>...</image>
2. <image> 内写画面描述，或使用下文定义的参数 JSON；不要写解释或代码块
3. 一轮最多输出 1 个 <image>...</image>
4. 如果只是文字里提到图片，不要输出 <image> 标签

## 提示词规范（自然语言模型）

- 用一到三段完整的英文句子描述画面，像给摄影师或画师讲需求，不要写逗号分隔的标签串
- 依次讲清：主体是谁、外貌与服装、在做什么和表情、所处场景、光线与时间、镜头（景别、角度、焦段）、整体画风（如 anime illustration、film photo、watercolor）
- 自拍/第一人称：直接写 "a selfie taken by her" 或 "first-person view, her hand reaching toward the viewer"
- 不要使用 (tag:1.2)、{tag}、[tag] 这类权重符号，也不要写 masterpiece、best quality 这类质量标签
- 想避免的内容直接在句子里说明（例如 "no text, no watermark"），这类模型通常不支持负面提示词

【本次绘图参数契约】需要调整参数时，<image> 内可传 JSON：{"prompt":"English description","width":{default_width},"height":{default_height},"count":{default_count}}。以上是参考值，可合理调整。除 prompt 外均可省略，省略时使用角色绘图预设。宽高范围 256–2048，张数 count 范围 1–4。当前渠道不支持 steps、guidance_scale。本次格式以此契约为准，禁止传入渠道或模型选择参数。''',
      ),
      _toolDescription,
      PromptSection(
        id: 'natural.prompt',
        scope: PromptScopes.imageToolPrompt,
        title: '提示词参数（自然语言）',
        text: '''用一到三段完整的英文句子描述画面：主体、外貌服装、动作表情、场景、光线、镜头、画风。不要写标签串、权重符号或质量标签；想避免的内容直接写进句子。

## 负面提示词

这类模型通常不支持负面提示词，一般留空；需要避免的内容写进正向描述。''',
      ),
      _paramsBasic,
    ],
  ),
];

const _ttsBase = PromptSection(
  id: 'tts.base',
  scope: PromptScopes.ttsChat,
  title: '<tts> 基础规则',
  text: '''你可以使用 <tts>文本</tts> 标记来生成语音。

使用规则：
1. 将需要转换为语音的文本用 <tts></tts> 标记包裹
2. 每个 <tts></tts> 标记内的文本不要超过 {max_chars_per_chunk} 个字
3. 一轮对话中可以使用多个 <tts></tts> 标记
4. 建议在关键句子或回复的重要部分使用语音

示例：
<tts>你好，很高兴见到你！</tts>
<tts>今天天气真不错。</tts>''',
);

const _ttsText = PromptSection(
  id: 'tts.text',
  scope: PromptScopes.ttsChat,
  title: '文本规范',
  text: '【禁止】<tts> 内部严禁包含颜文字（如 (^_^)、(*¯︶¯*) 等）、Emoji 或特殊符号，以免影响语音合成发音。',
);

const _ttsOff = PromptSection(
  id: 'tts.off',
  scope: PromptScopes.ttsChatOff,
  title: '不使用语音',
  text: '【重要】用户不希望你使用语音功能，请只用文字回复。',
);

const _toolDescription = PromptSection(
  id: 'image.tool_description',
  scope: PromptScopes.imageToolDescription,
  title: '工具说明',
  text:
      '如果对话场景涉及到生成图片，可调用此工具。你可以自行使用此工具提升角色扮演效果，如生成自拍或生活图片等，自行决定用途。上下文中如果出现［图片］标签，意思是这个地方有一个图片占位，这意味着你需要配合语境发起一次图片工具调用，而不是单纯地回复文本标签。',
);

/// Width, height, count, steps and guidance in one section: the tool reads
/// them together, so the editor shows one item for them.
const _paramsSampling = PromptSection(
  id: 'image.params',
  scope: PromptScopes.imageToolParams,
  title: '参数',
  text: '''## 参数

- 宽度 width：严格遵循，竖图人像 832；横图 1216；方图 1024。参考值 {default_width}，可省略。
- 高度 height：严格遵循，竖图人像 1216；横图 832；方图 1024。参考值 {default_height}，可省略。
- 张数 count：1–4，参考 {default_count}，可省略。
- 步数 steps：采样步数 1–100，参考 {default_steps}，可合理调整。
- 提示词强度 guidance_scale：0–10，参考 {default_guidance_scale}，可合理调整。''',
);

/// Same as [_paramsSampling] for a channel without steps or guidance.
const _paramsBasic = PromptSection(
  id: 'image.params_basic',
  scope: PromptScopes.imageToolParams,
  title: '参数',
  text: '''## 参数

- 宽度 width：严格遵循，竖图人像 832；横图 1216；方图 1024。参考值 {default_width}，可省略。
- 高度 height：严格遵循，竖图人像 1216；横图 832；方图 1024。参考值 {default_height}，可省略。
- 张数 count：1–4，参考 {default_count}，可省略。''',
);
