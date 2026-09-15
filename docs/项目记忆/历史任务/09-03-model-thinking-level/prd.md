# 模型思考档位设置（会话级 reasoning effort）

## Goal

让用户在选择模型时可以设置该模型的「思考档位」（reasoning effort / thinking budget），并让三家主要上游（OpenAI 兼容、Claude、Gemini）真正按档位发请求。档位分两层：模型默认档位（全局）+ 会话级覆盖（会话之间隔离）。

用户价值：目前档位只能通过导入 SillyTavern 预设间接设置，且只对 OpenAI 系生效；用户无法按需在「快答」和「深思」之间切换，也无法为 Claude / Gemini 开启思考。

## Background（代码现状，锚点相对 `apps/aicove_flutter/`）

- 请求参数容器 `ProviderChatRequestOptions.reasoningEffort` 已存在（`lib/src/core/api/providers/provider_adapter.dart:115`），但唯一来源是 ST 预设 `SillyTavernPreset.reasoningEffort`（`lib/src/features/agent_context/domain/silly_tavern_preset.dart:167`）；无预设的会话 `providerRequestOptions` 整体为 null（`lib/src/features/chat/services/chat_send_backend_service.dart:650`）。
- 只有 OpenAI 适配器消费该字段写 `reasoning_effort`（`lib/src/core/api/providers/openai_adapter.dart:107-112`）；Claude（`claude_adapter.dart:140-153`）与 Gemini（`gemini_adapter.dart:109-132`）完全不构造 thinking 参数；MiniMax 继承 OpenAI。
- 参数追踪白名单 claude / gemini 不含 `reasoning_effort`（`provider_adapter.dart:150-166`）。
- 模型级配置容器 `ModelConfig`（`lib/src/features/settings/settings_models.dart:844`）持久化于 SharedPreferences JSON；会话表 `Conversations`（`lib/src/core/database/database.dart:14`）为 Drift，schemaVersion=14，加列走 `_safeAddColumn`（`:456`），云同步映射在 `lib/src/core/sync/sync_service.dart:187`。
- 思考内容的流式解析（Anthropic `thinking_delta`、OpenAI `reasoning_content`）与 UI 展示（`ThinkingBlock`）已就绪（`lib/src/core/api/agent_api_stream_support.dart:319/393`、`message_bubble.dart:751`）；Gemini `thought` part 未解析。
- 聊天页选模型入口 `composer.dart:1326` → `composer_model_picker_sheet.dart`；模型设置编辑弹层 `lib/src/ui/features/settings/widgets/model_row_tile.dart:224/716`。
- 上游原生档位（2026-09 核实）：
  - OpenAI `reasoning_effort`：值随模型而异，全集 `none / minimal / low / medium / high / xhigh / max`；o 系仅 low/medium/high；GPT-5.1+ 支持 none；GPT-5.1-codex-max 及之后支持 xhigh。
  - Claude 4.6+：`thinking: {type: "adaptive"}` + `output_config.effort` ∈ `low / medium / high / xhigh / max`（4.6 无 xhigh；Fable 5 不可 disabled）；4.5 及更早：`thinking: {type: "enabled", budget_tokens: N}`（N ≥ 1024 且 < max_tokens）。
  - Gemini 3.x：`generationConfig.thinkingConfig.thinkingLevel` ∈ `MINIMAL / LOW / MEDIUM / HIGH`（Pro 不含 MINIMAL 且不可关闭）；Gemini 2.5：`thinkingConfig.thinkingBudget`（0 关闭、-1 动态、正整数上限），两者不可同发。

## Requirements

### R1 档位数据两层存储（用户裁决）

- R1.1 模型默认档位：存在 `ModelConfig` 内，按 modelRef（provider:model）生效，随模型 store 持久化。
- R1.2 会话级覆盖：存在会话记录上，**按 modelRef 分别记录**（一个会话内每个用过的模型各自记住自己的档位），会话之间完全隔离，并进入云同步映射。
- R1.3 生效优先级：会话内该模型的覆盖 > 模型默认档位 > ST 预设 `reasoning_effort` > **软件默认档位**。
- R1.5 软件默认档位（用户裁决）：优先 `off`；该模型不支持关闭时取其方案的最低档（一般为 `low`，Gemini 3 Flash 系为 `minimal`）。即所有模型未设置时都以「关或最低思考」发请求，不再"不发参数沿用上游默认"。
- R1.4 会话内切换模型时：若该模型在本会话用过，沿用本会话上次对它的档位；否则用模型默认档位。

### R2 档位口径按模型决定（用户裁决）

- R2.1 上游对该模型有原生档位枚举的，UI 直接展示上游的档位（如 OpenAI 的 low/medium/high/xhigh，Gemini 3 的 MINIMAL/LOW/MEDIUM/HIGH，Claude 4.6+ 的 low~max）。
- R2.2 上游没有原生枚举、只有 token 预算或不可识别的模型，展示自研四档「关 / 低 / 中 / 高」，由适配器翻译成上游参数（budget_tokens / thinkingBudget / reasoning_effort 的 low/medium/high）。
- R2.3 每个档位方案都含一个「跟随上游」项（`auto`，不发任何 thinking 参数），供用户主动选择；它不是默认值（默认见 R1.5）。
- R2.4 用户选过的档位若因换模型而不在新模型的可选集合里，按最接近档位降级（例如 xhigh → high），不报错。

### R3 三家适配器真正发送参数

- R3.1 OpenAI 兼容：`reasoning_effort` 按方案写入；「关」在支持 none 的模型写 `none`，否则不发。
- R3.2 Claude：4.6+ 写 `thinking: {type: adaptive}` + `output_config.effort`；「关」写 `thinking: {type: disabled}`（Fable 5 不可关，方案里不提供关）；4.5 及更早写 `thinking: {type: enabled, budget_tokens}` 并保证 `budget_tokens < max_tokens`。
- R3.3 Gemini：3.x 写 `thinkingLevel`；2.5 写 `thinkingBudget`；绝不同时写两者；渠道 `customConfig` 已有 thinkingConfig 时以本功能设置为准覆盖同名字段。
- R3.4 参数追踪（`parameterTraceForProvider`）对 claude / gemini 也把思考档位记为已应用。

### R4 UI 入口

- R4.1 聊天页：选模型的地方能看到并切换当前模型在本会话的档位；切换后立即对下一条消息生效。
- R4.2 设置页模型配置编辑弹层：可设置该模型的默认档位。
- R4.3 档位选项的文案对新手友好（如 "xhigh — 极深思考，最慢最贵"），并标出当前生效来源（会话 / 模型默认 / 预设）。

### R5 思考内容展示补全

- R5.1 Gemini 流式响应的 `parts[].thought == true` 文本解析进 reasoning 缓冲，保证开启思考后 Gemini 也能显示思考块。

## Acceptance Criteria

- [ ] AC1（R1.1/R4.2）设置页给模型 A 设默认档位后，新建会话用模型 A 发送，请求体带对应参数（通过 trace payload / adapter 单测验证）。
- [ ] AC2（R1.2/R1.4/R4.1）会话 S1 把模型 A 调到高档，会话 S2 用模型 A 仍是模型默认；回到 S1 切到模型 B 再切回 A，档位仍是高档。
- [ ] AC3（R1.3/R1.5）同一会话同时有预设 reasoning_effort 与会话覆盖时，请求体取会话覆盖；仅有预设时取预设；都没有时取软件默认：claude-opus-5 → `thinking.type=disabled`，claude-fable-5 → `effort=low`，gemini-3-flash → `thinkingLevel=MINIMAL`，gemini-3-pro → `LOW`，gpt-5.2 → `reasoning_effort=none`，o3 → `low`，未知 OpenAI 兼容模型 → 不发参数。
- [ ] AC4（R2.1/R2.2）单测覆盖：gpt-5.x → 上游档位集合；o3 → low/medium/high；未知 OpenAI 兼容模型 → 四档；claude-opus-5 → low~max；claude-sonnet-4-5 → 四档→budget_tokens；gemini-3-flash → MINIMAL~HIGH；gemini-2.5-flash → 四档→thinkingBudget。
- [ ] AC5（R2.4）档位 xhigh 切到只支持 high 的模型，请求体为 high，无异常。
- [ ] AC6（R3.1~R3.3）三家适配器请求体单测：各档位 + 关 + 自动的输出形状正确；Gemini 不同时含 thinkingLevel 与 thinkingBudget；Claude 4.5 的 budget_tokens < max_tokens。
- [ ] AC7（R5.1）Gemini 流式 fixture 含 thought part 时，结果 reasoning 非空且不混入正文。
- [ ] AC8 数据库迁移 v14→v15 在旧库上可升级，旧会话档位为空，按软件默认档位（R1.5）发送；升级前后其余请求字段不变（回归单测）。
- [ ] AC9 `flutter analyze` 零新增告警；相关测试目录全绿。

## 自主决策

- 「不支持关就最低档」里的最低档按方案实际集合取：Gemini 3 Flash 系有 MINIMAL 就用 MINIMAL（比 low 更省），其余为 low；符合"减少思考"的意图。
- 未识别的 OpenAI 兼容模型（四档兜底）软件默认为「跟随上游」而非 `off`：这类上游是否接受 `reasoning_effort: none` 无法判断，发了可能 400；用户主动选「关」时才发 `none`。
- 会话级覆盖按 modelRef 分别存（JSON map 一列），而不是单值：不同模型档位集合不同，单值切模型后无法解释；也天然满足 R1.4。
- 档位在持久层统一用小写字符串 canonical 值（`auto / off / minimal / low / medium / high / xhigh / max`），不存上游原始 JSON：换模型可比较、可降级，适配器只做翻译。
- 档位方案由「provider 类型 + 模型 id 模式」的静态目录表决定，不查上游 Models API：离线可用、行为可测；未命中即四档兜底，宁可保守。
- 四档翻译数值：Claude budget_tokens 低 2048 / 中 8192 / 高 16384（受 max_tokens 约束再裁）；Gemini 2.5 thinkingBudget 低 1024 / 中 8192 / 高 -1（动态上限）。数字是常见推荐值，后续可调不影响接口。
- Claude 旧模型的「关」写 `thinking: {type: disabled}` 而不是省略：省略在 Opus 5 上等于开启 adaptive，语义不稳。
- 会话档位写入走现有会话 repository 的 update 路径，不新建 provider：改动面最小。
- 不改 `composer.dart` 写全局默认模型的现有行为（`sessionProvider` 接线是另一件事）；本任务只在其旁边加档位入口。
- 优先级里保留 ST 预设作为第三级而非移除：兼容已导入预设的用户。

## Out of Scope

- 会话绑定模型（`sessionProvider` 写入）。
- MiniMax / Z.ai / 其他小众供应商的专属 thinking 字段（继承 OpenAI 行为即可）。
- 思考内容展示样式改版。
- 上游 Models API 动态能力探测。

## Open Questions

无阻塞问题。
