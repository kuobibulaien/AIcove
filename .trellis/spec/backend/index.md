# AIcove Cloud Backend Guidelines

云端位于 `cloud_backend/`，基于 FastAPI。云端职责以认证、云同步、备份、触发器、记忆、额度、管理面板为主，AI 对话主链路仍在 Flutter 客户端。

## Guidelines Index

| Guide | Description | Status |
|---|---|---|
| [Directory Structure](./directory-structure.md) | 云端模块组织 | Active |
| [Database Guidelines](./database-guidelines.md) | SQLAlchemy / SQLite / 数据安全 | Active |
| [Error Handling](./error-handling.md) | FastAPI 异常与 API 响应 | Active |
| [Quality Guidelines](./quality-guidelines.md) | 验证和风险控制 | Active |
| [Logging Guidelines](./logging-guidelines.md) | 日志与排查记录 | Active |

## Pre-Development Checklist

1. 读 `cloud_backend/README.md`。
2. 涉及 Agent Context Web 面板时，读 `cloud_backend/Agent上下文系统Web管理端实施说明_20260430.md`。
3. 涉及同步/备份/记忆/触发器时，先找对应 API 和模型定义。

## Quality Check

- API 改动要同步 `cloud_backend/README.md` 或专题文档。
- 涉及数据结构、批量数据、生产 API 前必须先确认。

