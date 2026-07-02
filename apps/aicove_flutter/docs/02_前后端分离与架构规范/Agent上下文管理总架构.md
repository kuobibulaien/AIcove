# Agent Context Runtime（上下文管理总架构）

> 从根 README 迁移至此。本文档是 Agent 上下文管理系统的完整架构设计。
>
> 配套文档：
> - Web 管理端实施说明：`cloud_backend/Agent上下文系统Web管理端实施说明_20260430.md`
> - Node Studio 前端改造说明：`cloud_backend/Agent节点界面前端改造说明_20260430.md`
> - App 端迁移说明：`docs/Agent上下文系统前端二次完善说明_20260430.md`

AIcove 的长期架构方向不是"提示词管理系统"，而是 **Agent 上下文管理系统**。提示词只是上下文最终序列化给模型的一种表现形式；系统真正要管理的是：身份、人设、记忆、对话窗口、运行时事实、工具能力、输出契约和后处理链路。

## 核心公式

```text
Agent = 模型 + 上下文策略 + 工具策略 + 输出契约 + 后处理器
```

这里的每个 Agent 都应拥有同一套定义面，而不是只有前台聊天才有角色卡、预设、世界书、记忆或工具策略：

```text
AgentDefinition
  = ModelRef
  + ContextProfile
  + ContextRecipe
  + ContextAssemblyPermissions
  + ToolPolicy
  + OutputContract
  + PostProcessors / DeliveryChannel
```

不同 Agent 的差异不在于"有没有这些东西"，而在于**能装配哪些上下文资产、能调用哪些工具、输出会投递到哪里**。前台 `ChatAgent` 拥有完整可组装权限；后台 Agent 复用同一组槽位，但按职责收窄为更专业化的权限。

| Agent 类型 | 触发来源 | 典型职责 |
|------|------|------|
| 标准对话 Agent | 用户消息 | 多轮聊天、角色扮演、情绪陪伴、多模态回复 |
| 后台 / 主动关怀 Agent | 定时器、未回复窗口、状态变化 | 判断是否需要主动关怀，预生成候选回复并审核触发时机 |
| Analyzer Agent | 后台扫描、上下文状态变化 | 分析上下文、产出决策、调度工具链 |
| Renderer / Tool 执行链 | 标准化输出事件 | 执行 TTS、绘图、表情包、触发器等副作用 |

## Agent Runtime 统一调度

AIcove 的前台聊天不再被视为特殊主链路，而是一个标准 `ChatAgent`：

```text
前台聊天 = ChatAgent + userMessage trigger + foregroundConversation delivery
```

并且 `ChatAgent` 的粒度不是全局唯一，而是**联系人级**：

```text
一个联系人 / 角色会话 = 一个 ChatAgent

contactId（当前等同 conversation.id）
        ↓
chat_agent:<contactId>
        ↓
standard_chat_recipe:<contactId>
        ↓
该联系人的角色卡、预设、世界书、记忆、插件开关、输出契约
```

也就是说，前台聊天入口只是触发某个联系人自己的 `ChatAgent`。这个 `ChatAgent` 是最完整的上下文装配者：它可以读取并组合该联系人的角色卡、SillyTavern 预设、`prompt_order`、世界书 / lorebook、记忆、对话窗口、regex / extension prompt、工具策略、输出契约和 provider 渲染策略。不同联系人可以拥有不同的上下文配方、酒馆预设、世界书、插件边界和输出规则。

后台分析、主动关怀、记忆总结、渲染执行等能力也应先归一化为一次 `AgentRunRequest`，再交给同一个运行壳调度：

```text
Trigger / Event
        ↓
AgentScheduler
        ↓
AgentRunRequest
        ↓
AgentRuntime
        ↓
ContextRuntime / ContextRecipe
        ↓
ModelRunner + ToolLoop
        ↓
OutputPipeline
        ↓
DeliveryChannel
        ↓
Trace / State / Storage / UI
```

统一调度后，各类 Agent 都有同一套上下文资产面，但通过 `ContextAssemblyPermissions` 收窄职责：

| Agent | Trigger | ContextRecipe | 装配权限 | DeliveryChannel |
|------|------|------|------|------|
| ChatAgent | 用户消息 | `standard_chat_recipe:<contactId>` | `full_chat`：角色卡、ST 预设、prompt_order、世界书、记忆、对话窗口、regex、extension prompt、工具策略、输出契约、provider 渲染 | 前台聊天气泡、数据库、流式 UI |
| ProactiveAgent | 定时器、沉默窗口、云触发器 | `proactive_preview_recipe` / `proactive_dispatch_recipe` | `proactive_specialized`：围绕某个联系人读取人设、预设、世界书、记忆和近期窗口，但输出受主动关怀审核与投递策略限制 | 主动回复候选、通知、聊天投递 |
| AnalyzerAgent | 后台扫描、状态变化 | `analyzer_recipe` | `analyzer_specialized`：读取记忆、窗口、运行时事实和工具边界，偏 JSON / 决策输出，不直接拥有完整角色扮演装配面 | 后台 trace、调度状态 |
| MemoryAgent | 对话变更、摘要窗口 | `memory_recipe` | `memory_specialized`：读取窗口和运行时事实，产出可写入的记忆结构，不负责聊天风格渲染 | 本地 / 云端记忆库 |
| RendererAgent | 标准输出事件 | `renderer_recipe` | `renderer_specialized`：消费标准输出事件和工具策略，不重新组装角色卡 / 世界书 | TTS、图片、表情包等插件队列 |

`<tts>`、`<image>`、tool call、JSON 决策不再是某条聊天链路的私有后处理，而是 `OutputPipeline` 解析出的标准事件。只要不同 Agent 产出同一种事件，就应走同一套插件、投递和 trace 逻辑。

## SillyTavern 预设兼容目标

AIcove 的目标不是把 SillyTavern 预设导入成一段长 prompt，而是直接兼容它的上下文构建骨架：

```text
SillyTavern prompts
        ↓
AgentContextNode

SillyTavern prompt_order
        ↓
AgentContextRecipe.nodes 的顺序和 enabled 状态

SillyTavern marker（chatHistory / worldInfoBefore / charDescription 等）
        ↓
运行时 ContextSlot / AgentContextEntry 注入点

SillyTavern regex / extension prompt / world info scan
        ↓
TransformPipeline / LorebookScanner / ExtensionInjection
```

因此内部上下文不能长期停留在"一个 `systemPrompt` 字符串"。标准形态应是：

```text
AgentContextRecipe
  ├─ AgentContextNode(main)
  ├─ AgentContextNode(worldInfoBefore)
  ├─ AgentContextNode(charDescription)
  ├─ AgentContextNode(chatHistory)
  └─ AgentContextNode(jailbreak)
        ↓
AgentRenderedMessage[]
        ↓
provider-specific messages
```

`systemPrompt` 只作为向旧链路过渡的兼容字段；真正的上下文运行时应以有序节点、动态注入点、变换 trace 和最终 messages 为准。

动态阶段按酒馆流程继续拆分：

| SillyTavern 能力 | AIcove 内部抽象 | 说明 |
|------|------|------|
| regex placements | `AgentContextTransformPipeline` | 按 `user_input`、`ai_output`、`world_info`、`reasoning` 等位置执行上下文变换 |
| world info / lorebook scan | `LorebookScanner` | 扫描最近聊天和当前输入，命中后生成指向 `worldInfoBefore` / `worldInfoAfter` 的 `AgentContextEntry` |
| extension prompts | `ExtensionInjection`（后续） | 插件按指定位置注入上下文节点 |
| token budget | `AgentContextTokenBudgetPlanner` | 根据模型上下文长度裁剪节点和历史窗口，优先保留 preset/system 与最新聊天 |
| provider renderer | `AgentProviderMessageRenderer` | 将 `AgentRenderedMessage[]` 渲染成 OpenAI / Claude / Gemini 等供应商消息结构 |

当前兼容批次已经先支持"世界书命中 → 注入 worldInfoBefore/worldInfoAfter → regex/world_info placement 变换 → token budget 裁剪 → provider-specific message 渲染"的最小闭环。

## 上下文装配分层

所有进入模型的请求都应按以下层次组装，而不是把零散 prompt 字段直接拼在业务代码里：

1. **身份和关系上下文**：角色、人设、关系状态、对话目标。
2. **用户画像和记忆**：长期记忆、当前画像、召回片段、角色作用域记忆。
3. **对话窗口**：数据库 raw message、最近 N 轮、摘要、context start marker、编辑/重发后的分支截断。
4. **运行时事实**：当前时间、上一条用户消息时间、未回复时长、设备状态、触发来源。
5. **能力边界**：可用插件、可用工具、模型能力、工具调用开关、模型上下文限制。
6. **输出契约**：本次允许输出普通文本、`<tts>`、`<image>`、工具调用、JSON 审核结果或触发器创建结果。

## 输出标签与多模态边界

`<tts>`、`<image>` 等标签不是 Agent 本体，而是模型输出 DSL / 归一化协议：

- 给模型看的部分是"标签语义说明"，用于约束模型什么时候可以输出对应标签。
- 程序处理的部分应把模型输出解析为标准事件，例如 `TextSegment`、`TtsSegment`、`ImageRequest`。
- 真正执行的部分交给 TTS 插件、图片插件、工具调用或触发器执行链。
- 只有当图片生成、语音生成等链路需要独立的 prompt 改写、审核、重试、风格选择时，才升级为专门的 sub-agent。

## 迁移原则

1. **先接标准对话 Agent**：当前对话模型是最高频入口，应作为第一批接入 Agent Context Runtime 的标准 Agent。
2. **不一次性推倒重写**：现有聊天主链路保持可运行，逐步抽出 `AgentContextAssembler`，把当前散落在聊天、后台 Agent、主动关怀中的上下文装配逻辑收口。
3. **上下文优先，prompt 次之**：新增能力先定义上下文来源、优先级、token 策略和输出契约，再决定最终如何序列化为 system/user/tool messages。
4. **输入、能力、输出三者分离**：`system-reminder` 是上下文输入；`tools` 是可执行能力；`<tts>` / `<image>` 是输出契约。
5. **所有链路可追踪**：Agent 运行结果必须能追踪本次使用了哪些上下文层、哪些工具、哪些标签语义，以及最终传给模型的 messages。

推荐目标链路：

```text
用户消息 / 定时事件 / 后台状态变化 / 输出事件
        ↓
AgentScheduler.submit(AgentRunRequest)
        ↓
AgentRuntime.run(...)
        ↓
ContextRuntime / AgentContextAssembler 组装上下文
        ↓
ModelRunner 调用模型
        ↓
OutputPipeline / OutputNormalizer 解析文本、tts、image、tool result
        ↓
DeliveryChannel 将标准事件投递到 UI、插件、记忆库或后台 trace
```

## 当前改造批次

第一阶段先做**行为不变的架构抽象**：建立 Agent Context Runtime / Agent Runtime 的契约层和最小组装器，让后续聊天主链路、主动回复、后台 Agent 都能逐步迁移到统一的 `AgentDefinition + AgentRunRequest + ContextProfile + ContextAssembler + OutputPipeline + DeliveryChannel` 口径。当前阶段不直接推翻现有发送链路，先保证可测试、可追踪、可回退。

本阶段第一刀：前台聊天作为 `StandardChatAgent` 接入 `AgentScheduler.submit(...)`，内部暂时仍委托既有 `ChatSendUseCase` / `ChatSendService`，不改变真实发送、流式输出、工具调用、TTS 和图片插件投递行为。
