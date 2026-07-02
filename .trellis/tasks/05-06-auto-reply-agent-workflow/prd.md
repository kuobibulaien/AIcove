# refactor: auto reply agent workflow

## Goal

重构主动回复 Agent 的提示词和默认 Agent 图：删除 `auto_reply.context.runtime_instruction`，把运行态输入和工具审核流程合并进 `auto_reply.analyzer.default`，让触发后的 analyzer 以 `{state_json}` 和 analyzer 默认提示词作为完整上下文完成一次工具驱动的主动回复决策。

## Requirements

* `auto_reply.context.runtime_instruction` 不再作为独立 prompt default、Dart 内置常量、Agent Build 节点或默认绑定存在。
* `auto_reply.analyzer.default` 包含 `{state_json}` 注入点、主动回复时间判断规则、工具预生成与确认入库流程。
* 主动回复 analyzer 触发后输入最近聊天、`state_json`、`auto_reply.analyzer.default` 和工具列表。
* 适合主动回复时，analyzer 先调用预生成工具，工具调用当前会话 chat 模型生成候选内容。
* analyzer 审核候选内容和发送时机；无误后调用确认入库工具，有误则重新调用预生成工具。
* 不适合主动回复或工具不可用时，仍能输出兼容 JSON 决策，避免调度链路中断。
* 云端 Agent Context Studio 的内置 `proactive_agent:default` 默认图只保留 analyzer 和回复生成节点，不再出现 runtime instruction 节点。
* 相关测试同步更新。

## Acceptance Criteria

* [ ] 全仓搜索不到正式代码和正式资产引用 `auto_reply.context.runtime_instruction`。
* [ ] `PromptBuiltinDefaults` 不再生成 `autoReplyContextRuntimeInstruction`。
* [ ] `ContextAnalyzer` 不再依赖独立 runtime instruction prompt，运行态 JSON 从 analyzer prompt 渲染进入系统提示词。
* [ ] `proactive_agent:default` 默认图、bindings、Flutter artifact、云端测试与 Flutter loader 测试均符合新结构。
* [ ] 主动回复工具流程仍保留预生成、审核、确认入库、重试预生成的行为约束。

## Definition of Done

* 更新 prompt defaults 与生成 Dart 文件。
* 更新云端内置 Agent 图生成与迁移逻辑。
* 更新 Flutter 侧 analyzer 调用链和相关测试。
* 运行聚焦测试；条件允许时运行 `flutter pub get` 和必要的分析/测试命令。
* 判断是否需要更新长期规范或正式文档。

## Technical Approach

按用户指定的唯一方案执行：删除独立 runtime instruction prompt，把 `{state_json}`、输出 JSON 兼容格式、工具预生成/审核/确认入库规则合并到 `auto_reply.analyzer.default`。Flutter 侧在触发 analyzer 前只渲染 analyzer prompt，不再向 `BackgroundAgentService.run` 传独立 extra instruction。云端默认图删除 runtime 节点和相关边，旧三节点系统图迁移为两节点图。

## Out of Scope

* 不重做主动回复 UI。
* 不改 chat 模型预生成工具的底层执行方式。
* 不引入新依赖。

## Technical Notes

* 根 README 项目宪法要求：改 Agent Runtime 先看 Agent 上下文总架构，改云端服务先看 `cloud_backend/README.md`。
* 已检查 `apps/aicove_flutter/docs/02_前后端分离与架构规范/Agent上下文管理总架构.md`：主动回复应归入统一 Agent Runtime，输入、能力、输出分离。
* 关键文件：`apps/aicove_flutter/assets/prompt_defaults.json`、`apps/aicove_flutter/lib/src/core/prompts/prompt_builtin_defaults.g.dart`、`apps/aicove_flutter/lib/src/features/auto_reply/data/context_analyzer.dart`、`cloud_backend/agent_context_admin_api.py`、`apps/aicove_flutter/assets/agent_context_defaults.json`。
