# Composer 组件更新文档

## 更新日期
2025-11-06

## 更新概述
重新设计了 Composer 组件的 UI 布局，解决了 Android 端界面拥挤的问题。

## 更新前的设计

```
┌─────────────────────────────────┐
│ [模型▼] [输入框...] [📷] [▶]   │  ← 旧版 Composer
└─────────────────────────────────┘
```

**问题**：
- 4个控件挤在一行，Android 端界面被压缩
- 模型选择器占用过多空间
- 功能按钮不易扩展

## 更新后的设计

```
┌─────────────────────────────────┐
│ [+] [输入框...........] [▶]     │  ← 新版 Composer
└─────────────────────────────────┘
```

**改进**：
- 简化为3个控件：加号按钮 + 输入框 + 发送按钮
- 模型选择和其他功能移至二级菜单
- 界面更加简洁，不会被压缩

## 附加功能菜单

点击 [+] 按钮后，会从底部弹出功能菜单：

```
┌─────────────────────────────────┐
│           ━━━━                  │  ← 拖动指示器
│                                 │
│  ┌────┐ ┌────┐ ┌────┐ ┌────┐  │
│  │ 🤖 │ │ 📷 │ │ 📸 │ │ 📞 │  │
│  │模型│ │照片│ │拍照│ │语音│  │
│  └────┘ └────┘ └────┘ └────┘  │
│                                 │
│  ┌────┐ ┌────┐ ┌────┐ ┌────┐  │
│  │ 📹 │ │ 🫱 │ │ 🎁 │ │ 📍 │  │
│  │视频│ │戳戳│ │红包│ │位置│  │
│  │通话│ │    │ │    │ │    │  │
│  └────┘ └────┘ └────┘ └────┘  │
│                                 │
└─────────────────────────────────┘
```

### 功能列表

| 功能 | 图标 | 状态 | 说明 |
|-----|------|------|------|
| 选择模型 | 🤖 smart_toy_outlined | ✅ 已实现 | 打开模型选择器 |
| 照片 | 📷 image_outlined | 🚧 开发中 | 从相册选择图片 |
| 拍照 | 📸 camera_alt_outlined | 🚧 开发中 | 调用相机拍照 |
| 语音通话 | 📞 phone_outlined | 🚧 开发中 | 发起语音通话 |
| 视频通话 | 📹 videocam_outlined | 🚧 开发中 | 发起视频通话 |
| 戳一戳 | 🫱 shuffle_outlined | 🚧 开发中 | 发送戳一戳消息 |
| 红包 | 🎁 card_giftcard_outlined | 🚧 开发中 | 发送红包 |
| 位置 | 📍 location_on_outlined | 🚧 开发中 | 发送位置信息 |
| 文件 | 📁 folder_outlined | 🚧 开发中 | 发送文件 |

## 模型选择器

点击功能菜单中的"选择模型"后，会弹出模型选择器：

```
┌─────────────────────────────────┐
│           ━━━━                  │  ← 拖动指示器
│                                 │
│       选择AI模型                │  ← 标题
├─────────────────────────────────┤
│  GPT-4                      ✓   │  ← 当前选中的模型
├─────────────────────────────────┤
│  Claude 3.5 Sonnet              │
├─────────────────────────────────┤
│  Gemini Pro                     │
├─────────────────────────────────┤
│  Llama 3.1                      │
└─────────────────────────────────┘
```

**特性**：
- 显示所有可用模型列表
- 当前选中的模型显示 ✓ 标记
- 点击任意模型立即切换
- 自动关闭弹窗

## 技术实现

### 组件结构

```dart
Composer (ConsumerStatefulWidget)
├─ _ComposerState
│  ├─ _buildPlusButton()        // 加号按钮
│  ├─ TextField                 // 输入框
│  └─ _buildSendButton()        // 发送按钮
│
├─ _ActionsMenu (ConsumerWidget)  // 功能菜单
│  └─ GridView.count (4列)
│     └─ _ActionButton (多个)
│
├─ _ActionButton (StatelessWidget) // 功能按钮
│  ├─ IconButton
│  └─ Text (标签)
│
└─ _ModelSelectorSheet (StatelessWidget) // 模型选择器
   └─ ListView.builder
      └─ ListTile (多个模型)
```

### 关键方法

1. **_showActionsMenu()**: 显示附加功能菜单
   ```dart
   void _showActionsMenu() {
     showModalBottomSheet(
       context: context,
       backgroundColor: Colors.transparent,
       builder: (context) => const _ActionsMenu(),
     );
   }
   ```

2. **_showModelSelector()**: 显示模型选择器
   ```dart
   void _showModelSelector(BuildContext context, WidgetRef ref) {
     // 获取可用模型列表
     // 显示模型选择弹窗
     // 处理模型切换
   }
   ```

3. **_submit()**: 发送消息
   ```dart
   void _submit() {
     final t = _ctrl.text.trim();
     if (t.isEmpty || widget.disabled) return;
     widget.onSend(t);
     _ctrl.clear();
   }
   ```

### 样式设计

#### 尺寸规范
- Composer 高度：56dp
- 加号按钮：42x42dp，圆角8dp
- 发送按钮：42x42dp，圆形
- 输入框：自适应高度（1-4行），padding: 12x8dp
- 功能按钮：56x56dp，圆角8dp

#### 颜色规范
- Composer 背景：`moeSurface` (#F3F6F8)
- 按钮边框：`moeBorder`
- 输入框背景：白色
- 输入框提示文字：`moeMuted`
- 发送按钮：渐变色 (moeHeaderGradientStart -> moeHeaderGradientEnd)

## 用户交互流程

1. 用户点击 [+] 按钮
2. 从底部弹出功能菜单（带拖动指示器）
3. 用户选择功能：
   - **选择模型**：打开模型选择器 → 选择模型 → 自动关闭
   - **其他功能**：显示"功能开发中"提示（临时）
4. 点击菜单外部区域，关闭菜单

## 优势总结

### 用户体验
- ✅ 界面更简洁，不会被压缩
- ✅ 功能分级组织，主要功能（输入和发送）在一级
- ✅ 附加功能易于访问和扩展
- ✅ 符合现代 IM 应用的设计模式

### 开发维护
- ✅ 组件职责明确，易于维护
- ✅ 新增功能只需在 GridView 中添加按钮
- ✅ 使用 Riverpod 管理模型选择状态
- ✅ 使用 Material Design 的 BottomSheet 组件

### 性能
- ✅ 按需加载功能菜单
- ✅ 使用 showModalBottomSheet，自动处理动画和手势
- ✅ 避免在主界面渲染过多组件

## 后续开发建议

1. **实现功能按钮**
   - 照片选择：使用 `image_picker` 包
   - 拍照：使用 `camera` 包
   - 文件上传：使用 `file_picker` 包
   - 位置分享：使用 `geolocator` + `google_maps_flutter`

2. **增强模型选择器**
   - 添加模型描述和参数信息
   - 支持收藏和最近使用的模型
   - 添加模型搜索功能

3. **优化交互**
   - 添加长按功能按钮显示提示
   - 支持拖动调整菜单高度
   - 添加功能按钮的快捷键支持（桌面端）

4. **国际化**
   - 将所有文本提取到 l10n 文件
   - 支持多语言切换

## 相关文件

- `lib/src/features/chat/presentation/widgets/composer.dart` - Composer 组件实现
- `lib/src/core/theme/tokens.dart` - 主题颜色和尺寸常量
- `lib/src/features/settings/app_settings.dart` - 应用设置（模型管理）
- `界面布局图.md` - 界面布局文档
- `前端说明.md` - 前端开发说明

## 更新历史

| 日期 | 版本 | 更新内容 |
|------|------|----------|
| 2025-11-06 | v2.0 | 重新设计 Composer UI，添加功能菜单和模型选择器 |
| 之前 | v1.0 | 初始实现：模型选择 + 输入框 + 图片按钮 + 发送按钮 |
