# 当前角色人设变量驱动主动回复

## Goal

让节点库显式提供“当前角色人设”变量，并让主动回复分析器在判断触发时机时能读取当前 chat 的角色人设，避免所有角色共用同一套触发判断语气与边界。

## What I already know

* 用户指出：节点库变量缺少当前角色的人设。
* 主动回复 agent 需要根据当前 chat 的人设来决定触发时机。
* 当前主动回复分析器模板只声明并渲染 `{state_json}`。
* `state_json` 是主动回复分析器现有运行态入口，当前会话人设应继续通过 `state_json.current_role_persona` 提供。
* 当前角色人设来源是 `Conversation.personaPrompt`，聊天主链路会通过 `PersonaPromptCodec.parse(...).userPrompt` 使用用户编辑的人设主体。
* 节点库变量来自 `apps/aicove_flutter/assets/prompt_defaults.json` 的 `variables` 列表；同步到 Agent Context 节点库时会进入 `prompt_defaults` 虚拟资产。
* 用户补充：本轮只写变量通道，提示词正文由用户后续补。

## Assumptions

* “当前角色的人设”指 `PersonaPromptCodec.parse(conversation.personaPrompt).userPrompt`，不包含同字段里编码的绘图提示扩展。
* 主动回复分析器读取人设即可，主动回复最终生成仍继续由当前聊天请求链路负责保持角色口吻。
* 变量名采用 `current_role_persona`，语义比 `persona` 更明确。

## Requirements

* 节点库变量列表新增 `current_role_persona`。
* `auto_reply.analyzer.default` 声明变量 `current_role_persona`。
* Flutter 运行态继续通过 `state_json.current_role_persona` 提供短版本人设。
* 不改 `auto_reply.analyzer.default` 的提示词正文。

## Acceptance Criteria

* [ ] Prompt 默认资产中能看到变量 `current_role_persona`。
* [ ] `auto_reply.analyzer.default` 的变量列表包含 `current_role_persona`。
* [ ] `state_json.current_role_persona` 包含当前会话的人设文本。
* [ ] 人设为空时不影响主动回复分析器运行。
* [ ] 后端 Agent Context artifact 同步测试覆盖新变量。
* [ ] Flutter defaults loader 测试覆盖新变量。

## Definition of Done

* Tests added/updated where appropriate.
* Backend Python tests pass for Agent Context defaults.
* Flutter analyzer / targeted tests pass as feasible.
* Docs/spec update judgment completed.

## Technical Approach

更新 prompt 默认源数据，把 `current_role_persona` 作为节点库变量；主动回复分析器继续通过 `state_json.current_role_persona` 读取当前会话人设。提示词正文由用户后续编辑。

## Out of Scope

* 不改联系人编辑页的人设存储结构。
* 不改主动回复最终发送流程。
* 不做新的 UI 页面。
* 不引入新依赖。

## Technical Notes

* Relevant files inspected:
  * `apps/aicove_flutter/lib/src/features/auto_reply/data/context_analyzer.dart`
  * `apps/aicove_flutter/lib/src/features/settings/settings_models.dart`
  * `apps/aicove_flutter/assets/prompt_defaults.json`
  * `apps/aicove_flutter/lib/src/core/prompts/prompt_builtin_defaults.g.dart`
  * `cloud_backend/agent_context_admin_api.py`
  * `cloud_backend/tests/test_agent_context_admin_api.py`
  * `apps/aicove_flutter/test/features/agent_context/data/agent_context_defaults_loader_test.dart`
* Prompt defaults source of truth appears to be `apps/aicove_flutter/assets/prompt_defaults.json`, with generated Dart constants in `prompt_builtin_defaults.g.dart`.
