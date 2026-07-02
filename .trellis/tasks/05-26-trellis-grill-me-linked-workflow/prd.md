# design: trellis grill-me linked workflow

## Goal

把用户提出需求后的协作方式固定成一条稳定流程：先由 AI 问清需求并记录到任务文档，再进入实现与检查，尽量减少中途反复确认。

## What I Already Know

* 用户希望自己只提出需求，其余流程由 AI 主动推进。
* 需求澄清阶段需要记录入文档库，避免后续上下文丢失。
* 设计期可以使用 `grill-me` 的“一次一个问题 + 推荐答案”方式提高需求质量。
* Trellis 当前以 `.trellis/workflow.md` 作为工作流来源，任务状态提示由 Codex hook 读取其中的 `[workflow-state:*]` 块。
* Codex 平台当前推荐通过 `trellis-implement` / `trellis-check` 子代理执行实现和检查。

## Requirements

* 新需求进入时，Trellis 负责创建任务、维护 `prd.md`、配置执行上下文。
* 需求不清、存在设计分支或需要检验方案时，进入一个明确的 Grill Gate：一次只问一个关键问题，并给出推荐答案。
* 每个用户回答都必须立刻写回 `prd.md`，不能只保存在对话里。
* Grill Gate 结束后，AI 给出简短需求确认；用户确认后进入实现阶段。
* 实现阶段默认一气呵成：执行实现、检查、必要的文档更新，再报告结果。
* 只有重大变更或高风险操作需要额外确认；普通实现不重复打断用户。
* Grill Gate 不能退化成普通确认清单；它必须沿着方案分支、依赖关系、失败场景逐步追问，直到形成共享理解。

## Acceptance Criteria

* [x] `.trellis/workflow.md` 明确描述 Grill Gate 在 Phase 1 的位置和行为。
* [x] Skill Routing 能把“需求澄清 / 方案质询 / grill me”导向 Trellis + grill-me 联动。
* [x] Codex 每轮 planning 状态提示能提醒 AI 更新 `prd.md` 后再继续。
* [x] 项目本地 skill 或等效入口说明该联动的执行规则。
* [x] 设计不破坏现有 Trellis 任务、实现、检查、收尾流程。

## Recommended Design

采用“Grill Gate 作为 Trellis Phase 1 子步骤”的设计：

1. `trellis-brainstorm` 创建任务并初始化 `prd.md`。
2. AI 自查代码、文档和现有约定，能自行确认的内容不问用户。
3. 对阻塞性或偏好性问题，使用 Grill Gate：一次一个问题，附推荐答案。
4. 用户回答后，立即把结论写入 `prd.md`。
5. 开放问题清完后，给出简短确认。
6. 确认后进入 Trellis Phase 2：实现、检查、必要文档更新。

## Design Boundary

* `grill-me` 的职责保持不变：质询计划或设计，沿设计树逐个解决关键问题，并给出推荐答案。
* Trellis 不替代 `grill-me` 的追问方式，只负责保存任务状态、PRD、研究记录和执行上下文。
* Grill Gate 只在需求不清、设计分支较多、影响范围较大或用户明确要求质询时启用。
* 简单明确的小任务可以跳过 Grill Gate，直接由 Trellis 记录需求并执行。

## Out of Scope

* 不修改 Trellis 上游包。
* 不改变任务存储结构。
* 不引入新的运行时依赖。
* 不绕过现有高风险操作确认规则。

## Technical Notes

* 主要改动点预计是 `.trellis/workflow.md`。
* 如需自动触发说明，建议新增项目本地 skill：`.agents/skills/trellis-grill-gate/SKILL.md`。
* Codex hook `.codex/hooks/inject-workflow-state.py` 已从 `.trellis/workflow.md` 读取状态块，优先不改 hook。
* `grill-me` 当前是全局 skill；本项目只在工作流中定义何时调用它，不复制其实现。

## Context Redundancy Findings

* SessionStart 当前注入约 24k 字符，其中 `<workflow>` 约 16.8k 字符，是最大来源。
* `<workflow>` 已包含 Phase 1/2/3 细节，`<task-status>` 又重复提示下一步；两者职责重叠。
* `<current-state>` 同时列出 `ACTIVE TASKS` 和 `MY TASKS`，当前 13 个任务被重复展示。
* `<guidelines>` 内联了 thinking guides，同时又列出 spec index；对普通任务来说，thinking guides 可改为按需读取。
* 每轮 UserPromptSubmit 注入约 521 字符，体量合理；真正需要优化的是新会话注入内容。
* 当前任务的 `implement.jsonl` / `check.jsonl` 仍是 seed 状态；在规划阶段无需注入完整实现检查上下文。

## Implementation Result

* Codex SessionStart 改为短上下文：当前任务、git 摘要、短 workflow、spec/guide 路径。
* SessionStart 实测从约 24k 字符降到 4710 字符。
* UserPromptSubmit workflow-state 实测为 397 字符。
* Grill Gate 已写入 `.trellis/workflow.md` 和 `.agents/skills/trellis-grill-gate/SKILL.md`。
* 长期约定已写入 `.trellis/spec/project/documentation.md`。
