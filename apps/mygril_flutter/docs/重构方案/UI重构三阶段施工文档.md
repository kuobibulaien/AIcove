# UI重构三阶段施工文档

> 创建日期：2025-12-31
> 状态：施工中 🚧
> 预计工时：8-12 小时

---

## 📋 总体目标

**三阶段的核心任务是「整理」和「统一」**：

1. **创建公共组件库** - 按钮、输入框、列表等常用组件统一封装
2. **拆分大文件** - 将超过 500 行的文件按服务/功能拆分
3. **推广组件使用** - 替换现有硬编码样式为公共组件
4. **清理代码** - 删除无用代码、统一代码风格

---

## 📁 第一部分：公共组件创建

### 1.1 已完成组件 ✅

| 组件 | 文件路径 | 用途 | 状态 |
|------|----------|------|------|
| `MoePrimaryButton` | `ui/shared/widgets/buttons/moe_primary_button.dart` | 主按钮 | ✅ 完成 |
| `MoeSecondaryButton` | `ui/shared/widgets/buttons/moe_secondary_button.dart` | 次级按钮 | ✅ 完成 |
| `MoeIconButton` | `ui/shared/widgets/buttons/moe_icon_button.dart` | 图标按钮 | ✅ 完成 |
| `MoeTileButton` | `ui/shared/widgets/buttons/moe_tile_button.dart` | 功能入口按钮 | ✅ 完成 |
| `MoeTextField` | `ui/shared/widgets/form/moe_text_field.dart` | 输入框 | ✅ 完成 |
| `MoeSwitch` | `ui/shared/widgets/form/moe_switch.dart` | 开关 | ✅ 完成 |
| `MoeCheckbox` | `ui/shared/widgets/form/moe_checkbox.dart` | 复选框 | ✅ 完成 |
| `MoeSettingsGroup` | `ui/shared/widgets/list/moe_settings_group.dart` | 设置分组卡片 | ✅ 完成 |
| `MoeSettingsRow` | `ui/shared/widgets/list/moe_settings_row.dart` | 设置行 | ✅ 完成 |
| `MoeListTile` | `ui/shared/widgets/list/moe_list_tile.dart` | 通用列表项 | ✅ 完成 |
| `MoeLoadingIndicator` | `ui/shared/widgets/feedback/moe_loading_indicator.dart` | 加载指示器 | ✅ 完成 |
| `MoeEmptyState` | `ui/shared/widgets/feedback/moe_empty_state.dart` | 空状态占位 | ✅ 完成 |
| Design Tokens | `ui/theme/tokens.dart` | 动画、间距、圆角、阴影 | ✅ 完成 |

### 1.2 公共组件创建已全部完成 ✅

所有规划的公共组件已创建完毕，包括：
- **按钮类**：主按钮、次级按钮、图标按钮、功能入口按钮
- **表单类**：输入框、开关、复选框
- **列表类**：设置分组、设置行、通用列表项
- **反馈类**：加载指示器、空状态占位

### 1.3 组件设计规范

#### 样式接口标准

所有公共组件必须支持以下样式覆盖参数：

```dart
// 颜色相关
final Color? backgroundColor;
final Color? foregroundColor;
final Color? pressedBackgroundColor;
final Color? disabledBackgroundColor;

// 装饰相关
final BoxDecoration? decoration;      // 完整装饰（最高优先级）
final BorderRadius? borderRadius;     // 圆角
final BorderSide? border;             // 边框
final List<BoxShadow>? boxShadow;     // 阴影
```

#### 主题集成标准

```dart
@override
Widget build(BuildContext context) {
  final colors = context.moeColors;   // 获取主题颜色
  final skin = context.skin;          // 获取皮肤配置（可选）
  
  // 优先使用传入值，否则使用主题默认值
  final bgColor = widget.backgroundColor ?? colors.dialogWarning;
  // ...
}
```

---

## 📁 第二部分：大文件拆分

### 2.1 超 500 行文件清单

| 文件 | 行数 | 职责 | 拆分方案 |
|------|------|------|----------|
| `chat_actions.dart` | **1690** | 聊天操作 | 🔴 优先拆分 |
| `composer.dart` | **758** | 消息输入 | 🔴 优先拆分 |
| `chat_page.dart` | **547** | 聊天页面 | 🟡 可拆分 |
| `message_bubble.dart` | 495 | 消息气泡 | 🟢 暂不拆 |

### 2.2 `chat_actions.dart` 拆分方案（1690行 → 5个文件）

**原则**：按服务/功能分组，而非按页面分组

#### 拆分清单

| 新文件 | 包含内容 | 预计行数 |
|--------|----------|----------|
| `chat_actions.dart` | 主入口 + Provider 定义 + 公共状态 | ~100 |
| `services/chat_send_service.dart` | `send()` + `sendWithImage()` 逻辑 | ~400 |
| `services/chat_retry_service.dart` | `retry()` 逻辑 | ~300 |
| `services/chat_trigger_service.dart` | `sendProactiveTrigger()` + 分析器 | ~250 |
| `services/chat_tts_service.dart` | TTS 相关处理 | ~200 |
| `services/chat_message_builder.dart` | 消息构建辅助方法 | ~200 |

#### 拆分后目录结构

```
features/chat/
├── chat_actions.dart              # 主入口（精简版）
├── services/                      # 🆕 服务层
│   ├── chat_send_service.dart
│   ├── chat_retry_service.dart
│   ├── chat_trigger_service.dart
│   ├── chat_tts_service.dart
│   └── chat_message_builder.dart
├── data/                          # 已有数据层
├── domain/                        # 已有领域层
└── ...
```

### 2.3 `composer.dart` 拆分方案（758行 → 3个文件）

| 新文件 | 包含内容 | 预计行数 |
|--------|----------|----------|
| `composer.dart` | 主组件 | ~400 |
| `composer_actions_menu.dart` | `_ActionsMenuContent` + `_ActionButton` | ~150 |
| `composer_model_selector.dart` | `_ModelSelectorSheet` | ~150 |

#### 拆分后目录结构

```
features/chat/presentation/widgets/
├── composer/                      # 🆕 独立目录
│   ├── composer.dart              # 主组件
│   ├── composer_actions_menu.dart # 功能菜单
│   └── composer_model_selector.dart # 模型选择器
├── message_bubble.dart
└── ...
```

### 2.4 `chat_page.dart` 拆分方案（547行 → 3个文件）

| 新文件 | 包含内容 | 预计行数 |
|--------|----------|----------|
| `chat_page.dart` | 主页面 | ~200 |
| `message_list.dart` | `_MessageList` + 时间分隔器 | ~200 |
| `animated_message_item.dart` | `_AnimatedMessageItem` | ~100 |

---

## 📁 第三部分：组件替换计划

### 3.1 弹窗按钮替换

**目标**：将所有弹窗中的硬编码按钮替换为 `MoePrimaryButton` / `MoeSecondaryButton`

| 文件 | 当前实现 | 替换为 |
|------|----------|--------|
| `meotalk_dialog.dart` | 已有公共组件 | 内部使用新按钮 |
| `chat_settings_dialog.dart` | 手动 ElevatedButton | 公共组件 |
| `contact_edit_dialog.dart` | 手动 ElevatedButton | 公共组件 |
| `momotalk_sort_dialog.dart` | 手动 TextButton | 公共组件 |
| `image_crop_dialog.dart` | 手动 ElevatedButton | 公共组件 |

### 3.2 输入框替换

**目标**：将所有 TextField 替换为 `MoeTextField`

| 文件 | 当前实现 | 状态 |
|------|----------|------|
| `contact_edit_page.dart` | 手动 TextField | 待替换 |
| `auto_reply_trigger_form.dart` | 手动 TextField | 待替换 |
| `provider_selector_page.dart` | 手动 TextField | 待替换 |

### 3.3 设置页列表替换

**目标**：将设置页的 ListTile 替换为 `MoeSettingsRow`

| 文件 | 当前实现 | 状态 |
|------|----------|------|
| `settings_page.dart` | 手动 `_buildSettingItem` | 待替换 |
| `ui_settings_page.dart` | 手动 ListTile | 待替换 |
| `message_format_settings_page.dart` | 手动 ListTile | 待替换 |
| `tts_plugin_detail_page.dart` | 手动 ListTile | 待替换 |

### 3.4 开关替换

**目标**：将所有 Switch 替换为 `MoeSwitch`

| 文件 | 当前实现 | 状态 |
|------|----------|------|
| `ui_settings_page.dart` | 原生 Switch | 待替换 |
| `auto_reply_settings_page.dart` | 原生 Switch | 待替换 |
| `message_format_settings_page.dart` | 原生 Switch | 待替换 |

---

## 📅 施工时间表

### 阶段 3.1：公共组件完善 ✅（已完成）

- [x] 创建 `MoeSettingsGroup` 组件
- [x] 创建 `MoeSettingsRow` 组件
- [x] 创建 `MoeListTile` 组件
- [x] 创建 `MoeCheckbox` 组件
- [x] 创建 `MoeTileButton` 组件
- [x] 创建 `MoeLoadingIndicator` 组件
- [x] 创建 `MoeEmptyState` 组件
- [x] 更新 `index.dart` 导出文件

### 阶段 3.2：大文件拆分（已完成 ✅）

- [x] `chat_actions.dart` 初步重构（1690行 → 保持，提取辅助类）
  - [x] 创建 `services/` 目录
  - [x] 提取 `chat_message_builder.dart` - 消息构建逻辑
  - [x] 提取 `chat_request_config.dart` - 请求配置构建
  - [x] 提取 `chat_types.dart` - 公共数据类型
- [x] 拆分 `composer.dart`（758行 → 519行）
  - [x] 创建 `composer/` 目录
  - [x] 提取 `composer_actions_menu.dart` - 功能菜单
  - [x] 提取 `model_selector_sheet.dart` - 模型选择器
  - [x] 验证编译通过
- [x] 拆分 `chat_page.dart`（547行 → 204行）
  - [x] 创建 `widgets/` 目录
  - [x] 提取 `chat_message_list.dart` - 消息列表组件
  - [x] 提取 `animated_message_item.dart` - 消息动画
  - [x] 验证编译通过
- [x] 拆分 `app_settings.dart`（836行 → 398行）
  - [x] 提取 `settings_models.dart` - 数据模型类（462行）
  - [x] 使用 export 保持向后兼容
  - [x] 验证编译通过

**备注**：`chat_actions.dart` 由于内部状态紧密耦合，采用渐进式重构策略：先提取可复用的工具类，保持主类不变。

### 阶段 3.3：组件替换（预计 3 小时）

- [ ] 替换弹窗按钮
- [ ] 替换输入框
- [ ] 替换设置页列表（创建组件后）
- [ ] 替换开关

### 阶段 3.4：清理与文档（预计 1 小时）

- [ ] 删除无用代码/文件
- [ ] 统一代码格式
- [ ] 更新 README
- [ ] 编写交付报告

---

## ⚠️ 注意事项

### 拆分原则

1. **保持 API 稳定**：拆分后的外部调用方式不变
2. **按服务分组**：一个服务文件只做一件事
3. **避免循环依赖**：注意 import 方向
4. **先拆后测**：每次拆分后都要 `flutter analyze` + `flutter run`

### 替换原则

1. **渐进替换**：一个页面一个页面替换，不要一次性改太多
2. **保持功能**：替换前后功能完全一致
3. **验证 UI**：每次替换后检查视觉效果

### 文件命名规范

```
公共组件：moe_xxx.dart（如 moe_button.dart）
服务文件：xxx_service.dart（如 chat_send_service.dart）
页面文件：xxx_page.dart
组件文件：xxx.dart 或 xxx_widget.dart
```

---

## 📊 进度追踪

| 任务 | 状态 | 完成日期 | 备注 |
|------|------|----------|------|
| Design Tokens 补充 | ✅ | 2025-12-31 | 动画、间距、圆角、阴影 |
| MoePrimaryButton | ✅ | 2025-12-31 | 主按钮 |
| MoeSecondaryButton | ✅ | 2025-12-31 | 次级按钮 |
| MoeIconButton | ✅ | 2025-12-31 | 图标按钮 |
| MoeTileButton | ✅ | 2025-12-31 | 功能入口按钮 |
| MoeTextField | ✅ | 2025-12-31 | 输入框 |
| MoeSwitch | ✅ | 2025-12-31 | 开关 |
| MoeCheckbox | ✅ | 2025-12-31 | 复选框 |
| MoeSettingsGroup | ✅ | 2025-12-31 | 设置分组卡片 |
| MoeSettingsRow | ✅ | 2025-12-31 | 设置行 |
| MoeListTile | ✅ | 2025-12-31 | 通用列表项 |
| MoeLoadingIndicator | ✅ | 2025-12-31 | 加载指示器 |
| MoeEmptyState | ✅ | 2025-12-31 | 空状态占位 |
| chat_actions.dart 拆分 | ⏳ | - | 待开发 |
| composer.dart 拆分 | ⏳ | - | 待开发 |
| 组件替换 | ⏳ | - | 待开发 |

---

## 📖 附录

### A. 现有公共组件清单

```
ui/shared/
├── widgets/
│   ├── buttons/
│   │   ├── moe_primary_button.dart     # 主按钮
│   │   ├── moe_secondary_button.dart   # 次级按钮
│   │   ├── moe_icon_button.dart        # 图标按钮
│   │   └── moe_tile_button.dart        # 🆕 功能入口按钮
│   ├── form/
│   │   ├── moe_text_field.dart         # 输入框
│   │   ├── moe_switch.dart             # 开关
│   │   └── moe_checkbox.dart           # 🆕 复选框
│   ├── list/                           # 🆕 列表组件
│   │   ├── moe_settings_group.dart     # 设置分组卡片
│   │   ├── moe_settings_row.dart       # 设置行
│   │   └── moe_list_tile.dart          # 通用列表项
│   ├── feedback/                       # 🆕 反馈组件
│   │   ├── moe_loading_indicator.dart  # 加载指示器
│   │   └── moe_empty_state.dart        # 空状态占位
│   ├── index.dart                      # 统一导出
│   ├── moe_app_bar.dart                # AppBar
│   ├── moe_toast.dart                  # Toast 提示
│   ├── meotalk_dialog.dart             # 弹窗
│   ├── image_crop_dialog.dart          # 图片裁剪
│   ├── settings_drawer_panel.dart      # 设置抽屉
│   └── settings_drawer_wrapper.dart    # 抽屉包装器
├── effects/
│   ├── frosted_glass_card.dart         # 毛玻璃卡片
│   ├── gradient_blur_card.dart         # 渐变模糊卡片
│   ├── smooth_clip.dart                # 平滑裁剪
│   └── role_background_hero.dart       # 角色背景 Hero
└── animations/
    ├── expanding_page_route.dart       # 展开页面路由
    └── parallax_slide_page_route.dart  # 视差滑动路由
```

### B. 大文件拆分后的 import 示例

拆分后，`chat_actions.dart` 变成入口文件：

```dart
// chat_actions.dart（精简版）
export 'services/chat_send_service.dart';
export 'services/chat_retry_service.dart';
export 'services/chat_trigger_service.dart';

// Provider 定义
final chatActionsProvider = Provider((ref) => ChatActions(ref));
final sendingProvider = StateProvider<bool>((ref) => false);
// ...

// ChatActions 类只保留核心方法声明，内部委托给各服务
class ChatActions {
  final Ref ref;
  late final ChatSendService _sendService;
  late final ChatRetryService _retryService;
  
  ChatActions(this.ref) {
    _sendService = ChatSendService(ref);
    _retryService = ChatRetryService(ref);
  }
  
  Future<void> send(String text) => _sendService.send(text);
  Future<void> retry(String messageId) => _retryService.retry(messageId);
  // ...
}
```

---

*本文档将随着施工进度持续更新。最后更新：2025-12-31*
