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
7. 全项目只有一处上下文装配与模型调用实现：Agent 的“看到什么”只由 `ContextProfile` 声明，“在哪、何时跑”只由调度器决定；后台 Agent 不得另写拼法或直连供应商，只依赖 DB、设置与配方启动，产出经投递通道写入并带来源标记（ADR0060）。

## Agent 架构验收清单（2026-10-07）

给 AI 写 Agent 相关任务书时按需摘取，作为验收项。来源是 Pi 对照学习与 ADR0060～0067；每条的决策出处见括号。

| 方面 | 验收项 |
|---|---|
| 核心边界 | 新入口与新 Agent 走统一装配，不自拼请求、不直连供应商；核心可用假模型跑通（ADR0060） |
| 上下文 | 请求副本每轮从 raw 现做，不维护逐步修改的“当前上下文”缓存；新增加工步骤写明在流水线中的位置与读写范围；每轮变化的内容不进请求开头；预览与真实发送共用同一流水线（ADR0067） |
| 工具 | 模型需要看到结果才做成工具，否则用输出标签；任何失败都作为结果交还模型；工具输出有上限并提示已截断；修改同一对象的并发调用排队 |
| 压缩 | 压缩后仍超长只重试一次；切点不拆开工具调用与结果；编辑来源后旧摘要不再使用；旧工具结果按时间清理（ADR0061）；聊天与任务分用不同摘要口径（ADR0062） |
| 扩展点 | 钩子写明时机与权力（只通知／可改／可拦），至少有一个真实使用者；新插件接入不改发送核心；把关类钩子出错即拦截，装饰类出错即跳过（ADR0063） |
| 持久化 | 新数据表注明是真相还是派生，派生可删后重建；可编辑数据说明对依赖方的影响与同步合并规则；会中断的任务进度与结果同一事务提交；进程任意时刻被杀后重启无永久卡住状态；迁移有从旧版本升级的测试 |
| 安全 | 按 ADR0066 定位，不加监控与审核；新增外发点让用户可见、可关；同步不泄露 |
| 可观测 | 诊断日志只含白名单字段，测试断言不含正文；新记录点源头带轮次／会话／运行／模块编号；新观察需求订阅统一事件流（ADR0060、ADR0065）；缓存与成本相关改动附命中数据（ADR0067）；流水线重构附请求回放比对 |

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

## 短期／长期记忆的 Agent 边界（2026-09-23，ADR0038）

本节取代 2026-09-05 的「联系人 MD 记忆工具」与「手动内容交接 Agent」两节（旧文见 git 历史与客户端 `05_历史归档/20260923_旧记忆与压缩方案/`）。

1. **聊天模型不带记忆工具。** 长期记忆由 `MemoryPlugin` 在请求前注入（常驻层＋关键词检索出的档案），注入内容显式固定请求 owner；请求副本成对过滤历史中的 `memory_search`、`memory_read`、`context_read`。
2. **压缩 Agent**：`local.topic_content_handoff`（手动）、`local.automatic_context`（自动与运行时），只允许 conversationWindow 输入与 JSON 输出，无工具、无角色卡，只写摘要。输入来自 DB raw 快照，不是 UI 投影。
3. **记忆 Agent**：`local.memory_keeper`，只在压缩成功后、发送时续跑、用户点「继续／重建」时运行。输入是一批 raw 原文＋常驻层＋相关档案；唯一工具是只读 `memory_search`（handler 闭包固定 owner）。输出 `{"ops":[...]}` 由代码校验来源、归属与锁定后，与书签推进同事务写入 `memory_items`。
4. 处理目标由 `context_summaries` 推算，不另设任务表；同一 owner 串行；重建代次变化时丢弃旧批次。失败只记录错误，不阻塞聊天。
5. 缺 owner、角色删除、未启用「记忆」插件时失败关闭：不注入、不整理。

实现与测试：客户端 `docs/04_功能模块规范/记忆系统/README.md`；`test/features/context/`、`test/features/memory/memory_keeper_test.dart`。
