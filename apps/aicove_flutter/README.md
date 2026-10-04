# AIcove Flutter 客户端

本目录是 Flutter 客户端源码，包含前端（`lib/src/ui/`）和本地后端（`lib/src/features/`、`lib/src/core/`）。以 macOS 为设计、开发与首轮验收基准，各端共用同一套窄屏／宽屏界面；正式规则见[全端共用界面架构与布局规范](docs/界面布局说明.md)。Web 平台已于 2026-09-13 移除。

## 环境准备

- Flutter SDK 由项目自带入口 `tool/flutterw` 管理（当前 3.44.6，位于 `~/dev-sdks/flutter-3.44.6`），**不要调用机器全局的 `flutter`**。版本与环境变量说明见 [tool/DIAGNOSTICS.md「项目 Flutter SDK」](tool/DIAGNOSTICS.md#项目-flutter-sdk2026-09-12)。
- macOS：Xcode 与 CocoaPods（项目已在 `pubspec.yaml` 关闭 Swift Package Manager 自动迁移）。
- Android：Android Studio + SDK + 平台工具，真机验收需 ADB 授权。

## 运行

```bash
cd apps/aicove_flutter
tool/flutterw pub get          # 只在依赖或 SDK 变化时需要
tool/flutterw run -d macos     # 人工试跑；终端按 r 热重载、R 热重启
tool/flutterw run -d <设备号>  # Android 真机
```

Agent 日常开发使用常驻调试会话与 Dart MCP，命令见 [DEVELOPMENT.md「快速开始」](../../DEVELOPMENT.md#快速开始macos)，规则见 [DEVELOPMENT.md 项目宪法第 7 条](../../DEVELOPMENT.md#项目宪法)。

## 目录

- `lib/main.dart`：启动入口；`lib/src/app.dart`：根组件与路由
- `lib/src/ui/`：前端（`features/` 按页面 · `shared/` 公共组件 · `theme/` tokens 与主题）
- `lib/src/features/`：本地后端，一个业务一个目录
- `lib/src/core/`：横切能力（供应商适配、数据库、网络、媒体、工具）
- `assets/`：静态资源与默认提示词 JSON
- `test/`、`integration_test/`、`test_contract/`：测试
- `tool/`：开发工具与说明（[DIAGNOSTICS.md](tool/DIAGNOSTICS.md)）
- `third_party/`：本地补丁依赖

完整目录树与分层解释见 [DEVELOPMENT.md「目录结构」](../../DEVELOPMENT.md#目录结构)。

## 文档索引

- [docs/README.md](./docs/README.md)：文档库总入口
- [界面布局说明.md](./docs/界面布局说明.md)：窄屏／宽屏布局规范
- [API架构说明.md](./docs/API架构说明.md)：聊天调用链与架构说明
- [音频播放器使用指南.md](./docs/04_功能模块规范/音频功能/音频播放器使用指南.md)
- [音频功能测试指南.md](./docs/04_功能模块规范/音频功能/音频功能测试指南.md)
