# 代码风格与约定

## 代码风格
- 使用 `flutter_lints` 包提供的推荐 lint 规则
- 遵循 Dart 官方代码风格指南

## 命名约定
- **类名**: PascalCase (例如: `Composer`, `MessageBubble`)
- **变量/函数**: camelCase (例如: `onSend`, `selectedImagePath`)
- **常量**: camelCase（例如: `moePrimary`）或全大写下划线分隔（例如: `_IDLE_SECONDS`）
- **私有成员**: 以下划线开头 (例如: `_ctrl`, `_submit()`)

## 文件组织
- 使用分层架构：`lib/src/features/<feature>/{data, domain, presentation}`
- 每个功能模块独立，包含自己的数据层、领域层和展示层
- 通用代码放在 `lib/src/core/` 目录

## 状态管理
- 使用 Riverpod 进行状态管理
- Provider 定义通常放在独立的文件中（如 `providers2.dart`, `plugin_providers.dart`）
- Widget 继承 `ConsumerWidget` 或 `ConsumerStatefulWidget`

## 组件设计
- 优先使用 StatelessWidget，需要状态时使用 StatefulWidget
- 将复杂 Widget 拆分为小组件
- 使用私有子组件类（以下划线开头）组织相关 UI

## 注释
- 使用 `///` 为公共 API 提供文档注释
- 使用 `//` 为实现细节提供说明性注释
- 中文注释和文档都可以接受

## 资源管理
- 图片等资源放在 `assets/` 目录
- 在 `pubspec.yaml` 中声明资源路径
- 使用有意义的资源文件名

## 错误处理
- 使用 try-catch 捕获异常
- 向用户显示友好的错误提示（使用 SnackBar）
- 在控制台记录详细错误信息用于调试

## 响应式设计
- 支持窄屏（移动端）和宽屏（桌面端）布局
- 使用 `MediaQuery` 获取屏幕信息
- 使用 `LayoutBuilder` 根据可用空间调整布局