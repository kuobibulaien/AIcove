# Kelivo 项目架构分析

> 这是一份面向"AI辅助编程者"的学习文档，帮助你理解成熟 Flutter 项目的架构设计。

---

## 📋 项目概览

**Kelivo** 是一个跨平台的 LLM 聊天客户端，支持 Android/iOS/Windows/macOS/Linux。

| 项目属性 | 内容 |
|---------|------|
| 类型 | AI 聊天客户端 |
| 技术栈 | Flutter + Riverpod (状态管理) + Hive (本地存储) |
| 功能 | 多模态输入、TTS语音、MCP工具调用、网络搜索 |

这个项目和你的 MyGril 非常相似，所以它的架构非常值得学习！

---

## 🏗️ 目录结构对比

### Kelivo 的结构 (简洁清晰)

```
lib/
├── main.dart                 # 程序入口
├── core/                     # 核心层（全局共享）
│   ├── models/               # 📋 数据模型定义
│   ├── providers/            # 🔄 状态管理 (Riverpod)
│   └── services/             # ⚙️ 业务服务
├── features/                 # 功能模块层
│   ├── chat/                 # 聊天功能
│   ├── assistant/            # 助手管理
│   ├── settings/             # 设置页面
│   ├── backup/               # 备份功能
│   └── ...                   # 其他功能
├── shared/                   # 共享 UI 层
│   ├── widgets/              # 公共组件
│   ├── pages/                # 公共页面
│   ├── animations/           # 动画
│   └── responsive/           # 响应式布局
├── theme/                    # 主题系统
│   ├── design_tokens.dart    # 设计令牌
│   ├── palettes.dart         # 调色板
│   └── theme_factory.dart    # 主题工厂
└── utils/                    # 工具函数
```

### 你目前的结构问题

```
lib/src/
├── core/                     # ✅ 有了！但内部可能不清晰
│   ├── theme/                # ✅ 主题
│   ├── widgets/              # ✅ 公共组件
│   ├── models/               # ✅ 数据模型
│   └── utils/                # ✅ 工具
└── features/
    └── chat/                 # ⚠️ 功能模块，但可能太大
        ├── domain/           # ❓ 模型在这还是在 core/models？
        ├── data/             # ❓ 服务在这还是在 core/services？
        └── presentation/     # ✅ UI 层
```

**问题**：你的结构比 Kelivo 多了一层 `domain/data/presentation`，这种 Clean Architecture 分层虽然更"学院派"，但对于小团队/AI编程来说可能**过度复杂**。

---

## 🧩 核心概念对照表

### 1️⃣ 数据模型 (Models)

| Kelivo | 你的项目 | 说明 |
|--------|---------|------|
| `core/models/conversation.dart` | `core/models/conversation.dart` | 对话模型 |
| `core/models/chat_message.dart` | `features/chat/domain/...` | 消息模型 |

**Kelivo 的做法**：
- 所有模型统一放在 `core/models/`
- 使用 Hive 进行本地持久化（`@HiveType`、`@HiveField`）
- 每个模型都有 `toJson()` 和 `fromJson()` 方法

**示例**：
```dart
@HiveType(typeId: 0)
class ChatMessage extends HiveObject {
  @HiveField(0)
  final String id;
  
  @HiveField(1)
  final String role; // 'user' or 'assistant'
  
  @HiveField(2)
  final String content;
  
  // ... 其他字段
  
  // 必须有的方法
  Map<String, dynamic> toJson() { ... }
  factory ChatMessage.fromJson(Map<String, dynamic> json) { ... }
  ChatMessage copyWith({ ... }) { ... }
}
```

**学习要点**：
- ✅ 模型放 `core/models/`，不要分散到各个 feature
- ✅ 每个模型写 `toJson()`、`fromJson()`、`copyWith()` 三件套
- ✅ 使用 Hive 注解实现本地存储

---

### 2️⃣ 状态管理 (Providers)

| Kelivo | 你的项目 | 说明 |
|--------|---------|------|
| `core/providers/chat_provider.dart` | `features/chat/presentation/providers/...` | 聊天状态 |
| `core/providers/settings_provider.dart` | 可能分散 | 设置状态 |

**Kelivo 的做法**：
- **全局 Provider 放 `core/providers/`**
- Provider 负责：调用 Service → 更新状态 → 通知 UI

**学习要点**：
- ✅ Provider 是"状态管理中心"，不直接写业务逻辑
- ✅ 复杂的业务逻辑放 Service，Provider 只是调用者

---

### 3️⃣ 服务层 (Services)

**Kelivo 的 `core/services/` 结构**：
```
services/
├── api/                 # API 调用相关
├── chat/                # 聊天核心逻辑
├── mcp/                 # MCP 工具集成
├── search/              # 搜索服务
├── storage/             # 存储服务
├── tts/                 # 语音合成
└── network/             # 网络相关
```

**学习要点**：
- ✅ Service 按"职能"分类，不是按"功能模块"分类
- ✅ `chat/` 服务处理所有聊天相关的复杂逻辑
- ✅ 一个 Service 可以被多个 Feature 调用

---

### 4️⃣ 功能模块 (Features)

**Kelivo 的 Feature 结构很简单**：
```
features/chat/
├── models/              # (可选) 该功能专用的模型
├── pages/               # 页面
└── widgets/             # 该功能专用的组件
```

**注意**：Kelivo 的 Feature 里**没有** `domain/` 和 `data/`！

| 层级 | Kelivo 放哪 | 你可能放哪 |
|------|------------|-----------|
| 模型 | `core/models/` | `features/xxx/domain/models/` |
| 服务 | `core/services/` | `features/xxx/data/services/` |
| UI | `features/xxx/pages/widgets/` | `features/xxx/presentation/` |

**结论**：Kelivo 选择了更扁平的结构，你可以考虑采用。

---

### 5️⃣ 共享组件 (Shared Widgets)

**Kelivo 的 `shared/widgets/` 包含**：
- `snackbar.dart` - 全局提示框（类似你的 MoeToast）
- `emoji_picker_dialog.dart` - 表情选择器
- `ios_switch.dart` / `ios_checkbox.dart` - iOS 风格控件
- `markdown_with_highlight.dart` - Markdown 渲染

**学习要点**：
- ✅ 可复用的 UI 组件统一放这里
- ✅ 按功能命名，一看就知道干什么

---

### 6️⃣ 主题系统 (Theme)

**Kelivo 的 `theme/` 结构**：
```dart
// design_tokens.dart - 设计令牌
class AppColors {
  static const Color textMuted = Colors.black54;
}

class AppSpacing {
  static const double xxs = 4;
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 20;
}

class AppRadii {
  static const double capsule = 28;
}
```

**学习要点**：
- ✅ 所有设计值（颜色、间距、圆角）用常量定义
- ✅ 代码里不写 `16.0`，而是写 `AppSpacing.md`
- ✅ 需要改设计时，只改一个文件

---

## 🎯 你的学习行动计划

### 第一阶段：理解现状（今天）

1. **浏览 Kelivo 目录结构** - 在文件浏览器里点开每个目录，对照本文档理解
2. **打开 3 个关键文件细读**：
   - `core/models/conversation.dart` - 看模型怎么写
   - `theme/design_tokens.dart` - 看设计令牌怎么定义
   - `features/settings/pages/settings_page.dart` - 看页面怎么组织

### 第二阶段：对比分析（明天）

1. 打开你项目的 `core/models/` 和 Kelivo 的对比
2. 列出你项目中"放错位置"的文件
3. 画一张"理想结构图"

### 第三阶段：重构规划（后天）

在你理解了架构后，我们可以一起：
1. 定义你项目的"新目录结构规范"
2. 制定重构步骤（先移动文件，再改导入）
3. 逐步迁移，每次只动一个模块

---

## ⚠️ 重要提醒

### Kelivo 的问题

虽然 Kelivo 架构清晰，但也有需要注意的地方：

1. **Provider 文件太大**：`settings_provider.dart` 有 **106KB**，这已经是屎山了
2. **Widget 文件太大**：`chat_message_widget.dart` 有 **113KB**，应该拆分
3. **没有严格的 Clean Architecture**：它选择了更实用的扁平结构

### 你的选择

| 方案 | 适合场景 | 复杂度 |
|------|---------|--------|
| **Kelivo 风格** | 快速开发、小团队、AI编程 | ⭐⭐ |
| **Clean Architecture** | 大团队、需要测试、长期维护 | ⭐⭐⭐⭐ |

**建议**：你可以采用 **Kelivo 风格 + 合理拆分**，不需要严格的 domain/data/presentation 三层。

---

## 📝 下一步

当你看完这份文档后，可以告诉我：

1. **"我想按照 Kelivo 风格重构"** - 我会帮你制定详细的迁移计划
2. **"我想继续深入学习 Kelivo 的某个模块"** - 我会详细分析那个模块
3. **"我想对比我项目的某个功能和 Kelivo"** - 我会做对比分析

学习加油！🚀
