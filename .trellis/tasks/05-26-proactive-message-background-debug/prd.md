# 排查主动消息后台不运行

## Goal

排查并修复主动消息只在应用前台打开时运行、后台不运行的问题。

## What I already know

* 用户反馈：主动消息没有在后台运行，只有前台打开应用时才运作。
* 项目为 Flutter 应用，手机已连接，改完需按项目要求验证。

## Assumptions (temporary)

* 问题可能在 Flutter 后台任务、通知权限、定时任务注册、生命周期处理或平台配置链路中。
* 先定位现有实现，再决定是否需要代码改动。

## Open Questions

* 暂无阻塞问题。

## Requirements (evolving)

* 找到主动消息后台不运行的具体原因。
* 修复后台运行链路，尽量保持现有架构。
* 补充必要验证。

## Acceptance Criteria (evolving)

* [x] 能说明后台不运行的根因。
* [x] 代码修复后，前台逻辑不回退。
* [x] 按项目检查命令完成验证，或记录阻塞原因。

## Definition of Done

* Tests or runtime checks completed where appropriate.
* Lint / typecheck / run checks completed where feasible.
* Docs updated only if behavior or durable convention changes.

## Out of Scope

* 不重做主动消息产品设计。
* 不引入新的后台任务框架，除非现有实现无法支撑。

## Technical Notes

* 根因：前台轮询依赖 Dart Timer，应用进入后台后不可靠；部分触发器创建路径没有注册 WorkManager；后台任务通知失败会阻断消息写入。
* 修复：触发器创建、恢复、重试时注册后台任务；暂停、删除、完成、最终失败时取消任务；后台任务先写入 SQLite，再尝试通知。
* 修复：命中 `cachedContent` 的后台回复不再要求 API Key；无预生成内容且缺少模型配置时跳过并写历史记录。
* 修复：应用切后台时安排一次延迟主动分析，应用恢复或 scheduler 取消时清理该 timer。
* 验证：定向 Flutter 测试通过；定向 Dart analyze 通过；`flutter pub get` 通过；`flutter run --no-resident --disable-dds` 已在 PKX110 成功启动。
* 备注：全量 `flutter analyze` 仍有既有 info 级提示，本次改动文件定向分析无问题。
