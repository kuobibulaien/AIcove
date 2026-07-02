# fix: Flutter toolchain startup hang

## Goal

修复当前 Flutter 工具链启动卡死问题，让项目能重新稳定执行 Flutter 启动/验证命令。

## What I Already Know

* 用户报告：当前 Flutter 工具链启动卡死，需要修复。
* 项目是 Windows / PowerShell 7 环境，Flutter 客户端位于 `apps/aicove_flutter/`。
* 项目交付要求通常需要执行 `flutter run --no-resident` 验证，手机已连接。

## Assumptions (Temporary)

* “启动卡死”可能发生在 `flutter run`、`flutter doctor`、`flutter pub get`、Gradle/Android toolchain 初始化或项目自定义启动脚本阶段。
* 本任务优先定位本机项目/工具链可修复的问题；若卡死来自外部设备、SDK 损坏或网络不可达，会给出明确处置建议。

## Open Questions

* 暂无阻塞问题；先通过本地复现与日志排查收敛。

## Requirements (Evolving)

* 复现或定位 Flutter 工具链启动卡死发生在哪个阶段。
* 修复可由仓库配置、脚本、缓存或项目代码导致的启动卡死。
* 保持改动范围最小，不碰无关的既有未提交变更。
* 用户确认后，删除并重装本机 Flutter SDK。

## Acceptance Criteria (Evolving)

* [x] 明确卡死阶段与根因。
* [x] 完成必要修复或给出工具链级处置方案。
* [x] `flutter run --no-resident` 能启动并退出验证，或明确说明无法在当前环境完成验证的外部原因。

## Definition of Done

* Flutter 相关验证命令有结果。
* 若修改代码/配置，经过 lint/typecheck 或等效验证。
* 若形成可复用踩坑结论，更新 `.trellis/spec/` 或项目文档。

## Out of Scope

* 不进行大规模 Flutter 版本升级。
* 不重置/删除用户未确认的数据、SDK 或全局配置。
* 不提交或推送 git 变更，除非用户后续明确确认。

## Technical Notes

* 已读取根目录 `README.md`，确认 Flutter 客户端位置和交付检查要求。
* 旧 Flutter SDK 位于 `C:\Users\developer\develop\flutter`，`flutter --version` / `flutter devices` 在 30 秒内无输出超时；直接运行 `flutter_tools.dart` 也超时，说明卡点在 Flutter tool 启动层，而不是项目代码。
* 排查期间发现异常堆积的 `git.exe` / `cmd.exe` 进程，清理后仍不能恢复 Flutter tool。
* 用户确认高风险操作后，删除并重新克隆 Flutter stable SDK。
* 新 SDK 验证结果：Flutter `3.41.9` stable，Dart `3.11.5`；`flutter doctor -v` 通过，只有 `NO_PROXY` 未设置的代理提示。
* `flutter pub get` 通过；由于 SDK 升级，`apps/aicove_flutter/pubspec.lock` 中 5 个 SDK 相关传递依赖被解析到新版。
* `flutter run --no-resident -d e949b887` 在真机 `PKX110` 上通过，应用启动完成。
* 额外执行 `flutter analyze` 未通过，失败点是当前代码/测试中的既有分析器问题，不属于 Flutter toolchain 启动卡死：`time_awareness_plugin.dart` 缺少 `PromptBuiltinDefaults` getter，若干测试 helper 与当前 API 签名不一致。
