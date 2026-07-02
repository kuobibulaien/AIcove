# 项目总览

AIcove 是面向医院场景的 AI 心理陪伴助手。当前仓库包含 Flutter 客户端和 FastAPI 云端服务。

## 主要边界

| 层 | 位置 | 职责 |
|---|---|---|
| Flutter 客户端 | `apps/aicove_flutter/` | UI、本地存储、聊天主链路、多模态消息、插件、Agent Runtime 消费 |
| 云端服务 | `cloud_backend/` | 认证、云同步、备份、触发器、记忆、额度、管理面板 |
| 项目文档 | `apps/aicove_flutter/docs/`、`.trellis/spec/` | 前者放可读文档库，后者放 AI 协作时优先加载的长期规范 |
| 临时资料 | `scratch/`、`.codex-temp/` | 排查输出、草稿、一次性报告，不作为权威规范 |

## 核心原则

- 聊天上下文以 DB raw message 为唯一真相源，禁止用 UI 投影或气泡缓存喂模型。
- 新能力跨层调用先定义 Port / Contract / Adapter，UI 不直接依赖具体 Service。
- Agent 方向是上下文管理系统，不是单纯提示词管理系统。
- 旧链路不做一次性大重构，新功能先规范，旧代码顺手收口。

## 权威入口

- 根说明：`README.md`
- Flutter 文档库：`apps/aicove_flutter/docs/README.md`
- 云端说明：`cloud_backend/README.md`
- Trellis 规范入口：`.trellis/spec/README.md`

