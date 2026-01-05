# Figma 风格平滑圆角组件 (Smooth Clip)

## 概述

本组件提供 **Figma/iOS 风格的 G2 曲率连续平滑圆角**（Squircle）效果，区别于 Flutter 默认的标准圆角。

> **2025-12-28 升级说明**：组件已从 `ContinuousRectangleBorder` 升级为 `figma_squircle` 包，实现真正的 G2 曲率连续算法，与 Figma 设计工具完全一致。

### 视觉差异

| 类型 | 实现 | 特点 |
|------|------|------|
| 标准圆角 | `BorderRadius.circular()` | 圆弧与直边交接处有明显拐点 |
| ~~ContinuousRectangleBorder~~ | ~~超椭圆曲线~~ | ~~近似平滑，但非 G2 连续~~（已弃用） |
| **平滑圆角** | `SmoothClipRRect` | **G2 曲率连续**，与 Figma 一致 |

---

## 核心组件

### 文件位置
```
lib/src/core/widgets/smooth_clip.dart
```

### 依赖
```yaml
figma_squircle: ^0.6.3
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
  radius: 12.0,  // 圆角半径
  // smoothing: 0.6,  // 可选，平滑度 (0.0-1.0)，默认 0.6 = iOS 风格
  child: Container(
    color: Colors.blue,
    child: YourContent(),
  ),
)
```

### 2. 平滑度参数

`smoothing` 参数控制曲线的平滑程度：

| 值 | 效果 | 说明 |
|----|------|------|
| 0.0 | 标准圆角 | 与 `BorderRadius.circular` 相同 |
| **0.6** | **iOS 风格** | **默认值**，与 Figma 60% corner smoothing 相同 |
| 1.0 | 最大平滑 | 完全的 squircle（似乎过于圆润） |

```dart
// 完全平滑的 squircle
SmoothClipRRect(
  radius: 20.0,
  smoothing: 1.0,  // 最大平滑
  child: YourWidget(),
)
```

### 3. 与展开动画配合使用

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

### 4. 自定义 ClipPath

如果需要更细粒度的控制：

```dart
ClipPath(
  clipper: SmoothRectClipper(
    radius: 16.0,
    smoothing: 0.6,  // 可选
  ),
  child: YourWidget(),
)
```

### 5. 装饰用法

```dart
Container(
  decoration: SmoothRectDecoration(
    radius: 16.0,
    smoothing: 0.6,
    color: Colors.white,
    border: Border.all(color: Colors.grey),
    boxShadow: [
      BoxShadow(
        color: Colors.black26,
        blurRadius: 8,
        offset: Offset(0, 2),
      ),
    ],
  ),
  child: YourContent(),
)
```

---

## 技术原理

### G2 曲率连续

G2 曲率连续意味着：
- **G0**：曲线位置连续（普通圆角也满足）
- **G1**：切线方向连续（曲线平滑）
- **G2**：**曲率也连续**（曲线的弯曲程度平滑过渡）

传统圆角在直线和圆弧交接处，曲率从 0 突变到 1/r，视觉上有"拐点感"。
G2 连续圆角通过贝塞尔曲线使曲率渐变，视觉更加自然柔和。

### figma_squircle 实现

`figma_squircle` 包使用与 Figma 相同的算法：
- 组合两段贝塞尔曲线和一段圆弧
- `cornerSmoothing` 参数对应 Figma 的 "Corner Smoothing" 滑块
- 0.6 (60%) 是 iOS 系统 UI 使用的标准值

---

## 应用场景

本项目中使用平滑圆角的位置：

| 页面 | 组件 | 说明 |
|------|------|------|
| 表情包管理 | 文件夹卡片 | iOS 相册风格 |
| 表情包管理 | 展开动画 | 与卡片圆角一致 |
| 角色卡 | 海报卡片 | 视觉更精致 |
| 角色卡 | 展开动画 | 与卡片圆角一致 |
| 毛玻璃卡片 | FrostedGlassCard | iOS 风格毛玻璃 |
| 渐变模糊卡片 | GradientBlurCard | 统一圆角风格 |

---

## 注意事项

1. **性能**：`ClipPath` 比 `ClipRRect` 略慢，但在现代设备上几乎无感知。

2. **嵌套裁剪**：避免多层 `SmoothClipRRect` 嵌套，可能导致性能问题。

3. **阴影**：`SmoothClipRRect` 只负责裁剪，不绘制阴影。如需阴影，可使用 `SmoothRectDecoration` 或在外层添加 `DecoratedBox`。

4. **InkWell 水波纹**：`InkWell` 的 `borderRadius` 仍使用标准圆角，视觉上会有细微差异。如需完美匹配，可自定义 `InkWell` 的 `customBorder`。

---

## 更新记录

- **2025-12-28**：升级为 `figma_squircle` 包，实现真正的 G2 曲率连续算法
- **2025-12-25**：修复 `SmoothRectDecoration` 描边问题
- **2025-12-03**：创建组件，用于表情包管理页面和角色卡页面
