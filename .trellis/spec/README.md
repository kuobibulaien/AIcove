# AIcove Trellis Spec Index

本目录是 AIcove 的长期项目知识库。这里放"以后还要遵守"的规范，不放临时讨论、一次性排查日志或已过期施工方案。

## 阅读顺序

| 场景 | 先读 |
|---|---|
| 新会话 / 新成员接手 | `project/overview.md`、`project/documentation.md` |
| Flutter 客户端开发 | `frontend/index.md` |
| 云端 FastAPI 开发 | `backend/index.md` |
| Agent Context Runtime 相关 | `agent-context/index.md` |
| 跨层设计或重构 | `guides/index.md`、`project/architecture-boundaries.md` |

## 写入规则

1. 只写长期有效的规则、约定、架构决定和踩坑结论。
2. 具体任务方案写到 `.trellis/tasks/<task>/prd.md` 或项目 docs，完成后再提炼到 spec。
3. 已过期内容不要留在 spec，迁到 `apps/aicove_flutter/docs/05_历史归档/` 或 `scratch/`。
4. 文档使用中文，路径和代码标识保持原文。

## 文档库自动更新

AIcove 已接入 Trellis 工作流，AI 在完成实现、修 bug、架构讨论、调研或检查后，必须判断是否需要更新文档库。

详细的"何时更新 / 更新到哪里 / 落位规则"由权威文档 [`project/documentation.md`](project/documentation.md) 统一维护，本节不再重复，避免双份口径漂移。

如果判断"不需要更新文档"，最终报告要明确说明原因。
