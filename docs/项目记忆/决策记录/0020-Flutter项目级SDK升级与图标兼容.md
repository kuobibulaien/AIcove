---
status: accepted
date: 2026-09-12
---

# Flutter 项目级 SDK 升级与图标兼容

## 背景

用户明确要求升级 SDK，并授权测试及修复升级暴露的问题。本机默认 Flutter 3.35.6，另已安装 stable 3.44.6。玻璃库讨论不等于授权本批引入玻璃库或替换 UI 架构。

## 决定

1. AIcove 切换到已安装的 Flutter 3.44.6 / Dart 3.12.2，保留旧 SDK 与机器全局 PATH。项目命令统一经 `tool/flutterw`；版本约束、使用与并发规则见 [DIAGNOSTICS.md](../../../apps/aicove_flutter/tool/DIAGNOSTICS.md#项目-flutter-sdk2026-09-12)。不宣称这是官方最新版本。
2. SDK 升级不同时迁移 CocoaPods 到 Swift Package Manager；项目显式关闭自动迁移，不修改全局配置。只接受 SDK 必需的传递依赖解析变化，不批量升级业务依赖。
3. 上游 `lucide_icons 0.257.0` 继承 `IconData`，不兼容 Flutter 3.44 的 final 限制。采用带 ISC 许可证的最小本地兼容副本：直接构造常量 `IconData`，不修改字体、码点、图标名及现有 import。未选择迁移新版社区图标包，以免把图标替换混入 SDK 升级；也不修改共享 pub 缓存。详情见 [兼容副本](../../../apps/aicove_flutter/third_party/lucide_icons/README.md)。
4. 新 SDK 对 `ListTile` 检测出底部弹窗背景遮挡 ink 绘制层：在公共 `MoeBottomSheet` 的裁剪内部加入透明 Material，不屏蔽断言；对 `ReorderableListView.onReorder` 的可空类型变化，仅修复测试中的调用检查。

## 代价与回滚

- 需维护一份原始图标常量与字体。上游有兼容版时可切回 hosted 依赖，但必须核对名称、码点、字体与实际外观。
- 回滚只恢复本次 SDK 指向、依赖配置、锁文件与兼容补丁；恢复前核对并发修改。旧 SDK 目录保留，不使用 git reset 或覆盖整个工作树。
- 本次原始配置备份、两版本独立源码副本与日志保存在 `scratch/sdk-upgrade-3.44.6/`（本机资料，不入库）。

## 验收门与范围

同一份源码分别在两版 SDK 运行全量测试，对比失败集合；新增失败需复现后修复，不将历史测试债务误报为 SDK 回归。编译 Mac 与 Android 标准入口；对图标、原生模糊及底部弹窗执行 Mac 原生 420／1000 宽度、浅深主题离线渲染。实际结果及平台缺口见需求日志和本机 `scratch/sdk-upgrade-3.44.6/verification.md`。

SDK 与本地构建切换不等于替换 `/Applications/AIcove.app` 或安装手机版本；本批不操作用户数据、不发生产请求，不宣称全端全部功能通过。
