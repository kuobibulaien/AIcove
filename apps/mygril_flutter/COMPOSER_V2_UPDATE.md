# Composer V2 更新 - 展开式功能菜单

## 更新日期
2025-11-06

## 问题描述
用户反馈：Android 端的功能菜单是覆盖式弹窗，点击加号后菜单覆盖在内容上方。希望改成像 QQ 那样，点击加号后菜单从底部展开，把输入框顶上去。

## 解决方案

### 设计变更

**V1 设计（覆盖式）**:
```
┌─────────────────────────┐
│   聊天消息区域          │
│                         │  菜单覆盖在上面
│   ┌─────────────────┐  │  ↓
│   │  功能菜单       │  │
│   │  (Modal Sheet)  │  │
│   └─────────────────┘  │
├─────────────────────────┤
│ [+] [输入框] [▶]       │  输入栏保持不动
└─────────────────────────┘
```

**V2 设计（展开式，像QQ）**:
```
展开前:
┌─────────────────────────┐
│   聊天消息区域          │
│                         │
│                         │
│                         │
├─────────────────────────┤
│ [+] [输入框] [▶]       │  ← 输入栏在底部
└─────────────────────────┘

展开后:
┌─────────────────────────┐
│   聊天消息区域          │
│   (被顶上去)            │
├─────────────────────────┤
│ 🤖 📷 📸 📞            │  ← 功能菜单从底部展开
│ 📹 🫱 🎁 📍            │     (高度动画展开)
├─────────────────────────┤
│ [×] [输入框] [▶]       │  ← 输入栏跟着被顶上去
└─────────────────────────┘
```

### 技术实现

#### 1. **组件结构变更**

**V1 结构**:
```dart
Composer
└─ Container (输入栏)
   └─ Row
      ├─ [+] 按钮 → showModalBottomSheet()
      ├─ TextField
      └─ [▶] 按钮
```

**V2 结构**:
```dart
Composer
└─ Column
   ├─ SizeTransition (功能菜单，可展开)
   │  └─ _ActionsMenuContent
   │     └─ GridView (功能按钮)
   └─ Container (输入栏，固定)
      └─ Row
         ├─ [+] 按钮 → _toggleActionsMenu()
         ├─ TextField
         └─ [▶] 按钮
```

#### 2. **动画实现**

```dart
class _ComposerState extends ConsumerState<Composer>
    with SingleTickerProviderStateMixin {  // 添加 Mixin

  bool _isMenuExpanded = false;  // 展开状态
  late AnimationController _animController;  // 动画控制器
  late Animation<double> _animation;  // 动画曲线

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),  // 250ms 动画
    );
    _animation = CurvedAnimation(
      parent: _animController,
      curve: Curves.easeInOut,  // 缓入缓出
    );
  }

  void _toggleActionsMenu() {
    setState(() {
      _isMenuExpanded = !_isMenuExpanded;
      if (_isMenuExpanded) {
        _animController.forward();  // 展开
      } else {
        _animController.reverse();  // 收起
      }
    });
  }
}
```

#### 3. **布局使用 SizeTransition**

```dart
SizeTransition(
  sizeFactor: _animation,  // 动画因子 (0.0 - 1.0)
  axisAlignment: -1.0,  // 从顶部展开 (-1.0)
  child: Container(
    child: _ActionsMenuContent(...),  // 功能菜单内容
  ),
)
```

**关键参数**:
- `sizeFactor`: 动画进度 (0.0 = 完全收起, 1.0 = 完全展开)
- `axisAlignment: -1.0`: 从顶部开始展开
- `axisAlignment: 0.0`: 从中间展开
- `axisAlignment: 1.0`: 从底部展开

#### 4. **加号按钮旋转动画**

```dart
AnimatedRotation(
  turns: _isMenuExpanded ? 0.125 : 0,  // 展开时旋转 45度 (0.125 圈)
  duration: const Duration(milliseconds: 250),
  child: const Icon(Icons.add),
)
```

### 代码变更清单

#### 新增代码
1. `_isMenuExpanded` - 菜单展开状态
2. `_animController` - 动画控制器
3. `_animation` - 动画曲线
4. `_toggleActionsMenu()` - 切换菜单展开/收起
5. `_closeActionsMenu()` - 关闭菜单
6. `_ActionsMenuContent` - 功能菜单内容组件（StatelessWidget）

#### 修改代码
1. `_ComposerState` - 添加 `SingleTickerProviderStateMixin`
2. `initState()` - 初始化动画控制器
3. `dispose()` - 释放动画控制器
4. `build()` - 使用 Column 布局，添加 SizeTransition
5. `_buildPlusButton()` - 添加 AnimatedRotation

#### 删除代码
1. `_ActionsMenu (ConsumerWidget)` - 旧的覆盖式菜单
2. `_showActionsMenu()` - 显示 BottomSheet 的方法

### 用户体验改进

#### 交互行为
1. **点击加号按钮**:
   - 按钮旋转 45 度
   - 功能菜单从底部展开 (250ms 动画)
   - 输入栏被顶上去

2. **再次点击加号按钮**:
   - 按钮旋转回 0 度
   - 功能菜单收起 (250ms 动画)
   - 输入栏恢复到底部

3. **点击功能按钮后**:
   - 自动关闭菜单
   - 执行对应功能（或显示开发中提示）

#### 视觉效果
- ✅ 输入栏跟随菜单移动（像 QQ）
- ✅ 平滑的展开/收起动画
- ✅ 加号按钮旋转提示状态变化
- ✅ 功能菜单不再遮挡消息内容

#### 性能优化
- 使用 `SizeTransition` 替代手动计算高度
- 动画使用硬件加速
- 菜单内容只渲染一次，不是每次打开都重建

### 布局调整

#### 功能菜单样式
- **Padding**: `12px` 水平，`16px` 顶部，`12px` 底部
- **Grid 间距**: 行间距 `12px`，列间距 `12px`
- **按钮尺寸**: `56x56px`
- **标签字体**: `11px`（比之前小 1px）
- **按钮背景**: 白色（之前是 `moeSurface`）

#### 按钮顺序
1. 选择模型 🤖
2. 照片 📷
3. 拍照 📸
4. 语音通话 📞
5. 视频通话 📹
6. 戳一戳 🫱
7. 红包 🎁
8. 位置 📍
9. 文件 📁

### 测试建议

#### 功能测试
- [ ] 点击加号展开菜单
- [ ] 再次点击加号收起菜单
- [ ] 点击功能按钮后菜单自动关闭
- [ ] 点击"选择模型"打开模型选择器
- [ ] 其他功能显示"开发中"提示

#### 动画测试
- [ ] 展开动画流畅 (250ms)
- [ ] 收起动画流畅 (250ms)
- [ ] 加号旋转动画同步
- [ ] 输入栏跟随菜单移动

#### 兼容性测试
- [ ] Android 真机测试
- [ ] iOS 真机测试
- [ ] Web 浏览器测试
- [ ] 不同屏幕尺寸测试

#### 性能测试
- [ ] 快速点击加号按钮
- [ ] 展开状态下输入文本
- [ ] 内存使用情况

### 已知限制

1. **菜单高度固定**:
   - 当前菜单高度由 9 个按钮的网格决定
   - 如果按钮数量增加，需要调整布局或添加滚动

2. **动画时长固定**:
   - 250ms 的动画时长适合大多数情况
   - 如需调整，修改 `AnimationController` 的 `duration`

3. **展开方向固定**:
   - 目前从顶部展开 (`axisAlignment: -1.0`)
   - 不支持动态调整方向

### 后续优化建议

1. **手势支持**:
   - 添加向下滑动关闭菜单的手势
   - 添加向上滑动展开菜单的手势

2. **记忆状态**:
   - 记住用户最后的菜单状态（展开/收起）
   - 下次打开聊天页时恢复状态

3. **响应式布局**:
   - 根据屏幕宽度调整列数（手机 4列，平板 6列）
   - 根据屏幕高度调整菜单最大高度

4. **自定义功能**:
   - 允许用户自定义功能按钮顺序
   - 允许用户隐藏不常用的功能

5. **快捷键支持**:
   - 桌面端添加键盘快捷键展开/收起菜单
   - 例如: `Ctrl/Cmd + B` 切换菜单

### 相关文件

- `lib/src/features/chat/presentation/widgets/composer.dart` - Composer 组件
- `lib/src/core/theme/tokens.dart` - 主题常量
- `lib/src/features/settings/app_settings.dart` - 应用设置

### 版本历史

| 版本 | 日期 | 更新内容 |
|-----|------|---------|
| V2.0 | 2025-11-06 | 展开式功能菜单，像 QQ 一样把输入框顶上去 |
| V1.0 | 2025-11-06 | 覆盖式功能菜单（BottomSheet） |

---

**维护者**: Claude Code Assistant
**最后更新**: 2025-11-06
