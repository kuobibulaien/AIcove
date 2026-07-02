# 后台Agent架构方案

> 创建日期：2026-03-17
> 状态：设计中

---

## 概述

本文档描述一套面向主聊天的通用后台 Agent 运行时，用来承载：

- 记忆总结
- 触发器规划
- 日反思/周报
- 风险识别

目标不是“再开几个隐藏聊天窗口”，而是把后台分析能力收敛为一套可复用的公共类与运行链路：

- 主聊天继续负责实时对话
- 后台 Agent 负责异步分析
- 两者共享主聊天上下文来源
- 两者复用现有 Tool Calling 基础设施

---

## 为什么要单独建这一层

当前仓库里，后台分析能力已经以零散形式存在：

- `ContextAnalyzer`：负责 AI 管家分析
- `AnalyzerScheduler`：负责触发分析
- `background_service.dart`：负责后台任务执行
- `MemoryPlugin / MemoryService`：负责长期记忆总结与召回

这些能力已经证明“后台 AI”方向是成立的，但还缺少一个统一抽象：

1. 没有一个可复用的公共运行类来承载“预设 + 上下文范围 + 工具白名单”。
2. 记忆、触发器、反思等能力都可能重复实现“取上下文 -> 组 prompt -> 跑工具 -> 收结果”。
3. 调度逻辑和运行逻辑容易混在一起，导致职责不清。

因此，本方案新增一个明确的“后台 Agent 运行时层”，由它统一处理：

- 主聊天上下文读取
- 后台 Agent 定义
- 工具白名单过滤
- 独立 session 执行
- 运行结果回传

---

## 目录

- [01_整体架构.md](01_整体架构.md)：整体架构、职责边界、数据流
- [02_定义与运行时.md](02_定义与运行时.md)：公共类定义与执行链路
- [03_与记忆系统集成.md](03_与记忆系统集成.md)：记忆机制如何改接后台 Agent 服务

---

## 核心口径

这套方案的口径先明确为 5 条：

1. 后台 Agent 是“运行时”，不是“调度器”。
2. 上下文直接来自主聊天 `ChatHistoryStore`，不维护第二份聊天上下文。
3. 工具定义复用现有 `AITool` 体系，只做白名单过滤，不新造工具协议。
4. 后台 Agent 使用独立 `sessionId`，避免污染主聊天上下文。
5. `BackgroundAgentService` 是第一公民；记忆机制是第一批接入方，但不是唯一接入方。

---

## 涉及的现有能力

本方案优先复用以下现有实现：

- `lib/src/features/chat/services/chat_history_store.dart`
- `lib/src/features/plugins/domain/handlers/ai_tool.dart`
- `lib/src/features/plugins/plugin_manager.dart`
- `lib/src/features/chat/services/chat_send_api_runner.dart`
- `lib/src/core/api/agent_api.dart`

明确不直接复用的旧入口：

- `lib/src/features/chat/data/background_service.dart`

原因：该文件更偏向 WorkManager/通知发送场景，且存在绕过统一适配层的历史包袱，不适合作为通用后台 Agent 运行时的基础。
