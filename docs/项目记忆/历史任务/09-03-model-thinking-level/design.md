# Design: 模型思考档位

路径基准 `apps/aicove_flutter/`。

## 1. 领域模型（新文件 `lib/src/core/api/thinking/thinking_level.dart`）

```dart
enum ThinkingLevel { auto, off, minimal, low, medium, high, xhigh, max }
// 存储值 = name（小写）；auto 表示"不发参数"，等价于持久层的 null。

enum ThinkingScheme {
  openaiEffort,      // reasoning_effort 原生枚举
  claudeEffort,      // output_config.effort（4.6+）
  claudeBudget,      // budget_tokens（≤4.5）
  geminiLevel,       // thinkingLevel（3.x）
  geminiBudget,      // thinkingBudget（2.5）
  generic,           // 未识别：四档，按 provider 翻译
}

class ThinkingLevelOptions {
  final ThinkingScheme scheme;
  final List<ThinkingLevel> levels;   // 始终以 auto 开头；R2.3
  final bool isNative;                // true = R2.1 展示上游档位；false = 四档
  ThinkingLevel get softwareDefault;  // R1.5：off 优先，否则最低档；generic 为 auto（见 §3.2）
}

ThinkingLevelOptions resolveThinkingOptions({required String providerType, required String modelId});
ThinkingLevel coerceThinkingLevel(ThinkingLevel requested, ThinkingLevelOptions options); // R2.4 最近降级
```

目录表 `thinking_level_catalog.dart`（静态，正则匹配小写 modelId）：

| providerType | 模型模式 | scheme | levels |
|---|---|---|---|
| openai/兼容 | `gpt-5\.[2-9]|gpt-5\.1-codex-max|gpt-5\.\d+-codex` | openaiEffort | auto, off(none), low, medium, high, xhigh |
| openai/兼容 | `gpt-5\.1` / `gpt-5(?!\.)` | openaiEffort | auto, off(none)/minimal, low, medium, high |
| openai/兼容 | `o[134](-|$)` | openaiEffort | auto, low, medium, high |
| openai/兼容 | 其他 | generic | auto, off, low, medium, high |
| claude | `fable-5|mythos` | claudeEffort | auto, low, medium, high, xhigh, max（无 off） |
| claude | `opus-5|opus-4-[78]|sonnet-5` | claudeEffort | auto, off, low, medium, high, xhigh, max |
| claude | `opus-4-6|sonnet-4-6` | claudeEffort | auto, off, low, medium, high, max |
| claude | 其他 | claudeBudget | auto, off, low, medium, high |
| gemini | `gemini-3.*pro` | geminiLevel | auto, low, medium, high |
| gemini | `gemini-3` | geminiLevel | auto, minimal, low, medium, high |
| gemini | 其他 | geminiBudget | auto, off, low, medium, high |

降级规则：按枚举序号找最近的可用档位，同距离取更高档；`off` 不可用时降到该方案最低档。

## 2. 数据层

### 2.1 模型默认档位
`ModelConfig` 新增 `final ThinkingLevel? thinkingLevel;`（`settings_models.dart:844`），JSON 键 `thinking_level`（null 不写），`copyWith(clearThinkingLevel)`、`isDefault` 同步。`normalizeUiModelsStoreData` 对非法值归 null。

### 2.2 会话级覆盖
- Drift：`Conversations` 加列 `thinkingLevels TEXT nullable`（JSON 对象 `{modelRef: level}`）；schemaVersion 14→15，`_safeAddColumn('conversations', 'thinking_levels TEXT')`。
- 实体 `Conversation.thinkingLevels: Map<String, ThinkingLevel>`（默认空），converters 双向、`sync_service.dart:187` 旁加 `thinking_levels`。
- Repository：`updateConversationThinkingLevel(conversationId, modelRef, ThinkingLevel?)`（null/auto = 删键）。

## 3. 请求链路

### 3.1 解析生效档位（`chat_request_config.dart:338` 附近）
`ChatRequestConfig` 新增 `ThinkingLevel? modelDefaultThinkingLevel`（读 `modelConfig.thinkingLevel`）。

### 3.2 注入（`chat_send_backend_service.dart:650`）
```
options   = resolveThinkingOptions(providerType, modelId)
explicit  = conv.thinkingLevels[modelRef] ?? config.modelDefaultThinkingLevel
          ?? fromPresetEffort(boundPreset?.reasoningEffort)   // 字符串→ThinkingLevel，解析失败=null
level     = explicit == null ? options.softwareDefault : coerceThinkingLevel(explicit, options)
```
`ThinkingLevelOptions.softwareDefault`（R1.5）：`levels` 含 `off` 则 `off`，否则取 `levels` 中除 `auto` 外序号最小的档位（Fable 5 → low，Gemini 3 Flash → minimal，Gemini 3 Pro → low，o 系 → low）。generic（未识别 OpenAI 兼容）方案的 `off` 无法可靠翻译成 `none`（部分上游会 400），因此 generic 的 `softwareDefault` 为 `auto`（不发参数），而用户主动选 `off` 时才发 `none`。
`providerRequestOptions` 改为**总是构造**（去掉 `boundPreset == null ? null` 短路），新增字段 `ThinkingLevel? thinkingLevel` 与 `ThinkingScheme? thinkingScheme`；`reasoningEffort` 字段保留但只在无 thinkingLevel 时由适配器回退使用（兼容旧测试）。

### 3.3 适配器翻译

**OpenAI**（`openai_adapter.dart:_applyRequestOptions`）：
`level` → `reasoning_effort`：off→`none`（模式含 none）/ 不发；minimal→`minimal`；其余同名。generic 方案时 xhigh/max→`high`。

**Claude**（`claude_adapter.dart:_applyRequestOptions`）：
- claudeEffort：`body['thinking'] = {type: adaptive}`，`body['output_config'] = {...existing, effort: level}`；off → `thinking: {type: disabled}` 且不写 effort。
- claudeBudget：off → `thinking: {type: disabled}`；低/中/高 → `{type: enabled, budget_tokens: min(N, maxTokens - 1)}`，N ∈ {2048, 8192, 16384}；若 `maxTokens ≤ 1024`，跳过并记 trace。
- 顺序：在 `customConfig` 展开之后写入，确保覆盖同名键。

**Gemini**（`gemini_adapter.dart:_applyRequestOptions`）：
- 取 `generationConfig['thinkingConfig']` 现有 map（可能来自 customConfig），先删 `thinkingLevel` 与 `thinkingBudget` 两键再写；geminiLevel 写 `thinkingLevel: LEVEL.upper()`；geminiBudget 写 `thinkingBudget`（off 0 / low 1024 / medium 8192 / high -1）；同时 `includeThoughts: true` 以便展示（R5）。

### 3.4 参数追踪
`parameterTraceForProvider`：claude / gemini 支持集合加 `thinking_level`；`toTraceJson` 输出 `thinkingLevel`/`thinkingScheme`。

## 4. 流式解析（R5.1）
`agent_api_stream_support.dart` Gemini 分支：`candidates[0].content.parts[]` 中 `part['thought'] == true` 的 `text` 走 `emitReasoningDelta`，其余走正文。

## 5. UI

- 新组件 `lib/src/features/chat/presentation/widgets/thinking_level_sheet.dart`：`showThinkingLevelSheet(context, {modelRef, current, options, source})`，列表项 = 档位 + 一句新手说明 + 当前生效来源标签；返回选中值。
- `composer_model_picker_sheet.dart`：每个 `_ModelPickerTile` trailing 加当前档位小徽标，点按打开 sheet 并写会话覆盖；当前会话 id 从现有 provider 取。
- `composer.dart:1326` 旁：模型名旁显示当前生效档位（auto 时不显示），点按同上。
- `model_row_tile.dart:224` 编辑弹层：新增「默认思考档位」下拉，选项来自 `resolveThinkingOptions`。
- 文案表（canonical → 中文 + 说明）集中在 `thinking_level_labels.dart`。

## 6. 兼容与回滚
- 旧库 / 旧 store 无字段 → 全部 null → 行为等同现状（AC8）。
- 若适配器改动引发上游 400，回滚点为 3.3 各 adapter 的 `_applyRequestOptions` 段落，数据层可保留。
- 已导入预设的用户无感知（优先级第三级）。

## 7. 取舍
- 静态目录表 vs Models API：选静态，离线可测；代价是新模型上线后需要补表，未命中兜底四档不报错。
- 会话 map 存 JSON 列 vs 关联表：选 JSON 列，会话内模型数量极小，避免新表与 build_runner 负担。
