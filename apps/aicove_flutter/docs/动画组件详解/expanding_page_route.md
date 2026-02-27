# 原地展开动画 (Expanding Page Route) 实现指南

## 概述

本文档介绍如何实现 **"点击卡片原地展开成详情页面"** 的动画效果，即 Material Design 中的 **Container Transform** 效果。

### 效果描述
- **打开动画**：点击卡片 → 卡片从原位置"撑开"变大 → 铺满屏幕 → 详情内容淡入
- **关闭动画**：详情内容淡出 → 容器从全屏"收缩"回卡片原位

---

## 核心原理

### 为什么不用 Hero？

Flutter 的 `Hero` 动画本质是 **飞行动画**（从 A 点飞到 B 点），而不是"原地展开"。即使用 `flightShuttleBuilder` 自定义飞行内容，也很难完美模拟"容器变换"效果。

### 我们的方案

使用 **自定义 PageRoute**，手动控制：
1. **位置插值**：从卡片位置 → 全屏位置
2. **大小插值**：从卡片大小 → 全屏大小
3. **圆角插值**：从卡片圆角 → 0
4. **内容透明度**：延迟淡入，避免"内容挤压变形"

---

## 核心代码

### 1. 自定义展开路由 `_ExpandingPageRoute`

```dart
/// 自定义展开路由 - 实现"原地展开"动画效果
class _ExpandingPageRoute<T> extends PageRoute<T> {
  final Widget page;           // 目标页面
  final Rect sourceRect;       // 源卡片的屏幕位置和大小
  final double sourceRadius;   // 源卡片的圆角

  _ExpandingPageRoute({
    required this.page,
    required this.sourceRect,
    required this.sourceRadius,
  });

  @override
  bool get opaque => false; // 透明背景，动画过程可见

  @override
  bool get barrierDismissible => false;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 400);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 350);

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) {
    return page;
  }

  @override
  Widget buildTransitions(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation, Widget child) {
    final screenSize = MediaQuery.of(context).size;
    final colors = context.moeColors; // 替换为你的主题色获取方式
    
    // 使用平滑曲线
    final curvedAnimation = CurvedAnimation(
      parent: animation,
      curve: Curves.easeInOutCubic,
      reverseCurve: Curves.easeInOutCubic,
    );

    return AnimatedBuilder(
      animation: curvedAnimation,
      builder: (context, _) {
        final progress = curvedAnimation.value;
        
        // 1. 位置和大小插值：从源卡片 → 全屏
        final currentRect = Rect.lerp(
          sourceRect,
          Rect.fromLTWH(0, 0, screenSize.width, screenSize.height),
          progress,
        )!;
        
        // 2. 圆角插值：从卡片圆角 → 0
        final currentRadius = sourceRadius * (1 - progress);
        
        // 3. 内容透明度：后 70% 渐变显示
        //    前 30% 容器展开，后 70% 内容淡入
        final contentOpacity = ((progress - 0.3) / 0.7).clamp(0.0, 1.0);
        
        // 4. 背景遮罩透明度
        final overlayOpacity = progress * 0.3; // 最大 30% 黑色遮罩
        
        return Stack(
          children: [
            // 半透明背景遮罩（可选）
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  color: Colors.black.withOpacity(overlayOpacity),
                ),
              ),
            ),
            // 展开的容器
            Positioned(
              left: currentRect.left,
              top: currentRect.top,
              width: currentRect.width,
              height: currentRect.height,
              child: Material(
                color: colors.surface, // 替换为你的背景色
                elevation: 8 * progress, // 逐渐增加阴影
                borderRadius: BorderRadius.circular(currentRadius),
                clipBehavior: Clip.antiAlias,
                child: Opacity(
                  opacity: contentOpacity,
                  child: child,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
```

### 2. 获取卡片位置并导航

```dart
// 在卡片的 onTap 回调中：
onTap: () async {
  // 1. 获取卡片在屏幕上的位置和大小
  final RenderBox box = context.findRenderObject() as RenderBox;
  final Offset position = box.localToGlobal(Offset.zero);
  final Size cardSize = box.size;
  final sourceRect = Rect.fromLTWH(
    position.dx, position.dy, cardSize.width, cardSize.height,
  );

  // 2. 使用自定义路由导航
  final result = await Navigator.of(context).push<YourResultType>(
    _ExpandingPageRoute(
      page: YourDetailPage(...),
      sourceRect: sourceRect,
      sourceRadius: 12.0, // 你的卡片圆角值
    ),
  );

  // 3. 处理返回结果
  if (result != null) {
    // ...
  }
}
```

### 3. 使用 Builder 确保获取正确的 Context

如果卡片在 `ListView` 或 `GridView` 中，需要用 `Builder` 包裹：

```dart
itemBuilder: (context, index) {
  return Builder(
    builder: (cardContext) {  // 使用 cardContext 而不是外层 context
      return YourCard(
        onTap: () {
          final RenderBox box = cardContext.findRenderObject() as RenderBox;
          // ...
        },
      );
    },
  );
}
```

---

## 关键参数调优

| 参数 | 推荐值 | 说明 |
|------|--------|------|
| `transitionDuration` | 300-500ms | 打开动画时长 |
| `reverseTransitionDuration` | 250-400ms | 关闭动画时长（略快更自然） |
| `curve` | `easeInOutCubic` | 平滑的加速减速曲线 |
| `contentOpacity` 起始点 | 0.3 | 容器展开 30% 后开始显示内容 |
| `overlayOpacity` 最大值 | 0.3 | 背景遮罩最深 30% 黑色 |

---

## 在其他界面复用

### 步骤 1：提取为公共组件

将 `_ExpandingPageRoute` 移动到公共文件：

```
lib/
  src/
    core/
      widgets/
        expanding_page_route.dart  ← 放在这里
```

### 步骤 2：创建便捷扩展方法

```dart
// lib/core/extensions/navigator_extensions.dart

extension ExpandingNavigator on NavigatorState {
  Future<T?> pushExpanding<T>({
    required Widget page,
    required BuildContext sourceContext,
    double sourceRadius = 12.0,
  }) {
    final RenderBox box = sourceContext.findRenderObject() as RenderBox;
    final position = box.localToGlobal(Offset.zero);
    final size = box.size;
    
    return push<T>(
      ExpandingPageRoute(
        page: page,
        sourceRect: Rect.fromLTWH(position.dx, position.dy, size.width, size.height),
        sourceRadius: sourceRadius,
      ),
    );
  }
}
```

### 步骤 3：使用扩展方法

```dart
// 任何地方使用：
Navigator.of(context).pushExpanding(
  page: DetailPage(...),
  sourceContext: cardContext,
  sourceRadius: radiusBubble.x,
);
```

---

## 注意事项

1. **移除目标页面的 Hero 包裹**：如果目标页面之前用了 `Hero`，需要移除，否则会冲突。

2. **Context 正确性**：`findRenderObject()` 必须在卡片自己的 `BuildContext` 上调用，不能用父级 context。

3. **性能优化**：如果页面内容复杂，可以考虑在 `contentOpacity` 为 0 时不渲染 `child`，避免无谓的布局计算。

4. **键盘适配**：如果目标页面有输入框，键盘弹出时可能影响动画。可以在动画完成后再聚焦输入框。

---

## 文件位置参考

本项目中的实现位于：
- **公共组件**: `lib/src/core/widgets/expanding_page_route.dart`
  - `ExpandingPageRoute` 类
  - `ExpandingNavigatorExtension` 扩展方法
  - `getSourceRect()` 辅助函数
- **使用示例**: `lib/src/features/chat/presentation/pages/role_card_page.dart`
  - `RoleCardContent` 的 `itemBuilder`（第 122-165 行）

---

## 更新记录

- **2025-12-01**：初始实现，用于角色卡页面
