# Flutter Directory Structure

## 根目录

Flutter 客户端主目录：`apps/aicove_flutter/`。

```text
lib/src/
  core/       # 核心层：API、数据库、工具、底层服务
  features/   # 业务层：domain / data / providers / application
  ui/         # UI 层：pages、shared widgets、theme
```

## 分层规则

- UI 层只依赖应用层 use case、provider 或公共 widget。
- 业务层放领域模型、repository、service、provider，不直接写页面逻辑。
- 核心层提供跨 feature 的基础设施。
- 新功能目录优先复用现有 feature 结构，避免把业务逻辑堆进 `ui/pages`。

## 命名与导入

- 页面文件使用 `*_page.dart`。
- Service 使用 `*Service`，Repository 使用 `*Repository`。
- UI 公共组件优先从 `lib/src/ui/shared/widgets/index.dart` 导入。
- 颜色、尺寸、字体优先走 `tokens.dart` 和现有主题系统。

