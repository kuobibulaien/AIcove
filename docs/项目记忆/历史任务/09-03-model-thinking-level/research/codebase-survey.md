# Research: 模型思考档位（reasoning effort / thinking budget）现状调研

- **Query**: 为「模型默认档位 + 会话级覆盖」功能调研现有 reasoningEffort 链路、会话/模型持久化、UI 入口、发送链路、thinking 展示、spec 与测试
- **Scope**: internal（只读，未改动任何源码）
- **Date**: 2026-09-03
- 路径基准：`apps/aicove_flutter/`（下文相对路径均以此为根）

---

## 1. 现有 reasoningEffort 链路

### 1.1 请求参数容器

`lib/src/core/api/providers/provider_adapter.dart`

- `ProviderChatRequestOptions`（`provider_adapter.dart:103`）：**只对当前请求生效**的供应商参数，与渠道持久化的 `customConfig` 分开。
- `final String? reasoningEffort;`（`provider_adapter.dart:115`），构造参数 `provider_adapter.dart:129`。
- `toTraceJson()` 输出 `reasoningEffort`（`provider_adapter.dart:144-145`）。
- `parameterTraceForProvider(String provider)`（`provider_adapter.dart:147`）按 provider 白名单判定字段状态：
  - `claude` 支持集合 = `{temperature, top_p, top_k, max_tokens, use_sysprompt}`（`provider_adapter.dart:150-156`）→ **不含 reasoning_effort**。
  - `gemini` 支持集合 = `{temperature, top_p, top_k, frequency_penalty, presence_penalty, seed, max_tokens, use_sysprompt}`（`provider_adapter.dart:157-166`）→ **不含 reasoning_effort**。
  - 默认（openai 系）支持集合含 `'reasoning_effort'`（`provider_adapter.dart:179`）。
  - `isDefault` 把 `reasoning_effort == 'auto' || ''` 判为 `notApplicable`（`provider_adapter.dart:203`）。
- 抽象接口 `ProviderAdapter.buildRequestBody({model, messages, temperature, topP, customConfig, tools, requestOptions})`（`provider_adapter.dart:237-245`）。

### 1.2 reasoningEffort 的来源：SillyTavern 预设

- 字段定义：`lib/src/features/agent_context/domain/silly_tavern_preset.dart:167` `final String reasoningEffort;`（非空 String），构造 `:202`。
- 解析：`lib/src/features/agent_context/domain/silly_tavern_preset_parser.dart:233` `reasoningEffort: _string(body['reasoning_effort'])`——来自导入的 ST 预设 JSON。
- 兼容性说明表：`silly_tavern_preset_parser.dart:504`（`'reasoning_effort': '已按 provider 能力映射'`）、`:600`。
- **持久化方式**：预设是「recipe」，会话通过 `Conversations.recipeId`（`lib/src/core/database/database.dart:43`）绑定；运行期由 `presetRecipeProvider(boundRecipeId)` 加载（`lib/src/features/chat/services/chat_send_backend_service.dart:159-160`）。
- 结论：**目前 reasoningEffort 只有 ST 预设一条来源，没有模型级/会话级来源**。无预设的会话 `boundPreset == null`，此时 `providerRequestOptions` 直接为 `null`（`chat_send_backend_service.dart:650-651`）。

### 1.3 各 adapter 现状

| Adapter | 文件 | thinking / reasoning 处理 |
|---|---|---|
| OpenAI | `lib/src/core/api/providers/openai_adapter.dart` | `_applyRequestOptions` 写 `body['reasoning_effort']`，跳过空串与 `'auto'`（`:107-112`）。另有 Kimi 专项：`_shouldApplyKimiThinkingSafeMaxTokens`（`:238`）与 `_isThinkingDisabled(customConfig)` 读 `customConfig['thinking']['type']`（`:251-256`），仅用于给 `kimi-k2-thinking` 兜底 `max_tokens=16384`（`:10`, `:69-74`）——**不构造 thinking 参数，只读取渠道已配置的**。`customConfig` 整体 `body.addAll(customConfig)`（`:75-77`），即渠道自定义配置可透传任意 thinking 字段。 |
| Claude | `lib/src/core/api/providers/claude_adapter.dart` | **无任何 thinking 处理**。`_applyRequestOptions` 只处理 temperature/top_p/top_k/max_tokens（`:140-153`），完全忽略 `reasoningEffort`。`...?customConfig` 展开进 body（`:103`），是目前唯一能传 `thinking` 的通道。 |
| Gemini | `lib/src/core/api/providers/gemini_adapter.dart` | **无 thinkingConfig / thinkingBudget / thinkingLevel**。`generationConfig` 由 `customConfig['generationConfig']` 展开 + `_applyRequestOptions`（`:109-114`, `:132+`）组成，`reasoningEffort` 未被消费。 |
| MiniMax | `lib/src/core/api/providers/minimax_adapter.dart:6` | `class MiniMaxAdapter extends OpenAIAdapter`，继承 OpenAI 的 `reasoning_effort` 行为，无独立 thinking 处理。 |

### 1.4 能力声明

`lib/src/core/api/providers/provider_capabilities.dart:11-12` 有 `final bool supportsThinking;`（默认 false，`:35`），OpenAI 档位 `true`（`:47`），其余 `false`（`:60`, `:80`）。当前仅作声明，未参与请求构造。

---

## 2. 会话数据模型与持久化（Drift）

- 表定义：`lib/src/core/database/database.dart:14` `class Conversations extends Table`。
  - 模型相关字段：`defaultProvider`（`:35`）、`sessionProvider`（`:36`）——都是 `TextColumn ... nullable()`，存的是 modelRef 字符串（provider:model 前的引用形式）。
  - 其他会话级设置示例：`chatBackgroundImage :20`、`chatBackgroundMaskOpacity :22`、`chatBackgroundBlurSigma :24`、`enabledPlugins :42`（JSON 数组字符串）、`recipeId :43`、`contextStartMessageId :59`。
- 领域实体：`lib/src/features/chat/domain/conversation.dart` —— `sessionProvider` 字段 `:26`，构造 `:67`，`copyWith` 哨兵模式 `:114`/`:160-162`。
- 表 ↔ 实体转换：`lib/src/core/database/converters/database_converters.dart:30`（写）、`:65`（读）。
- 云同步映射：`lib/src/core/sync/sync_service.dart:187` `sessionProvider: Value(data['session_provider'] as String?)`——**新增会话字段需要同步这里**。
- 消费点：`lib/src/features/chat/application/standard_chat_agent.dart:42` `modelRef: conversation.sessionProvider ?? conversation.defaultProvider`。
- 迁移惯例：`database.dart:354` `int get schemaVersion => 14;`；`migration` 在 `:357`，`onUpgrade` 用 `if (from < N)` 逐级累加，加列统一走 `_safeAddColumn(table, 'col_name TYPE [NOT NULL DEFAULT x]')`（定义在 `:456`，try/catch 吞异常）。
  - 最近几次示例：v12→v13 加列 `await _safeAddColumn('conversations', 'recipe_id TEXT');`（`:429-431`）；v13→v14 建表 `_ensureAutoReplyClaimTable()`（`:433-435`, `:441`）。
  - 新表需同时注册进 `@DriftDatabase(tables: [...])`（`:340` 附近列表）并跑 `flutter pub run build_runner build`（`database.dart:2` 注释）。

---

## 3. 模型数据模型与持久化

- 主文件：`lib/src/features/settings/settings_models.dart`（1377 行）。
  - `enum ChatModelCapability { vision, tools, reasoning, web }`（`:152-156`），带 `fromValue :161` / `fromValues :169` / `normalizeValues :179`。
  - 自动推断：`_chatReasoningPatterns`（`:233`，匹配 `o1|o3|o4|qwq|reasoner|reasoning|thinking|think|r1|glm-5|hunyuan-t1|glm-zero|deepseek-r|marco-o1`）、`inferChatModelCapabilities(String modelId)`（`:266`）。
  - **per-model 配置容器：`class ModelConfig`**，字段 `disableToolCalling / temperature / topP / contextMessageLimit / chatCapabilities / maxContextTokens`（`:844-851`），`isDefault`（`:854`，全默认则可删以省空间）、`copyWith`（`:865`，clearXxx 布尔模式）、`toJson`（`:893`，snake_case、null 不写）、`fromJson`（`:903`）。→ **这里是放「模型默认档位」最自然的位置**（新增如 `thinking_level` 字段 + `clearThinkingLevel`，并同步 `isDefault`）。
  - 读取入口：`AppSettings.getModelConfig(modelRef)`（在 `chat_request_config.dart:338` 被调用）、`getChatModelCapabilities(:1307)`、`hasChatModelCapability(:1321)`。
  - `ProviderAuth.customConfig`（`:683`，`Map<String, dynamic>`）是渠道级自定义配置，`toJson` 键 `'custom_config'`（`:772`），`fromJson :793`——即 adapter 拿到的 `customConfig` 来源。
- 持久化：SharedPreferences 单键 JSON store。
  - `lib/src/features/settings/data/local/ui_models_store_local_data_source.dart`：`class UiModelsStoreLocalDataSource :13`，`fetchAll :16`、`updatePartial :21`、`updateProvider :123`、`_loadStore :316`（读 `kUiModelsStoreKey`，走 `normalizeUiModelsStoreData` 后 `jsonEncode` 回写）、`_writeStore :508`、legacy 迁移 `_tryMigrateLegacyStore :355`。
  - `lib/src/features/settings/data/support/ui_models_store_support.dart`：默认值 `buildDefaultUiModelsStoreData :41`、归一化 `normalizeUiModelsStoreData :475`（provider/model 逐条 normalize，`:605-660`）、一次性数据迁移示例 `applyNovelAiV5FullDefaultMigration :330`。→ **模型 store 的「迁移」惯例是 normalize + 一次性 apply 函数，无 schemaVersion 概念。**

---

## 4. 模型选择 UI

| 位置 | 文件 | 说明 |
|---|---|---|
| 聊天页选模型入口 | `lib/src/features/chat/presentation/widgets/composer.dart:1326` | 调 `showComposerModelPickerSheet(context)`；选中后 **写的是全局默认模型** `setDefaultModelName(selected)`（`:1338`），而非会话字段（`:1310-1345`）。toast 见 `:1340-1344`。 |
| 选择器 sheet | `lib/src/features/chat/presentation/widgets/composer_model_picker_sheet.dart`（408 行） | `showComposerModelPickerSheet :11`、`_ComposerModelPickerSheet :82`、`_ModelPickerTile :315`、队列排序 `_onReorderQueue :264` / `_QueueOrderBadge :382`。**每个模型 tile 旁是加档位选择器的自然位置。** |
| composer 更多面板 | `lib/src/features/chat/presentation/widgets/composer_more_panel.dart` | 另一处模型相关入口 |
| 设置-模型列表页 | `lib/src/ui/features/settings/pages/model_list_page.dart:32` `ModelListPage` | |
| 设置-默认模型页 | `lib/src/ui/features/settings/pages/default_model_settings_page.dart:19` `DefaultModelSettingsPage` | |
| 设置-单模型行/配置编辑 | `lib/src/ui/features/settings/widgets/model_row_tile.dart:27` `ModelRowTile` | `settings?.getModelConfig(modelRef) ?? const ModelConfig()`（`:50`）；编辑弹层参数 `required ModelConfig currentConfig`（`:224`）；保存 `notifier.updateModelConfig(...)`（`:716`）。**「模型默认档位」的设置 UI 落点。** |
| 设置-通用模型选择器 | `lib/src/ui/features/settings/widgets/model_picker_sheet.dart`（436 行） | 插件/TTS/auto_reply 等复用 |

注意：`sessionProvider` 目前**在 UI 层没有任何写入点**（全局 grep 仅命中 db/converters/sync/domain/standard_chat_agent），即「会话绑定模型」这条路已有数据字段但未接通 UI。

---

## 5. 发送链路（UI → buildRequestBody）

```
composer / chat_actions_action_ops.dart:122 (overrideModel: model)
  → chat_send_use_case.dart:292 (overrideModel: model)
  → chat_ports.dart:81 / chat_port_adapters.dart:167,176 (String? overrideModel)
  → chat_send_service.dart:240,249
  → chat_send_backend_service.dart:134 (String? overrideModel)
      :146  buildRequestConfig(settings, modelRef: overrideModel)
      :154-179 加载 boundPreset（recipeId → presetRecipeProvider）
      :634-665 组装 ApiConfig，其中
        :650-665 providerRequestOptions = boundPreset == null ? null
                 : ProviderChatRequestOptions(..., reasoningEffort: boundPreset.reasoningEffort)
  → chat_send_api_runner.dart:233 / :261  requestOptions: config.providerRequestOptions
  → agent_api.dart:552 / :799 / :846  (ProviderChatRequestOptions? requestOptions)
      :567-574  adapter.buildRequestBody(..., requestOptions: requestOptions)
  → agent_api_stream_support.dart:28 / :62（流式同一路径）
  → 各 ProviderAdapter.buildRequestBody
```

配套结构：
- `lib/src/features/chat/services/chat_request_config.dart`：`ChatRequestConfig.modelFullId :15`；`buildRequestConfig :291`——解析 `modelRef`（`:299-301`，空则 `settings.defaultModelName`）、拆 provider/model（`:303-305`）、选 key、**`final modelConfig = settings.getModelConfig(resolvedModelRef);`（`:338`）**，返回 `:340+`。→ **模型级默认档位在这里读出最自然。**
- `lib/src/features/chat/services/chat_types.dart:104` `modelFullId`、`:119` `final ProviderChatRequestOptions? providerRequestOptions;`（构造 `:144`）——`ApiConfig` 的载体。

**注入层建议（事实陈述）**：会话级档位在 `chat_send_backend_service.dart` 已持有 `conv`（会话实体）与 `boundPreset`，且 `providerRequestOptions` 就在 `:650` 构造；模型级默认档位在 `chat_request_config.dart:338` 已加载 `ModelConfig`。当前 `boundPreset == null` 时 `providerRequestOptions` 整体为 null，这是「无预设会话拿不到任何 request options」的现实约束点。

---

## 6. 流式 thinking / reasoning 解析与展示

`lib/src/core/api/agent_api_stream_support.dart`：
- 累积缓冲 `final reasoning = StringBuffer();`（`:209`），`emitReasoningDelta` 写入 `:231`。
- 已覆盖的上游格式：
  - Anthropic `thinking_delta` → `delta['thinking']`（`:319-323`）
  - OpenAI 兼容 `choices[].delta.reasoning_content`（`:393-396`）、`message.reasoning_content`（`:413`, `:425`）、顶层 `evt['reasoning_content']`（`:439`）
  - OpenAI Responses API `response.reasoning.delta` / `response.reasoning_text.delta`（`:445-446`）
- 收尾：`finalReasoning`（`:564`），传给结果 `reasoning: finalReasoning`（`:581`），trace 记 `'reasoningLength'`（`:658`），回写 payload `'reasoning_content': reasoning`（`:793-799`）。

展示侧：
- `lib/src/core/models/message_block.dart`：`BlockType.thinking`（`:61`），`ThinkingBlock` 构造分支 `:175`。
- `lib/src/features/chat/presentation/widgets/message_bubble.dart`：`block is ThinkingBlock`（`:361`, `:400`），渲染 `_buildThinkingBlock(ThinkingBlock block, Color textColor)`（`:751`）。
- `lib/src/features/chat/domain/message.dart:72`：首块为 ThinkingBlock 时预览显示 `'[思考中...]'`。
- 结论：**解析与 UI 展示链路已完整存在**（Anthropic + OpenAI 两系），开启思考后思考内容可展示。Gemini 的 `thought` part 未见解析命中。

---

## 7. 相关 spec 文档路径

- `.trellis/spec/README.md`
- `.trellis/spec/backend/index.md`、`database-guidelines.md`（Drift/迁移）、`directory-structure.md`、`error-handling.md`、`logging-guidelines.md`、`quality-guidelines.md`
  - 注意：`backend/index.md` 索引表中各条目状态标为「To fill」，内容可能未落地。
- `.trellis/spec/frontend/index.md`、`component-guidelines.md`、`state-management.md`、`type-safety.md`、`quality-guidelines.md`、`hook-guidelines.md`、`directory-structure.md`
- `.trellis/spec/guides/index.md`、`cross-layer-thinking-guide.md`（跨层改动，涉及 DB→domain→service→UI 时必读）、`code-reuse-thinking-guide.md`
- `.trellis/spec/project/architecture-boundaries.md`、`glossary.md`、`overview.md`、`documentation.md`
- `.trellis/spec/project/decisions/0001-dsh-as-agent-runtime.md`
- `.trellis/spec/agent-context/index.md`
- 另：项目根 `AGENTS.md` 为唯一权威规则来源（`CLAUDE.md` 明确指向）。

---

## 8. 已有测试

Adapters / API：
- `test/core/api/providers/provider_adapter_test.dart` —— 已覆盖 `reasoningEffort: 'high'`（`:18`）、`byField['reasoning_effort']?['status']`（`:40`, `:57`）、`'auto'` 判定（`:70`）
- `test/core/api/providers/claude_adapter_test.dart`
- `test/core/api/providers/gemini_adapter_test.dart`
- `test/core/api/openai_adapter_request_test.dart` —— `reasoningEffort: 'high'`（`:105`）→ `expect(body, containsPair('reasoning_effort', 'high'))`（`:119`）
- `test/core/api/agent_api_stream_test.dart`、`agent_api_error_logging_test.dart`、`provider_chat_api_path_test.dart`

Settings：
- `test/features/settings/settings_models_test.dart`、`app_settings_notifier_test.dart`、`provider_detail_support_test.dart`、`provider_protocol_compat_test.dart`

Chat：
- `test/features/chat/`：`application/`、`domain/`、`presentation/`、`services/`、`chat_actions_test.dart`、`chat_providers_test.dart`、`chat_actions_stream_chunking_test.dart`、`chat_page_conversation_actions_test.dart`、`conversation_timeline_paging_test.dart`、`stream_placeholder_characterization_test.dart` 等

Preset（reasoningEffort 相关）：
- `test/features/agent_context/domain/silly_tavern_preset_parser_test.dart:114,156`
- `test/features/agent_context/domain/silly_tavern_actual_presets_test.dart:440`

其他目录：`test/core/`、`test/ui/`、`test/fixtures/`、`test/widget_test.dart`

---

## Caveats / 未确认

- 未检索到 Gemini `thinkingConfig` / `thinkingBudget` / `thinkingLevel` 的任何代码痕迹；Claude `thinking` 对象也无构造代码——两者当前只能靠渠道 `customConfig` 透传。
- `sessionProvider` 有 DB 字段和读路径，但未找到写入点（UI 或 repository 层），实际是否曾使用未确认。
- `ProviderCapabilities.supportsThinking` 的实际消费方未找到（疑似仅声明）。
- `.trellis/spec/backend/*` 多个文件索引标注为「To fill」，实际内容深度未逐份阅读。
- 未核实 `AppSettings.updateModelConfig` 的完整实现路径（只确认了 `model_row_tile.dart:716` 的调用点）。
