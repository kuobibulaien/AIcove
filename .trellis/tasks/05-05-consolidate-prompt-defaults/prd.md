# Refactor: Consolidate Prompt Defaults

## Goal

重整 `prompt_defaults.json` 中过度碎片化的默认提示词，让 Prompt Studio 主要展示真正需要独立维护的提示词大块；装配过程里的短格式片段、字段说明、小标题等不再拆成一堆顶层 prompt 卡片。用户特别指出时间感知应收敛为两条：一条 system 说明，一条插在最后一条 user 前的时间提醒。

## What I Already Know

* 当前默认提示词真相源是 `apps/aicove_flutter/assets/prompt_defaults.json`，生成文件是 `apps/aicove_flutter/lib/src/core/prompts/prompt_builtin_defaults.g.dart`。
* `time_awareness` 现在被拆成 7 条 prompt：当前时间默认/兜底、上一条用户消息、结尾提示、三条字段说明。
* 代码消费点集中在 `TimeAwarenessPlugin.buildSystemReminderPayload()`、`TimeAwarenessPlugin.buildSystemReminderFieldGuide()` 和 `SystemReminderService.buildReminderSemanticsPrompt()`。
* Prompt Studio 会直接展示所有 `prompts[]`，因此短格式片段会变成独立卡片，造成用户看到的“提示词拆太碎”。
* 其他类似碎片包括：`memory.role_scoped.*` 的小标题块、`memory.profile_prompt.line`、`memory.l2_skill_*` 格式行、`memory.merge.fallback`、`chat.draw_image.stable_review_prefix` 等。
* 不适合随便合并的项包括：图片工具 schema 各字段描述，它们运行时分别进入 tool/parameter description；强行合并会破坏工具 schema 的独立字段语义。

## Requirements

* 将时间感知默认提示词收敛为两条可编辑 prompt：
  * system 侧说明：解释 `<system-reminder>`、当前时间模板、上一条用户消息时间、历史消息时间戳等规则。
  * reminder 侧模板：生成插在最后一条 user 前的时间提醒，包含当前时间、可选上一条用户消息时间、让模型自行判断时序关系。
* 将纯格式化/小标题/回退行类碎片从 `prompts[]` 收口，改为代码内格式化或合并进更大的 prompt。
* 保留真正有独立运行时语义、独立编辑价值或 schema 字段约束的 prompt。
* 在前端管理面板中，对未使用或几乎作废的提示词节点卡片增加阴影遮罩/弱化态，提示维护者它们不应作为主要维护对象。
  * 识别优先基于已有元信息：`id` / `title` / `description` 中出现 legacy、遗留、较早版本、旧版、废弃、作废、未使用等语义。
  * 遮罩只影响展示，不改变 JSON 数据结构、不影响编辑/保存、不改变运行时提示词装配。
  * 覆盖范围至少包括 Node Studio 的 prompt 卡片；若 Agent Build 画布引用了这些 prompt，也应让对应节点呈现同类弱化状态。
* 同步更新 Dart 生成文件和相关测试。
* 不改变模型实际接收的核心语义，只减少维护面和 Prompt Studio 卡片数量。

## Acceptance Criteria

* [x] `time_awareness` 在 Prompt Studio 中只剩两条 prompt。
* [x] 其他明显格式片段不再作为独立 prompt 卡片出现。
* [x] 相关代码不再引用被移除的 `PromptBuiltinDefaults.*` 常量。
* [x] 未使用/近废弃 prompt 在前端节点卡片上有清晰阴影遮罩或弱化态，且不阻断点击查看详情。
* [x] 时间感知测试覆盖当前时间、上一条用户消息时间、关闭当前时间注入、字段说明语义。
* [x] `prompt_defaults_codegen.py` 可成功生成 Dart 默认值。
* [x] Flutter 相关测试/分析按项目质量门槛执行。

## Technical Approach

1. 先按“实际 prompt 大块 vs 装配格式片段”分类现有 `prompts[]`。
2. 合并时间感知：新增 `time_awareness.system.default` 与 `time_awareness.reminder.default`，移除旧 7 条。
3. 收口记忆等小格式片段：把纯标题/行模板搬回对应 Dart 组装函数里的本地格式化，保留总结、合并、重新丰富等真实模型任务 prompt。
4. 重跑 codegen，改消费方常量引用，更新测试。

## Out of Scope

* 不重做 Prompt Studio UI。
* 不改 Agent Context 架构。
* 不改变图片工具 schema 的字段结构。
* 不处理用户本地已有自定义覆盖数据迁移。

## Technical Notes

* 已读 `README.md` 项目宪法。
* 已读 `apps/aicove_flutter/docs/提示词默认值系统.md`。
* 已读 `apps/aicove_flutter/docs/04_功能模块规范/提示词装配链路.md`。
* 相关代码：
  * `apps/aicove_flutter/lib/src/features/plugins/time_awareness/time_awareness_plugin.dart`
  * `apps/aicove_flutter/lib/src/core/services/system_reminder_service.dart`
  * `apps/aicove_flutter/lib/src/core/services/prompt_tag_semantics_service.dart`
  * `apps/aicove_flutter/lib/src/features/plugins/memory/memory_plugin.dart`
  * `apps/aicove_flutter/lib/src/features/plugins/image/image_config.dart`
