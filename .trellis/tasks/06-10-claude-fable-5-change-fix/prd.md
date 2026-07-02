# brainstorm: 修复 claude-fable-5 模型更改功能

## Goal

修复 `claude-fable-5` 在应用中被错误识别为语言合成模型的问题，并优先恢复模型“更改”功能的可用性。

## What I already know

* 用户反馈 `claude-fable-5` 被错误识别为语言合成模型。
* 用户强调更需要关注“更改功能失效”。
* 这类问题可能涉及模型类型判断、配置编辑入口、保存链路和运行时消费链路。
* 已定位：`fable` 被当作 TTS 音色关键字参与子串匹配，导致 `claude-fable-5` 被误判。
* 已定位：用户手动选择 `chat` 时，旧逻辑会删除显式配置；若模型名自动推断为非 `chat`，下一次读取会恢复错误推断。

## Assumptions (temporary)

* “更改功能”指应用内模型或供应商配置的编辑/修改动作。
* 错误的模型类型识别可能导致编辑入口、字段表单或保存分支走错。

## Open Questions

* 暂无阻塞问题；先从代码与文档中定位。

## Requirements (evolving)

* `claude-fable-5` 不应被归类为语言合成模型。
* 模型更改功能应能正常保存并被运行时读取。
* 修复范围优先聚焦现有链路，不引入新依赖。

## Acceptance Criteria (evolving)

* [x] 定位更改功能失效原因。
* [x] 修复 `claude-fable-5` 类型识别错误。
* [x] 修复更改功能失效。
* [x] 增加或更新必要测试。
* [x] 按项目要求完成 Flutter 验证。

## Definition of Done (team quality bar)

* Tests added/updated where appropriate.
* Lint/typecheck passes for touched area.
* Runtime verification completed or blocker recorded.
* Docs/spec updated only if behavior or convention changed.

## Out of Scope

* 不重做整套模型管理 UI。
* 不新增供应商或全局依赖。

## Technical Notes

* 根目录 `README.md` 已确认：Flutter 客户端在 `apps/aicove_flutter/`，Agent/Provider 链路需遵守 Interface 与项目宪法。
* 记忆提示：Agent Context/Prompt 默认值类问题需核对配置源、同步产物和运行时消费是否一致。
* 修复点：`apps/aicove_flutter/lib/src/features/settings/settings_models.dart`、`apps/aicove_flutter/lib/src/features/settings/app_settings.dart`。
* 验证：`flutter test test/features/settings/settings_models_test.dart`、`flutter test test/features/settings/app_settings_notifier_test.dart`、定向 `flutter analyze`、`flutter pub get`、`flutter run --no-resident`。
