# fix: 多 Key 添加与用尽策略

## Goal

修复供应商多 Key 管理页添加 Key 时的红屏/溢出问题，并新增“用尽”负载策略：正常情况下持续使用当前 Key，只有当前 Key 被用尽、禁用或请求报错后才切到下一个可用 Key。

## Requirements

* 多 Key 管理页点击“添加”时，底部表单在键盘弹出和窄屏环境下不应发生布局溢出。
* 负载均衡策略增加“用尽”选项，并在 UI 文案中可见。
* “用尽”策略优先沿用当前索引 Key；当前 Key 不可用时切到下一个可用 Key。
* 当前 Key 请求报错后，记录失败状态与错误信息，使后续请求避开该 Key。
* 保持既有“轮询”“随机”策略兼容。

## Acceptance Criteria

* [x] 添加 Key 底部表单 widget 测试覆盖键盘 inset 场景。
* [x] 多 Key 支持测试覆盖“用尽”策略文案与配置保存。
* [x] 请求配置测试覆盖“用尽”策略在失败标记后切换 Key。
* [x] Flutter 目标测试通过。
* [x] 按项目宪法完成 Flutter 运行验证，若设备/环境阻塞则明确说明。

## Definition of Done

* Tests added/updated where behavior changes.
* Dart format applied to touched Dart files.
* No new dependency introduced.
* Docs/spec update considered; only长期有效约定才写入正式文档。

## Technical Approach

* 在 `provider_detail_support.dart` 统一新增策略常量与 label。
* 在 `multi_key_manager_page.dart` 中为添加 Key 表单提供更稳的弹窗高度约束，并加入“用尽”策略选项。
* 在聊天请求配置中保留当前 Key 索引，新增失败标记入口，报错后将当前 Key 标为 error 并推进索引。
* 尽量复用现有 `custom_config.multi_key_items` / `multi_key_rr_index` 字段，不改数据结构。

## Out of Scope

* 不新增供应商级配额检测 API。
* 不改变模型级 failover 的用户确认流程。
* 不重构整个 Provider 配置链路。

## Technical Notes

* 已读：根 `README.md`、Flutter 文档入口、公共组件总览、Trellis frontend specs。
* 相关文件：`multi_key_manager_page.dart`、`provider_detail_support.dart`、`provider_detail_actions.dart`、`chat_request_config.dart`、`chat_actions.dart`。
* 长期约定已更新到 `apps/aicove_flutter/docs/API架构说明.md`：`multi_key_strategy=exhaust` 的运行时语义。
