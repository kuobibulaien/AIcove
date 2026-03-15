# 视差滑动动画 (Parallax Slide Page Route) 使用指南

## 概述

实现类似**鸿蒙NEXT / iOS**风格的页面切换动画：
- **新页面**：从右侧滑入，左侧带阴影
- **底层页面**：微幅左移，形成视差跟随效果

---

## 动画参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `duration` | 320ms | 进入动画时长 |
| `reverseDuration` | 280ms | 返回动画时长 |
| `primaryCurve` | `Cubic(0.4, 0.0, 0.4, 1.0)` | 前景页滑入曲线（Harmony Smooth） |
| `secondaryCurve` | `Cubic(0.2, 0.0, 0.2, 1.0)` | 底层页左移曲线（Harmony Friction） |
| `secondarySlideRatio` | 0.08 | 底层页面左移比例（8%） |
| `shadow` | 16px blur, -4px offset | 新页面左侧阴影 |

### 本次调优思路

- 保留现有“新页面右滑进入 + 底层页面轻微左移”的鸿蒙式结构
- 保留位移比例不变，同时把时长从 `400/350ms` 缩短到 `320/280ms`
- 前景页用更平稳的 `Smooth`，减少起步过快
- 背景页用更柔和的 `Friction`，让左移更像被轻轻带走

---

## 使用方式

### 方式一：go_router（推荐）

适用于使用 go_router 的项目。需要在**两个路由**中分别配置动画。

```dart
import 'package:aicove_flutter/src/ui/shared/animations/parallax_slide_page_route.dart';

final router = GoRouter(
  routes: [
    GoRoute(
      path: '/',
      pageBuilder: (context, state) {
        return CustomTransitionPage(
          key: state.pageKey,
          child: const MainPage(),
          // ① 底层页面：被覆盖时微幅左移
          transitionsBuilder: buildSecondaryParallaxTransition(),
        );
      },
      routes: [
        GoRoute(
          path: 'detail/:id',
          pageBuilder: (context, state) {
            return CustomTransitionPage(
              key: state.pageKey,
              child: DetailPage(id: state.pathParameters['id']),
  transitionDuration: const Duration(milliseconds: 320),
  reverseTransitionDuration: const Duration(milliseconds: 280),
              // ② 新页面：从右侧滑入，带阴影
              transitionsBuilder: buildPrimaryParallaxTransition(),
            );
          },
        ),
      ],
    ),
  ],
);
```

### 方式二：Navigator.push

适用于直接使用 Navigator 的场景。

```dart
import 'package:aicove_flutter/src/ui/shared/animations/parallax_slide_page_route.dart';

// 使用扩展方法
Navigator.of(context).pushParallaxSlide(
  page: DetailPage(),
);

// 或直接使用 PageRoute
Navigator.of(context).push(
  ParallaxSlidePageRoute(
    page: DetailPage(),
  ),
);
```

---

## 自定义配置

```dart
// 创建自定义配置
const myConfig = ParallaxSlideConfig(
  duration: Duration(milliseconds: 420),      // 更慢的动画
  reverseDuration: Duration(milliseconds: 360),
  primaryCurve: Curves.easeOutQuart,          // 前景页曲线
  secondaryCurve: Curves.easeOutCubic,        // 背景页曲线
  secondarySlideRatio: 0.12,                  // 底层左移 12%
  shadow: BoxShadow(
    color: Color(0x40000000),                 // 更深的阴影
    blurRadius: 24,
    offset: Offset(-8, 0),
  ),
);

// go_router 中使用
transitionsBuilder: buildPrimaryParallaxTransition(config: myConfig),
transitionsBuilder: buildSecondaryParallaxTransition(config: myConfig),

// Navigator 中使用
Navigator.of(context).pushParallaxSlide(
  page: DetailPage(),
  config: myConfig,
);
```

### 禁用阴影

```dart
const noShadowConfig = ParallaxSlideConfig(
  shadow: null,  // 不显示阴影
);
```

---

## 文件位置

```
lib/src/ui/shared/animations/parallax_slide_page_route.dart
├── ParallaxSlideConfig          // 配置类
├── buildSecondaryParallaxTransition()  // go_router 底层页面动画
├── buildPrimaryParallaxTransition()    // go_router 新页面动画
├── ParallaxSlidePageRoute       // Navigator.push 用的 PageRoute
└── ParallaxSlideNavigatorExtension     // Navigator 扩展方法
```

---

## 实现原理

### 1. 底层页面动画

监听 `secondaryAnimation`（当此页面被新页面覆盖时从 0→1）：

```dart
SlideTransition(
  position: curvedSecondary.drive(
    Tween(begin: Offset.zero, end: Offset(-0.08, 0.0)),
  ),
  child: child,
)
```

其中 `curvedSecondary` 默认使用 Harmony `Friction` 曲线：

```dart
CurvedAnimation(
  parent: secondaryAnimation,
  curve: const Cubic(0.2, 0.0, 0.2, 1.0),
)
```

### 2. 新页面动画

监听 `animation`（进入动画从 0→1）：

```dart
SlideTransition(
  position: animation.drive(
    Tween(begin: Offset(1.0, 0.0), end: Offset.zero),
  ),
  child: DecoratedBox(
    decoration: BoxDecoration(boxShadow: [shadow]),
    child: child,
  ),
)
```

前景页默认使用 Harmony `Smooth` 曲线：

```dart
Tween(
  begin: const Offset(1.0, 0.0),
  end: Offset.zero,
).chain(
  CurveTween(curve: const Cubic(0.4, 0.0, 0.4, 1.0)),
)
```

---

## 更新记录

- **2026-03-15**：将单一 `fastOutSlowIn` 调整为 Harmony 风格双曲线：前景 `Smooth`，背景 `Friction`
- **2026-03-15**：将默认时长从 `400/350ms` 缩短到 `320/280ms`，降低整块滑动的拖沓感
- **2025-12-02**：创建，实现视差滑动动画，调优参数
