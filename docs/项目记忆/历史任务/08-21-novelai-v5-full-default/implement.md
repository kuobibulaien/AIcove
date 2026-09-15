# NovelAI V5 Full 默认生图模型：实施清单

## 实现

- [x] 读取前端质量/类型/目录规范和绘图功能文档。
- [x] 扩展 NovelAI 受控文生图模型目录，更新新安装默认值、`custom_config` 键名、
      API support 空模型默认值与可见顺序。
- [x] 调整 NovelAI normalize 保留受控优先级，不被通用字母排序破坏。
- [x] 增加一次性既有设置迁移：只升级缺失/历史内置默认，保护明确的 V3、Furry V3、
      V4、自定义模型以及密钥、地址和用户其他配置。
- [x] 增加 V5 模型族识别、`params_version = 4`、默认 scale 和结构化 prompt。
- [x] 确保 V5 `image_parameters` 不能覆盖核心字段或重新注入 V3 legacy 字段。
- [x] 移除 NovelAI 模型枚举错误后的跨模型静默重试。
- [x] 补充模型预览零请求、精确目录顺序、新安装持久化重载、迁移幂等/多渠道/配置保护、
      V5 Full/Curated 请求体、核心参数防覆盖、V5/V4.5/V3 无重试和 Furry V3 回归测试。
- [x] 更新 NovelAI 图片渠道适配文档。

## 验证

- [x] `flutter pub get`
- [x] `flutter test test/features/settings/provider_protocol_compat_test.dart`
- [x] `flutter test test/features/settings/app_settings_notifier_test.dart`
- [x] 与改动链路相关的其他窄测试
- [x] `flutter analyze`
- [x] `flutter run --no-resident`
- [x] 若可启动 UI，验证窄屏与宽屏设置页的模型展示；本次不改布局，至少确认无回归。
- [x] 完成 Codex 代码审查并修复确认的问题。

## 验证记录（2026-08-21）

- `flutter pub get` 成功；没有新增或升级依赖。
- NovelAI 定向协议与设置测试 71 项通过；审查后补充的设置测试单文件 37 项通过。
- 全量 `flutter test --timeout 60s` 639 项通过。
- 本次 5 个 Dart 文件定向 `flutter analyze` 为 0 问题；全仓 analyze 仍有 113 条
  既有 info/warning，均不指向本次文件。
- `flutter run --no-resident -d 3a845d3f` 在 Android 16 真机完成构建、安装与启动；
  macOS 目标因本机 `xcrun` 找不到 `xcodebuild`（exit 72）无法启动。
- 本次未改 UI 布局；全量 widget 测试包含设置页宽屏回归并通过。
- 独立 Codex 代码复核的 4 个 findings 已全部修复，复核无新增阻断/高风险问题。

## 风险点与回滚

- `agent_image_api_support.dart`：V5/V4/V3 分支错误会直接影响主要生图链路；依赖请求体
  测试后再运行应用。
- `ui_models_store_local_data_source.dart`：迁移必须一次性且不得破坏渠道密钥/地址；使用
  SharedPreferences mock 测试完整字段。
- 回滚使用保留 V5 识别的前向修复版本和新的补偿 migration id，将本次迁移产生的
  V5 Full 默认恢复为 V4.5 Full；不得直接发布不识别 V5 的旧代码。

## Review Gate

- 编码前：独立 Codex 方案审查。
- 编码后：独立 Codex 代码审查，逐项核实结论，不直接采信审查声明。
