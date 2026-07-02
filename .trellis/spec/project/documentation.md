# 文档治理规则

## 文档分层

| 层 | 位置 | 放什么 |
|---|---|---|
| Trellis spec | `.trellis/spec/` | 长期有效、AI 协作优先加载的规范和决策 |
| 开发文档库 | `apps/aicove_flutter/docs/` | 面向人阅读的架构、模块、UI、功能说明 |
| 云端文档 | `cloud_backend/README.md` 与云端专题文档 | FastAPI 服务、部署、API、管理面板说明 |
| 任务记录 | `.trellis/tasks/` | 当前或近期任务 PRD、研究、验收 |
| 临时草稿 | `scratch/`、`.codex-temp/` | 一次性排查、草稿、生成物 |
| 个人笔记 | `opusdocs/`、`data/*.md` | 头脑风暴、任务备忘、旧规则历史快照，不作为规范真相源 |
| 历史归档 | `apps/aicove_flutter/docs/05_历史归档/` | 过期方案、旧重构文档、已完成施工说明 |

## 新文档落位

- 架构边界、不可违反规则：先写 `.trellis/spec/`，必要时同步到 docs。
- 模块说明、使用指南、UI 组件说明：写 `apps/aicove_flutter/docs/`。
- 临时调查报告：先写 `scratch/diagnostics/`，确认长期有效后再提炼。
- 过期方案：加日期前缀，移入 `05_历史归档/`。

## 维护要求

1. 不在根 README 堆模块细节，根 README 只保留：项目总览 + 项目宪法（不可违反规则） + 权威入口索引。
2. 不在 `AGENTS.md` 堆长篇模块文档，`AGENTS.md` 只保留硬规则和索引。
3. 变更公共组件、核心架构、聊天上下文、Agent Runtime 后，必须更新对应文档。
4. 文档链接优先使用相对路径，避免复制一份同名文档造成分叉。

## AI 上下文注入

1. 新会话默认注入短上下文：当前任务、git 摘要、短 workflow、spec 路径。
2. 详细 workflow、thinking guides、历史任务列表按需读取，不在 SessionStart 中全文注入。
3. 需求不清或方案分支较多时，在 Trellis Phase 1 使用 Grill Gate；结论写入任务 `prd.md`。
