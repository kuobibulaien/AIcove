---
status: proposed
date: 2026-08-21
---

# 官方 DSH 作为唯一 Agent 驱动运行时

## Context

AIcove 已有 Agent 契约与 Dart Plugin，但聊天实际执行仍依赖旧 `ChatSendUseCase`。若在此基础上并列接入 DSH，会同时存在两套 Agent loop、Session、Tool 和 Plugin 生命周期。Android 还需要单独解决 Node/Termux Runtime、noexec、进程保活和 App/Shizuku/Root 权限路由。

## Proposed decision

- 设备本地运行的官方 DeepSeek Harness 是 AIcove 2.0 唯一 Agent loop、会话、工具和插件编排核心。
- Flutter 保留产品 UI、联系人、产品消息、投递和设备能力，通过版本化 Aicove Bridge Plugin 对接 DSH。
- DSH SessionEvent log 拟作为 Agent 执行与模型可见历史真相源；Drift raw message 保持产品时间线与投递真相源，两者只通过显式 binding 和幂等投影连接。
- DSH 常驻进程使用应用 UID；Shizuku 和 Root 作为按 Capability 调用的可选执行后端。
- 现有 Dart Agent Runtime 作为迁移契约和回滚入口，不再长期演进成另一套 Harness。

## Consequences

收益：可以直接复用 DSH 的 Agent、Cordis、Session、Skill、Tool 和 Subagent 生态，AIcove 特色能力以插件方式组合。  
代价：需要承担上游预览版兼容、Android Runtime 分发、Bridge 协议、双数据域投影与分阶段迁移成本。

## Acceptance gate

本 ADR 当前仍为 `proposed`。Phase 0 Runtime Spike 可以先做；任何改变数据库真相源语义的 schema 实施前，必须经用户确认改为 `accepted`，并同步修订现行聊天上下文规范。

详细方案：`apps/aicove_flutter/docs/02_前后端分离与架构规范/AIcove2.0_DSH驱动底层架构改造方案.md`。
