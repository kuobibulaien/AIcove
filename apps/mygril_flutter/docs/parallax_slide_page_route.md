# 视差滑动动画 (Parallax Slide Page Route) 使用指南

## 概述

实现类似**鸿蒙NEXT / iOS**风格的页面切换动画：
- **新页面**：从右侧滑入，左侧带阴影
- **底层页面**：微幅左移，形成视差跟随效果

---

## 动画参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `duration` | 400ms | 进入动画时长 |
| `reverseDuration` | 350ms | 返回动画时长 |
| `curve` | `fastOutSlowIn` | 动画曲线（Material Design 标准） |
| `secondarySlideRatio` | 0.08 | 底层页面左移比例（8%） |
| `shadow` | 16px blur, -4px offset | 新页面左侧阴影 |

---

## 使用方式

### 方式一：go_router（推荐）

适用于使用 go_router 的项目。需要在**两个路由**中分别配置动画。

```dart
import 'package:mygril_flutter/src/core/widgets/parallax_slide_page_route.dart';

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
              transitionDuration: const Duration(milliseconds: 400),
              reverseTransitionDuration: const Duration(milliseconds: 350),
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
import 'package:mygril_flutter/src/core/widgets/parallax_slide_page_route.dart';

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
  duration: Duration(milliseconds: 500),      // 更慢的动画
  reverseDuration: Duration(milliseconds: 400),
  curve: Curves.easeOutQuart,                 // 更柔和的曲线
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
lib/src/core/widgets/parallax_slide_page_route.dart
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

---

## 更新记录

- **2025-12-02**：创建，实现视差滑动动画，调优参数
