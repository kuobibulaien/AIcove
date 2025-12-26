# iOS 风格平滑圆角组件 (Smooth Clip)

## 概述

本组件提供 iOS 风格的**平滑圆角**（Squircle / Continuous Corner）效果，区别于 Flutter 默认的标准圆角。

### 视觉差异

| 标准圆角 | 平滑圆角 |
|---------|---------|
| `BorderRadius.circular()` | `SmoothClipRRect` |
| 圆弧与直边交接处有明显拐点 | 圆弧与直边平滑过渡，无拐点 |
| 适合一般 UI 元素 | 适合 iOS 风格卡片、相册封面 |

---

## 核心组件

### 文件位置
```
lib/src/core/widgets/smooth_clip.dart
```

### 组件列表

| 组件 | 用途 |
|------|------|
| `SmoothClipRRect` | 平滑圆角裁剪容器（推荐使用） |
| `SmoothRectClipper` | 自定义裁剪器（供 ClipPath 使用） |
| `SmoothRectDecoration` | 平滑圆角装饰（仅绘制背景，不裁剪子组件） |

---

## 使用方法

### 1. 基础用法 - SmoothClipRRect

```dart
import '../../../../core/widgets/smooth_clip.dart';

// 包裹任意 Widget，实现平滑圆角裁剪
SmoothClipRRect(
  radius: 12.0,  // 圆角半径，与标准 BorderRadius 使用相同的值
  child: Container(
    color: Colors.blue,
    child: YourContent(),
  ),
)
```

### 2. 与展开动画配合使用

`ExpandingPageRoute` 内部已使用平滑圆角，确保动画过渡时圆角样式一致：

```dart
// 卡片使用 SmoothClipRRect
Widget buildCard() {
  return SmoothClipRRect(
    radius: 12.0,
    child: CardContent(),
  );
}

// 点击时使用 ExpandingPageRoute（内部自动使用平滑圆角）
onTap: () {
  Navigator.of(context).pushExpanding(
    page: DetailPage(),
    sourceContext: cardContext,
    sourceRadius: 12.0,  // 与卡片圆角保持一致
  );
}
```

### 3. 自定义 ClipPath

如果需要更细粒度的控制：

```dart
ClipPath(
  clipper: SmoothRectClipper(radius: 16.0),
  child: YourWidget(),
)
```

---

## 技术原理

### ContinuousRectangleBorder

Flutter 提供的 `ContinuousRectangleBorder` 使用超椭圆曲线（Superellipse）生成路径，
与 iOS 的 `UIBezierPath(roundedRect:cornerRadius:)` 视觉效果一致。

### 转换系数

`ContinuousRectangleBorder` 需要更大的圆角值才能达到与标准圆角相同的视觉效果。
本组件内部使用 **2.35** 作为转换系数：

```dart
// 内部实现
final shape = ContinuousRectangleBorder(
  borderRadius: BorderRadius.circular(radius * 2.35),
);
```

这意味着你传入 `radius: 12.0`，实际生成的路径使用 `12.0 * 2.35 = 28.2` 的圆角值，
但视觉上与标准 `BorderRadius.circular(12.0)` 大小接近，只是更加平滑。

---

## 应用场景

本项目中使用平滑圆角的位置：

| 页面 | 组件 | 说明 |
|------|------|------|
| 表情包管理 | 文件夹卡片 | iOS 相册风格 |
| 表情包管理 | 展开动画 | 与卡片圆角一致 |
| 角色卡 | 海报卡片 | 视觉更精致 |
| 角色卡 | 展开动画 | 与卡片圆角一致 |

---

## 注意事项

1. **性能**：`ClipPath` 比 `ClipRRect` 略慢，但在现代设备上几乎无感知。

2. **嵌套裁剪**：避免多层 `SmoothClipRRect` 嵌套，可能导致性能问题。

3. **阴影**：`SmoothClipRRect` 只负责裁剪，不绘制阴影。如需阴影，可使用 `SmoothRectDecoration` 或在外层添加 `DecoratedBox`。

4. **InkWell 水波纹**：`InkWell` 的 `borderRadius` 仍使用标准圆角，视觉上会有细微差异。如需完美匹配，可自定义 `InkWell` 的 `customBorder`。

---

## 更新记录

- **2025-12-03**：创建组件，用于表情包管理页面和角色卡页面
