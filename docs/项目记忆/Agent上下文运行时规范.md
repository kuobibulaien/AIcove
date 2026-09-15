# Agent Context Runtime Guidelines

## 必读

- `docs/项目记忆/README.md`（架构边界一节）
- `apps/aicove_flutter/docs/02_前后端分离与架构规范/Agent上下文管理总架构.md`
- `apps/aicove_flutter/docs/02_前后端分离与架构规范/聊天请求上下文真相源与组装规范.md`

## 核心模型

```text
Agent = 模型 + 上下文策略 + 工具策略 + 输出契约 + 后处理器
```

五类 Agent：Chat / Proactive / Analyzer / Memory / Renderer。它们共享 `AgentDefinition` 定义面，通过 `AgentContextAssemblyPermissions` 收窄职责。

## 开发规则

1. 新增 Agent 前先定义 `AgentDefinition`、`ContextProfile`、`AgentContextAssemblyPermissions`、`AgentOutputContract`、`AgentDeliveryChannel`（实际类名见 `agent_runtime_contracts.dart`）。
2. 聊天主链路不得把 UI 投影作为模型上下文，必须从 DB raw message 组装。
3. 工具调用、TTS、生图、记忆等能力要通过可调度契约接入 Agent Scheduler。
4. 旧 Web 管理面板已按 ADR0031 删除；schema 与随包资源通过源码维护，App 端继续本地消费。
5. 主动关怀 Analyzer 当前职责已拆分：`ContextAnalyzer.analyze(conversation, proactiveState: ...)` 只返回 `ContextAnalysisDecision?`；调度、会话主动状态更新、触发器写入存储由 `AnalyzerScheduler` 负责。测试应断言 analyzer 决策或 scheduler 存储结果，不再调用旧的 `analyzeAndSchedule()`。
6. Prompt 默认节点由本地 JSON 与 `apps/aicove_flutter/tool/prompt_defaults_codegen.py` 维护；App 端不得本机覆盖默认节点模板，只能创建与默认节点 ID 不冲突的自定义节点。

## Scenario: Proactive Agent Build Graph Stage Split

### 1. Scope / Trigger
- Trigger: built-in `proactive_agent:default` graph seeding, artifact sync, and Agent prompt preview.
- Scope: Agent Build graph semantics only; it does not change live proactive runtime execution.

### 2. Signatures
- Source artifact: `apps/aicove_flutter/assets/agent_context_defaults.json`, maintained locally.
- The legacy backend seed and preview API were removed by ADR0031; stage semantics below remain the local artifact contract.

### 3. Contracts
- Analyzer stage prompt nodes:
  - `auto_reply.analyzer.default`
- Reply generation stage prompt node:
  - `auto_reply.agent.objective`
- Each staged graph node must carry `config.stage`, `config.stageLabel`, and `config.stageOrder`.
- `auto_reply.analyzer.default` owns the runtime-state `{state_json}` injection point and proactive tool workflow instructions; prompt defaults declare `current_role_persona` and `trigger_list`, while `{state_json}` carries shortened current-role persona and trigger summaries.
- The former auto-reply runtime-instruction prompt must not appear as a standalone prompt default, graph node, binding, or synced artifact node.
- Analyzer-stage nodes must not be connected to reply-generation nodes as one prompt chain.
- Prompt preview response must expose stage-grouped prompt text while preserving node order inside each stage.
- If a legacy proactive graph is reconstructed from derived bindings, bootstrap must still migrate the unstaged linear graph into the staged graph before syncing the Flutter artifact.

### 4. Validation & Error Matrix
- Missing referenced prompt default -> preview warning `提示词节点不存在：<id>`.
- Empty enabled prompt set -> preview warning `当前图没有启用的 prompt 节点。`.
- Graph edge references missing node id -> graph validation error on save.

### 5. Good/Base/Bad Cases
- Good: analyzer default in `analyzer`; reply objective is a separate `reply_generation` entry/output.
- Base: unstaged custom graph previews under a single default stage.
- Bad: analyzer default -> reply objective, which falsely implies one model request.

### 6. Tests Required
- Assert built-in proactive graph contains both `analyzer` and `reply_generation` stages, with no standalone runtime instruction node.
- Assert no edge crosses from analyzer prompts into `auto_reply.agent.objective`.
- Assert legacy seeded linear graph migrates to the stage-split graph.
- Assert binding-only legacy proactive seeds also migrate to the stage-split graph.
- Assert prompt preview returns ordered stage groups.

### 7. Wrong vs Correct

#### Wrong
```text
auto_reply.analyzer.default -> auto_reply.agent.objective
```

#### Correct
```text
Analyzer / trigger decision:
  auto_reply.analyzer.default

Proactive reply generation:
  auto_reply.agent.objective
```

## Scenario: Node Library Variable Runtime Contracts

### 1. Scope / Trigger
- Trigger: Agent Context Studio Node Studio / Agent Build prompt debugging.
- Scope: `prompt_defaults.json` variable nodes, prompt default virtual nodes, Agent prompt preview, and synced Flutter `agent_context_defaults.json` node library summaries.

### 2. Contracts
- Prompt default variables must distinguish three concepts:
  - `valueSource`: where the real runtime value is injected from.
  - `runtimeShape`: the expected runtime value structure.
  - `sampleValue` / `runtimeSampleValue`: preview-only fallback values.
- Agent prompt preview must render templates with supplied runtime values first, then variable runtime samples, then sample values.
- Preview responses must keep the original template available while exposing rendered text for debugging.
- Validation should warn for:
  - placeholders with no variable definition,
  - template placeholders not listed in a prompt's `variables`,
  - prompt `variables` entries not used by the template,
  - variables not referenced or declared by any default prompt.
- `state_json` must document and sample the same fields emitted by `ContextAnalyzer._buildRuntimeStateJson`.

### 3. Tests Required
- Backend preview tests must assert rendered variable substitution and validation warnings.
- Flutter asset tests must assert the synced node library exposes `variableContracts` for runtime variables.

## Scenario: Proactive Background Delivery

### 1. Scope / Trigger
- Trigger: proactive trigger creation, resume, retry, pause, delete, completion, final failure, or app background lifecycle.
- Scope: Flutter trigger controller, analyzer scheduler, WorkManager input, background isolate initialization, notification, and SQLite persistence.

### 2. Signatures
- `AutoReplyTriggerController.createTrigger(...)` and `createManualTrigger(...)` persist the trigger, then schedule `BackgroundService.scheduleOneOffTask(...)`.
- `AutoReplyTriggerController.togglePause(...)`, `deleteTrigger(...)`, and terminal delivery paths call `BackgroundService.cancelTaskByTriggerId(triggerId)`.
- `AnalyzerScheduler.onAppBackground()` schedules a delayed `_runAnalysis(conversationId, reason: 'app_background')` for the current active conversation.
- `BackgroundService.scheduleOneOffTask(uniqueName: 'trigger_$id', delay: ..., inputData: {...})` registers `taskNameActiveReply`.
- `callbackDispatcher()` is the WorkManager entry point and must initialize Flutter plugins before using platform channels.

### 3. Contracts
- Active trigger create, resume, and retry must register a one-off WorkManager task keyed as `trigger_<triggerId>`.
- Pause, delete, success, expiry, and final failure must cancel the matching background task.
- WorkManager `inputData` must include `triggerId`, `convId`, `prompt`, `model`, `apiBase`, and `characterName`; include `apiKey` only when available; pass `requestFormat`, `apiPath`, and `vertexExpress` from provider custom config when present.
- A trigger with non-empty `cachedContent` must schedule and run without a provider API key.
- Live generation may skip execution when no API key is available and no cached reply exists.
- Background persistence must write the assistant message before notification; notification failure logs a warning and must not undo the stored message.
- Stored assistant message `content` and `rawPayload` preserve the raw reply, while conversation summary uses a cleaned preview for `<tts>` / `<image>` style tags.
- App background analysis uses a short delay and cooldown; app resume and scheduler cancel must cancel any pending background analysis timer.

### 4. Validation & Error Matrix
- Empty `convId` -> skip task and record warning history.
- Empty API key with no cached reply -> skip live generation and record warning history.
- WorkManager schedule failure -> keep trigger state and record warning history.
- WorkManager cancel failure -> log warning without throwing to caller.
- Notification failure after message write -> record warning history; message remains in local storage.
- Unknown multimodal-only display text -> use a readable conversation summary such as `[图片]`.

### 5. Good/Base/Bad Cases
- Good: creating an active trigger registers `trigger_<id>`, then background isolate writes the message and tries notification.
- Base: cached proactive content sends in background with no API key.
- Bad: relying only on foreground polling timers; mobile OS background suspension prevents delivery.

### 6. Tests Required
- Assert trigger creation registers `registerOneOffTask` with trigger and model input fields.
- Assert cached background replies do not require model API key.
- Assert background storage payload keeps raw reply text while cleaning display text for known multimodal tags.
- Assert notification failure does not prevent local message persistence.
- Assert pause/delete/success/final failure cancel the matching background task when plugin APIs are available.

### 7. Wrong vs Correct

#### Wrong
```dart
await _persist([...current, trigger]);
// Wait for the foreground 30s poller to notice the trigger.
```

#### Correct
```dart
await _persist([...current, trigger]);
await _scheduleBackgroundTaskForTrigger(trigger);
```

## Scenario: Proactive Foreground Delivery

### 1. Scope / Trigger
- Trigger: Flutter foreground polling finds an active proactive trigger whose target conversation is currently open.
- Scope: trigger expiry rules and foreground dispatch into the local chat timeline.

### 2. Contracts
- A low-priority proactive trigger must not expire only because the target chat page is active.
- If the user has not sent a newer message since trigger creation, foreground polling should dispatch the trigger so the open chat can observe the database update.
- A newer user message still expires low-priority and medium-priority non-manual triggers.

### 3. Tests Required
- Assert low-priority triggers survive `isChatActive == true` when the last user message is unchanged.
- Assert low-priority triggers still expire when the last user message changed.

## Scenario: Proactive Memory Linkage

### 1. Scope / Trigger
- Trigger: proactive analyzer or agent needs contextual memory to inform trigger scheduling or reply generation decisions.
- Scope: interface contract only — declares the future capability signature without runtime implementation.

### 2. Signatures
- Memory retrieval: `Future<List<MemorySnippet>> retrieveRelevantMemories({ required String conversationId, String? query, int? limit })`
- Memory snippet model: `{ id, content, layer, category, createdAt, tags, relevanceScore }`
- Integration point: `ContextAnalyzer.analyze(...)` and `AutoReplyAgent.generate(...)` receive optional memory context via `AnalysisContext` / `AgentContext`.

### 3. Contracts
- **Retrieval contract:** when a proactive analyzer runs, it may optionally request recent/relevant memories for the target conversation; the retrieval layer returns ranked snippets (L1 → L2 → L3) with relevance scores.
- **Injection contract:** retrieved memories are injected into the analyzer prompt as `{relevant_memories}` or into the agent reply prompt as `{context_memories}`, formatted as timestamped bullet points.
- **Fallback contract:** if memory retrieval fails or returns empty, analyzer/agent proceeds without memory context; absence of memory must not block proactive trigger creation or reply generation.
- **Privacy contract:** memory content must not be sent to backend APIs unless explicitly enabled by user; local-first proactive flow uses local memory store only.

### 4. Validation & Error Matrix
- Empty memory result → proceed without memory context, no error logged.
- Memory retrieval timeout (>500ms) → proceed without memory, log warning.
- Missing `conversationId` → skip retrieval, proceed without memory.

### 5. Good/Base/Bad Cases
- **Good:** Analyzer retrieves last 7 days of L1/L2 memories for the target conversation, injects ranked snippets into prompt, analyzer produces more contextually-aware trigger decisions.
- **Base:** Memory feature flag disabled; analyzer and agent skip retrieval, proactive flow works as before.
- **Bad:** Memory retrieval blocks analyzer execution for >2s; user sees delayed proactive message due to memory timeout.

### 6. Tests Required
- Assert analyzer can receive optional memory context without breaking existing flow.
- Assert agent prompt supports optional `{context_memories}` placeholder.
- Assert empty memory result does not prevent trigger creation or reply generation.
- Assert memory retrieval errors are logged and swallowed, not propagated to caller.

### 7. Implementation Note
This scenario documents the **interface contract** for future memory linkage. Runtime implementation is deferred to a later phase; current analyzer and agent flows must remain functional without memory integration.

## 联系人 MD 记忆工具（2026-09-05，第一批已实现）

本节补充标准聊天的实际能力，不将上节主动关怀接口标成已实现。

1. `ContactMemoryPort.load/save` 必须显式传入稳定 owner；新模式真相源是各角色独立 MD，聊天原始消息仍在 DB。
2. `memory_search(query, offset)` 与 `memory_read(id, offset)` 只读，参数不得包含 owner/path。`ChatPluginContextBuilder` 从本次请求取得 owner，handler 闭包固定它。
3. 工具 schema 与执行器一起保存到 `ApiConfig.boundTools`，`ChatSendApiRunner` 优先使用此绑定；禁止工具执行时重新按 activeConversation 查询所属角色。
4. 缺 owner、角色删除、禁用插件、关闭 MD 或文档损坏必须失败关闭；常驻读取失败可继续无记忆聊天，但不得隐式跨角色/跨旧库补齐。
5. 首批仅手工维护。新增自动 MemoryAgent 时仍需定义上下文/输出契约、读取 DB raw messages、验证来源及版本后提交，不能直接复用旧库的 summarized 成功判定。

实现与测试入口：客户端 `docs/04_功能模块规范/记忆系统/联系人Markdown记忆.md`、`test/features/memory/contact_memory_plugin_test.dart`。

## 手动内容交接 Agent（2026-09-05）

- 定义：`local.topic_content_handoff`，`AgentKind.summarizer` / `stateChange`，只允许 conversationWindow 与 JSON 输出；不装配角色卡、不使用工具、不覆盖管理端默认节点。`BackgroundTopicSummaryAdapter` 将定义桥接到现有 BackgroundAgentService，输出只投递后台 trace 和经过校验的 UI 草稿，不直接写记忆。
- 输入：`TopicHandoffStorePort.snapshot(owner)` 从 DB raw 取得明确范围，携带之前的内容摘要；不是 UI messages.last，不是已裁过的最近 N 条。前一摘要仅作派生背景，来源范围和校验仍绑定 raw。
- 输出：仅 `{"facts":["..."]}`；规范化为有界纯内容摘要。空事实结果不得抹掉已有背景，格式/身份/标签要求不得晋升为永久事实。摘要是有损草稿，人工预览后才提交。
- 提交：`TopicCompactionPort.commit` 将摘要、来源、旧/新边界及 pending 同事务保存，再调用 ContactMemoryPort；MD 失败可重试，不能提前标记已归档。生成互斥读取 `conversationSendingProvider(owner)`，不是全局 active 对话发送状态。
- 读取：标准聊天普通/酒馆装配读取有效交接摘要，不带旧原文；来源改变或重放范围内旧轮次时不注入旧交接摘要。预算不足不得发送丢失当前问题的请求。主动关怀/分析器没有在本批扩大装配权限。

实现与测试：`features/chat/{domain/topic_compaction_port.dart,application/topic_compaction_service.dart,data/background_topic_summary_adapter.dart,data/sqlite_topic_handoff_store.dart}`、`test/features/chat/topic_compaction_test.dart`。自动压缩按 ADR0027 经 AutomaticContextPort 在每轮工具循环的模型请求前做预算检查：默认 272k 窗口、80% 触发线、16% 近期原文预算，产出结构化摘要与有来源的记忆增量，不调用手动新话题入口；ADR0024 的触发与保留策略已被取代，仅其移除条数设置的决定保留。
