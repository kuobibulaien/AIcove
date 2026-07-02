# Flutter Component Guidelines

## UI 组件原则

- 优先复用 Moe 系列组件和 `shared/widgets/index.dart` 已导出的组件。
- 颜色使用 `tokens.dart`，不要在页面里散落硬编码色值。
- 提示信息使用 MoeToast，避免各页面自造 snackbar/toast。
- 公共组件重复使用 2 次以上就应抽取，并登记到 `apps/aicove_flutter/docs/公共组件总览.md`。

## 页面组合

- 页面保持薄，复杂业务逻辑下沉到 use case / service / provider。
- 宽屏/窄屏以 900px 为断点，页面改动必须同时考虑两端。
- 不新增与现有 Moe 风格冲突的控件体系。

## 禁止模式

- 在 UI widget 中直接拼接网络请求。
- 在页面中直接读写数据库。
- 新增公共组件但不登记文档。

