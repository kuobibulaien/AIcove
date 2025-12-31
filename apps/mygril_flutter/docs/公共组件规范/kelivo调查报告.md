# Kelivo 项目公共资源调查报告

> 调查日期：2025-12-28
> 参考项目路径：`C:\ide\mygril\参考素材\kelivo-master`

---

## 📊 项目概览

Kelivo 是一个成熟的 Flutter AI 聊天应用，其公共组件设计遵循 **iOS 风格**，具有完善的主题系统和高度复用的 UI 组件库。

### 项目结构

```
lib/
├── core/           # 核心服务（数据模型、Provider、服务）
├── shared/         # 共享资源（组件、动画、响应式）
│   ├── widgets/    # ⭐ 公共组件库
│   ├── animations/ # 动画工具
│   ├── pages/      # 公共页面
│   └── responsive/ # 响应式布局
├── theme/          # 🎨 主题系统
│   ├── design_tokens.dart
│   ├── palettes.dart
│   ├── theme_factory.dart
│   └── theme_provider.dart
├── utils/          # 工具函数
├── features/       # 功能模块
└── main.dart
```

---

## 🎨 主题系统

### 1. Design Tokens（设计令牌）

📄 `lib/theme/design_tokens.dart`

```dart
// 颜色
class AppColors {
  static const Color textMuted = Colors.black54;
}

// 阴影
class AppShadows {
  static List<BoxShadow> soft = [...];
}

// 圆角
class AppRadii {
  static const double capsule = 28;
}

// 间距
class AppSpacing {
  static const double xxs = 4;
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 20;
}
```

**特点：**
- 使用静态常量定义，性能好
- 语义化命名（xxs, xs, sm, md, lg）
- 分类清晰（颜色、阴影、圆角、间距）

### 2. 调色板系统

📄 `lib/theme/palettes.dart` (22KB)

- 支持多套调色板
- 支持 Material You 动态取色（Dynamic Color）
- 完整的亮/暗模式定义

### 3. 主题工厂

📄 `lib/theme/theme_factory.dart`

**核心函数：**
```dart
ThemeData buildLightTheme(ColorScheme? dynamicScheme)
ThemeData buildDarkTheme(ColorScheme? dynamicScheme)
ThemeData buildLightThemeForScheme(ColorScheme staticScheme, {...})
ThemeData buildDarkThemeForScheme(ColorScheme staticScheme, {...})
```

**关键特性：**
- 平台字体回退处理（iOS、Android、Windows 分别处理）
- SnackBar 自定义主题
- AppBar 透明/无阴影设计
- 完整的 ColorScheme 支持

---

## 🧩 公共组件库

### 1. 按钮组件

#### IosTileButton（瓷砖按钮）
📄 `lib/shared/widgets/ios_tile_button.dart`

```dart
IosTileButton(
  label: '按钮文字',
  icon: Icons.add,
  onTap: () {},
  enabled: true,
  backgroundColor: Colors.blue,
  foregroundColor: null,
  borderColor: null,
)
```

**特点：**
- iOS 风格无水波纹效果
- 按压时颜色渐变（AnimatedContainer）
- 自动适配亮/暗模式
- 支持禁用状态

#### IosIconButton（图标按钮）
📄 `lib/shared/widgets/ios_tactile.dart`

```dart
IosIconButton(
  icon: Icons.arrow_back,
  onTap: () {},
  size: 20,
  padding: EdgeInsets.all(6),
  color: null,
  pressedColor: null,
  minSize: 44,  // 最小点击区域
  semanticLabel: '返回',
  enabled: true,
)
```

**特点：**
- 无水波纹，颜色渐变过渡
- 支持 Hover 状态（桌面端）
- 微妙的背景色变化
- 支持自定义 Builder

---

### 2. 开关与勾选框

#### IosSwitch（开关）
📄 `lib/shared/widgets/ios_switch.dart`

```dart
IosSwitch(
  value: true,
  onChanged: (v) {},
  width: 44,
  height: 26,
  activeColor: null,    // 开启时轨道颜色
  inactiveColor: null,  // 关闭时轨道颜色
  thumbColor: null,     // 滑块颜色
  enableHaptics: true,
  semanticLabel: '开关',
)
```

**特点：**
- 仿 iOS 原生开关外观
- 按压时轻微缩放
- 触觉反馈支持
- AnimatedAlign + AnimatedContainer 实现流畅动画

#### IosCheckbox（复选框）
📄 `lib/shared/widgets/ios_checkbox.dart`

```dart
IosCheckbox(
  value: false,
  onChanged: (v) {},
  size: 22,
  hitTestSize: 32,  // 点击区域扩大
  activeColor: null,
  borderColor: null,
  checkmarkColor: CupertinoColors.white,
  enableHaptics: true,
)
```

**特点：**
- 圆形复选框（iOS 风格）
- 勾选动画使用 CustomPaint 绘制
- TweenAnimationBuilder 实现弹性动画

---

### 3. 卡片与容器

#### IosCardPress（可按压卡片）
📄 `lib/shared/widgets/ios_tactile.dart`

```dart
IosCardPress(
  child: ...,
  onTap: () {},
  onLongPress: () {},
  borderRadius: BorderRadius.circular(12),
  baseColor: null,
  pressedBlendStrength: 0.12,  // 按压时颜色混合强度
  pressedScale: 0.98,          // 按压时缩放
  duration: Duration(milliseconds: 200),
  haptics: true,
)
```

**特点：**
- 无水波纹，背景色渐变
- 可选的缩放效果
- 支持长按
- 触觉反馈

#### _iosSectionCard（设置分组卡片）

用于设置页面的分组，类似 iOS 设置：

```dart
_iosSectionCard(children: [
  _iosNavRow(...),
  _iosDivider(context),
  _iosNavRow(...),
])
```

---

### 4. 列表行组件

#### _iosNavRow（导航行）

设置页面中的每一行：

```dart
_iosNavRow(
  context,
  icon: Icons.settings,
  label: '设置项',
  detailText: '当前值',    // 右侧说明文字
  detailBuilder: (ctx) => Widget,  // 或自定义控件
  onTap: () {},
)
```

**视觉特点：**
- 左侧 36px 宽图标区
- 中间标题
- 右侧可选的说明文字或控件
- 最右侧展开箭头 `>`
- 按压时颜色变淡（无缩放）

---

### 5. 通知/提示组件

#### AppSnackBarManager（通知管理器）
📄 `lib/shared/widgets/snackbar.dart`

```dart
// 快捷调用
showAppSnackBar(
  context,
  message: '保存成功',
  type: NotificationType.success,  // success/error/info/warning
  duration: Duration(seconds: 3),
  onTap: () {},
  actionLabel: '撤销',
  onAction: () {},
);

// 类型枚举
enum NotificationType {
  success,
  error,
  info,
  warning,
}
```

**核心特性：**
- 单例管理器模式
- 最多同时显示 3 个通知
- 堆叠效果（后面的缩小、偏移、透明度降低）
- 滑动关闭（向上滑动）
- 自动消失
- 入场/退场动画

---

### 6. 动画工具

📄 `lib/shared/animations/widgets.dart`

```dart
// 通用时长常量
const Duration kAnimFast = Duration(milliseconds: 180);
const Duration kAnim = Duration(milliseconds: 240);
const Duration kAnimSlow = Duration(milliseconds: 320);

// 图标切换动画
AnimatedIconSwap(child: Icon(...))

// 文字切换动画
AnimatedTextSwap(text: '文字', style: ...)

// 出现动画扩展
widget.appear(duration: kAnim, dy: 0.02, begin: 0)
```

---

## 📋 设置页面模式

Kelivo 的设置页面是一个很好的参考范例：

### 页面结构

```dart
Scaffold(
  appBar: AppBar(...),
  body: ListView(
    children: [
      header('通用设置', first: true),
      _iosSectionCard(children: [
        _iosNavRow(...),
        _iosDivider(context),
        _iosNavRow(...),
      ]),
      
      SizedBox(height: 12),
      header('模型服务'),
      _iosSectionCard(...),
      
      // 更多分组...
    ],
  ),
)
```

### 视觉规范

| 元素 | 规格 |
|------|------|
| 分组标题 | fontSize: 13, fontWeight: w600, opacity: 0.8 |
| 行内边距 | horizontal: 12, vertical: 11 |
| 图标尺寸 | 20 |
| 图标区宽度 | 36 |
| 图标与文字间距 | 12 |
| 卡片圆角 | 12 |
| 卡片间距 | 12 |
| 分割线缩进 | 54（与文字对齐） |

---

## 🔑 设计哲学总结

### 1. iOS 触感优先

- **无水波纹**：不使用 InkWell/InkResponse
- **颜色过渡**：按压时改变背景/前景色
- **可选缩放**：部分控件按压时微缩（0.98）
- **触觉反馈**：关键操作震动

### 2. 状态驱动动画

```dart
// 典型模式
class _XxxState extends State<Xxx> {
  bool _pressed = false;
  bool _hovered = false;

  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedContainer(
        duration: Duration(milliseconds: 200),
        decoration: BoxDecoration(
          color: _pressed ? pressedColor : normalColor,
        ),
        child: ...
      ),
    );
  }
}
```

### 3. 暗色模式优先

- 每个组件都有 isDark 判断
- 颜色计算区分亮/暗模式
- 使用 `Color.lerp` 进行颜色混合

### 4. 语义化与可访问性

- Semantics 包装
- semanticLabel 属性
- 最小点击区域（通常 44x44）

---

## 📊 对比 MyGril 现状

| 维度 | Kelivo | MyGril |
|------|--------|--------|
| 按钮组件 | ✅ IosTileButton, IosIconButton | ❌ 无统一组件 |
| 开关组件 | ✅ IosSwitch | ❌ 使用原生 Switch |
| 复选框 | ✅ IosCheckbox | ❌ 使用原生 Checkbox |
| 列表行 | ✅ _iosNavRow | ❌ 各页面自行实现 |
| 卡片容器 | ✅ IosCardPress, _iosSectionCard | ⚠️ 有 GradientBlurCard 但场景不同 |
| 通知系统 | ✅ AppSnackBarManager | ✅ MoeToast |
| 弹窗 | 使用系统+定制 | ✅ MeoTalkDialog（但无人使用） |
| 动画常量 | ✅ kAnimFast/kAnim/kAnimSlow | ❌ 无统一定义 |
| Design Tokens | ✅ AppRadii, AppSpacing | ⚠️ 有 tokens.dart 但不够完整 |

---

## 🎯 可借鉴的关键点

1. **创建统一的按钮组件**
   - MoePrimaryButton（主按钮）
   - MoeSecondaryButton（次级按钮）
   - MoeIconButton（图标按钮）
   - MoeTileButton（列表项按钮）

2. **创建统一的表单控件**
   - MoeSwitch
   - MoeCheckbox
   - MoeTextField

3. **创建统一的列表组件**
   - MoeSettingsRow（设置行）
   - MoeSettingsGroup（设置分组卡片）
   - MoeListTile（通用列表项）

4. **补充 Design Tokens**
   - 统一动画时长（kAnimFast/kAnim/kAnimSlow）
   - 统一间距（spacing）
   - 统一圆角变体（radiusSmall/radiusCard/radiusLarge）

5. **推广公共弹窗使用**
   - MeoTalkDialog 已存在，需要推广使用
   - 为常见场景提供便捷函数

---

## 📁 附录：Kelivo 组件文件清单

```
lib/shared/widgets/
├── emoji_picker_dialog.dart
├── emoji_text.dart
├── export_capture_scope.dart
├── favicon.dart
├── interactive_drawer.dart
├── ios_checkbox.dart          ✅ 复选框
├── ios_switch.dart             ✅ 开关
├── ios_tactile.dart            ✅ 图标按钮、卡片按压
├── ios_tile_button.dart        ✅ 瓷砖按钮
├── markdown_with_highlight.dart
├── mermaid_*.dart              # 图表相关
├── plantuml_block.dart
└── snackbar.dart               ✅ 通知系统
```
