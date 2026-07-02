# brainstorm: 提示词管理面板节点一致性与手机端支持

## Goal

排查提示词管理面板中的配置项是否与实际运行的提示词节点一一对应，并为手机端补齐同类管理能力。

## What I already know

* 用户关注现有提示词管理面板与实际运行节点之间的对应关系。
* 手机端现在也需要具备提示词管理能力。
* 用户已明确策略：Web 端是默认提示词配置来源；手机端默认节点不允许本机修改；手机端可以新增自定义节点。
* `apps/aicove_flutter/assets/prompt_defaults.json` 当前有 34 个提示词默认值。
* `PromptBuiltinDefaults` 中 34 个提示词常量都被 Flutter 运行代码引用。
* `apps/aicove_flutter/assets/agent_context_defaults.json` 当前只同步 Agent Build 图里被引用的 10 个 prompt 节点。
* `cloud_backend/agent_context_admin_api.py` 的 Node Studio 会把全部 prompt defaults 暴露为只读虚拟节点，Agent Build artifact 只包含被图引用的节点。

## Assumptions (temporary)

* 现有管理面板可能在管理端或 Flutter 宽屏界面中。
* 实际运行节点可能分布在前端编排、后端 agent workflow 或 prompt assembly 代码中。
* 手机端应复用已有数据模型与接口，避免创建第二套配置来源。

## Open Questions

* 无阻塞问题。

## Requirements (evolving)

* 梳理管理面板中的提示词配置项。
* 梳理实际运行的提示词节点。
* 找出缺失、多余或命名不一致的项。
* 给出手机端功能的最小实现范围。
* 手机端新增提示词节点页面：默认节点只读，支持查看用途和 Agent Build 图引用；自定义节点可以新建。
* 不保留“本机覆盖默认节点”策略，Web 端默认配置更新后应成为手机端默认节点的来源。

## Acceptance Criteria (evolving)

* [x] 输出提示词管理项与运行节点的对应关系。
* [x] 明确需要新增或修正的节点映射。
* [x] 手机端可以访问对应提示词节点核对页。
* [x] 质量检查按项目要求执行。
* [x] 手机端页面能显示 34 个内置提示词的运行用途。
* [x] 手机端页面能标记 10 个 Agent Build 图节点及其所属 Agent。
* [x] 手机端默认节点只读，不允许本机覆盖默认模板。
* [x] 手机端支持新建自定义节点，且自定义节点不覆盖同 ID 默认节点。
* [x] 文档说明 Web 默认配置、手机默认节点和手机自定义节点的边界。

## Definition of Done (team quality bar)

* Tests added/updated where appropriate.
* `flutter pub get` and compile/run verification completed.
* Narrow and wide screen behavior checked where UI changes are made.
* Docs/notes updated only if behavior or durable conventions change.

## Out of Scope (explicit)

* 不重做提示词系统架构。
* 不引入新依赖，除非调查证明现有能力无法满足。

## Technical Notes

* Created from user request on 2026-05-26.
* Prompt defaults 全量使用情况通过扫描 `PromptBuiltinDefaults.<dartName>` 引用确认。
* Agent Build 图节点通过解析 `agent_context_defaults.json` 的 `agents[].agentGraph.nodes` 与 `bindings` 确认。
* 手机端新增 `设置 → 提示词节点`，核对内置提示词、运行用途和 Agent Build 图覆盖情况。
* 已移除旧方案中的 `PromptRuntimeOverrides.storageKey` 默认节点本机覆盖能力。
* 手机端自定义节点保存在 `PromptCustomNodeStore.storageKey`，加载时同 ID 内置默认节点优先。
* 正式文档已补充手机端管理入口：`apps/aicove_flutter/docs/提示词默认值系统.md`。
