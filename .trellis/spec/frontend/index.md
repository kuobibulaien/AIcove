# AIcove Flutter Frontend Guidelines

Flutter 客户端位于 `apps/aicove_flutter/`。本目录只记录长期有效的前端开发规范，详细人类文档见 `apps/aicove_flutter/docs/README.md`。

## Guidelines Index

| Guide | Description | Status |
|---|---|---|
| [Directory Structure](./directory-structure.md) | Flutter 目录和分层边界 | Active |
| [Component Guidelines](./component-guidelines.md) | Moe UI 组件、主题 token、页面组合 | Active |
| [Hook Guidelines](./hook-guidelines.md) | Riverpod / provider 使用边界 | Active |
| [State Management](./state-management.md) | 本地状态、应用状态、聊天状态 | Active |
| [Quality Guidelines](./quality-guidelines.md) | 验证、禁止模式、回归风险 | Active |
| [Type Safety](./type-safety.md) | Dart 类型与数据模型约束 | Active |

## Pre-Development Checklist

1. 读根 `README.md` 和 `apps/aicove_flutter/docs/README.md`。
2. 涉及 UI 时读 `apps/aicove_flutter/docs/公共组件总览.md`。
3. 涉及聊天上下文时读 `apps/aicove_flutter/docs/02_前后端分离与架构规范/聊天请求上下文真相源与组装规范.md`。
4. 涉及 Agent 时读 `.trellis/spec/agent-context/index.md`。

## Quality Check

- 改完 Flutter 代码后运行 `flutter run --no-resident`。
- 页面改动要说明 900px 断点下的窄屏/宽屏适配。
- 新公共组件必须登记到 `公共组件总览.md`。

