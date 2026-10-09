# 0060 Agent 统一装配：配方与调度分离

- 状态：accepted
- 日期：2026-10-07
- 关联：ADR0064（Dart 微内核运行时，取代 ADR0001）、ADR0038（记忆与上下文两层）；规则落点：[Agent上下文运行时规范](../Agent上下文运行时规范.md) 开发规则第 7 条

## 背景

`agent_runtime_contracts.dart` 早已定义 `ContextProfile` 与按职责收窄的权限集合（`fullChat`／`proactiveSpecialized`／`analyzerSpecialized`／`memorySpecialized`／`rendererSpecialized`），但实际存在三套上下文拼装：

1. `ContextProfile`：前台聊天 `standard_chat_agent.dart`、后台摘要 `background_context_summarizer.dart` 在用。
2. `BackgroundContextSpec`（`features/background_agent/domain/`）：只描述“最近 N 条＋角色过滤”的另一份配方格式。
3. `features/auto_reply/data/background_service.dart` 的 `_fetchAiReply`：后台主动回复自取最近 10 条、自写系统提示词、自拼请求体直接发 HTTP。

`proactiveSpecialized` 定义后没有调用方。主链路修改上下文规则（预设、记忆、插件标签过滤等）时，第 2、3 条不会跟进，主动消息与日常聊天表现会分叉且难以排查。

同时确有不同 Agent 需要不同上下文（子代理不应拿全部上下文），以及后台 Agent 需与前台独立运行的需求。

## 备选

1. 保持独立：后台主动回复继续自拼，文档记录差异。改动最少，两条链路持续分叉。
2. 统一装配：所有 Agent 走同一装配机器，差异由配方表达；前后台差异由调度决定，不另写拼法。

## 决定

采用 2。

- **两条轴分开**：“看到什么”由 `ContextProfile`（层、权限集合、优先级、token 预算）声明；“在哪、何时跑”由 `AgentScheduler` 决定。后台不等于上下文少，前台也可以有窄配方 Agent。
- **一台装配机器**：全项目只保留一处上下文组装与模型调用实现；新增 Agent 只提供配方、工具策略与输出契约，不得自行拼请求或直连供应商。
- **子代理上下文**：默认用“切片”（按配方从 DB raw 真相源读取），不依赖前台运行时递交状态；需要传递上游意图时用显式交接单，内容可审计。
- **后台可独立启动**：后台 Agent 运行只依赖 DB、设置与配方等纯数据，不依赖 UI 状态或前台对象，可在无界面的后台环境启动。
- **产出写入点事先定死**：后台产出只经 `AgentDeliveryChannel` 写入，带来源标记（哪个 Agent、何时、何触发）。写入聊天原文（如主动消息）与写入旁路（记忆库、摘要表，见 ADR0038）在 Agent 定义时声明，不在运行中临时决定。
- **收拢现状**：`_fetchAiReply` 改走统一装配并使用 `proactiveSpecialized`；`BackgroundContextSpec` 并入 `ContextProfile`（可表达为 `conversationWindow` 层参数）。代码收拢单独排期，本 ADR 先定方向。收拢时一并处理后台主动回复的中断缺口（2026-10-07 Codex 排查）：执行权认领持久化后进程被杀不会释放（`features/auto_reply/data/auto_reply_claim_store.dart`），任务在送达前即持久化为 `fired`（`auto_reply_trigger_controller.dart`），可能漏发。
- **统一事件流**：运行时对外只发一种事件流（轮次开始／结束、消息增量、工具开始／结束、压缩、钩子结果等），界面、诊断日志、测试都订阅它；不再在发送接口上逐个追加回调（现有 `ChatSendPort.executeApiCall` 的 `onStreamTextDelta`／`onStreamToolCallObserved`／`onStreamingFallback` 等收拢到事件流）。事件在产生处带上轮次、会话、运行、模块编号（ADR0065）。
- 与 ADR0064 的关系：ADR0001（DSH）已被 ADR0064（Dart 微内核＋全插件化）取代，“装配机器”位于 ADR0064 的内核，本 ADR 的配方／调度分离与验收项照常适用。

## 验收项（写入相关任务书）

1. 新增 Agent 必须声明 `ContextProfile`，代码中不得出现自拼请求体或直连供应商端点。
2. 后台 Agent 能在无界面环境仅凭 DB、设置与配方启动。
3. 后台产出只经投递通道写入，并带来源标记。
4. 核心装配与运行可用假模型跑通测试。

## 代价

- 后台环境需要能构建统一装配所需的依赖，比自拼请求多一层初始化工作。
- `BackgroundContextSpec` 迁移涉及已保存的后台 Agent 定义，需兼容读取旧字段。
- 收拢前三套拼法仍会并存，期间主动消息与聊天行为可能不一致。
