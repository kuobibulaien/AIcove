---
status: accepted
date: 2026-09-03
---

# 退役 Trellis，改用 docs/项目记忆 作为跨 agent 项目记忆

## 背景

Trellis（0.6.5）自 2026-07 起管理本项目的 AI 协作流程。两个月后的审计结论：

- 用户的原始诉求是「自动记录项目信息、归纳文档，且所有 agent 共用」，Trellis 提供的却是任务流程（prd / design / implement / jsonl 清单 / 子代理派工）。
- journal 两个月只写了 2 条且带占位符；`spec/backend/` 与多篇 `spec/frontend/` 全是未填模板；32 个任务里 20 个是 7 月前遗留、状态却仍为 in_progress。
- 500 余个文件、661 行 workflow、每轮 hook 注入，用户已无法读懂其中记录。
- 真正有价值的只有：`spec/project/`（总览、边界、术语表、1 篇 ADR）、`spec/frontend/quality-guidelines.md` 里约 90 行踩坑硬约束、`spec/agent-context/index.md`，以及「复杂任务先写方案再动工」这条护栏。

## 备选

1. 瘦身保留 Trellis：归档死任务、删模板 spec。流程与文件格式不变，用户仍看不懂。
2. 换成第三方记忆框架（AXME、memento-vault、projectmem 等）：功能更多、结构同样重，且多数只覆盖单一 agent。
3. 自建极简方案：纯 markdown + `AGENTS.md` 规则 + 一个共用 hook 脚本。

## 决定

采用方案 3：

- 知识层：`docs/项目记忆/`（README 一页纸、需求日志、决策记录、经验教训、术语表、Agent 上下文规范、历史任务只读参考）。
- 规则层：`AGENTS.md` 写明「开工读 README、收工按写入规则回写」。这是所有 agent（含不支持 hook 的实验 harness）的底线。
- 加固层：`hooks/memory.py` 一个脚本，会话开始注入 README，用户每次提问自动把原话追加进需求日志。接入 Claude Code（`.claude/settings.json`）、Codex（`.codex/hooks.json`）、Pi（`.pi/extensions/memory.ts`）。
- 护栏保留一条：改动超 3 个文件或涉及架构边界的任务，先在对话中给出目标 / 边界 / 验收 / 回滚，用户确认后动工；不再要求任务目录。
- `trellis mem`（全局 CLI，读各 agent 自己的会话日志）继续用于回查历史对话，与项目内文件无关。

## 代价

- 失去 Trellis 的子代理派工上下文清单（implement.jsonl / check.jsonl）与 phase 级步骤指引；本项目实际未依赖。
- 需求日志靠 hook 记原话、靠 agent 自觉补结果，结果行可能漏；漏了可用 `trellis mem` 回查。
- 不支持 hook 的 harness 只能靠 AGENTS.md 规则，可靠度约八成。

## 回滚

`git tag pre-trellis-removal-20260903` 与 `~/ide/aicove-trellis-backup-20260903.tar.gz`（含 `.trellis` `.claude` `.codex` `.agents` 与三个入口文件）。
