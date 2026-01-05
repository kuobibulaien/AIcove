# 上下文交接文档 - UI大文件拆分

> 创建日期：2025-12-31
> 用途：供新的 AI 上下文快速了解项目状态和待办任务

---

## 🎯 当前任务

**继续拆分超过 500 行的 UI 文件**

---

## 📊 待拆分文件清单（按优先级排序）

### 高优先级（Flutter 前端）

| 文件 | 行数 | 路径 | 状态 |
|------|------|------|------|
| `model_list_page.dart` | ~~1096~~ → **220** | `ui/features/settings/pages/` | ✅ 已完成 |
| `tts_plugin_detail_page.dart` | ~~704~~ → **~120** | `ui/features/plugins/pages/` | ✅ 已完成 |
| `auto_reply_settings_page.dart` | ~~695~~ → **~280** | `ui/features/auto_reply/pages/` | ✅ 已完成 |

### 低优先级

| 文件 | 行数 | 路径 | 状态 |
|------|------|------|------|
| `import_model_dialog.dart` | ~~538~~ → **~280** | `ui/features/settings/pages/` | ✅ 已完成 |
| `role_card_page.dart` | ~~511~~ → **~180** | `ui/features/character/pages/` | ✅ 已完成 |

### 不要修改

| 文件 | 行数 | 原因 |
|------|------|------|
| `database.g.dart` | 7301 | ⚠️ 自动生成的文件 |

---

## ✅ 已完成的拆分（可参考）

### `chat_actions.dart` 拆分案例（1690行 → 292行）

**拆分策略：门面模式 + 服务层**

```
chat_actions.dart (292行) - 门面类，只做协调
├── services/
│   ├── chat_send_service.dart (488行) - 发送核心逻辑
│   ├── chat_tts_handler.dart (237行) - TTS 处理
│   ├── chat_message_processor.dart (158行) - 消息处理
│   ├── chat_types.dart (65行) - 公共数据类型
│   └── chat_request_executor.dart (277行) - 请求执行器
└── chat_providers.dart (35行) - 全局 Provider
```

**关键技术点：**
1. 门面类只保留公开 API，内部委托给服务
2. 使用 `export` 保持向后兼容
3. 服务之间通过 Riverpod Provider 互相访问

---

## 🏗️ 项目架构

```
lib/src/
├── core/           # 核心工具（API、数据库、日志）
├── features/       # 业务逻辑层
│   ├── chat/
│   │   ├── services/   # 🆕 服务层（本次新增）
│   │   ├── data/
│   │   ├── domain/
│   │   └── presentation/widgets/
│   └── settings/
└── ui/             # UI 展示层
    ├── theme/
    ├── shared/     # 公共组件（Moe系列）
    └── features/   # 页面
        ├── chat/pages/
        ├── settings/pages/
        └── ...
```

---

## 📝 公共组件库（可复用）

> 📖 完整文档：[前端公共组件库.md](../前端公共组件库.md)  
> 📖 后端服务：[后端公共服务库.md](../后端公共服务库.md)

位置：`lib/src/ui/shared/widgets/`

| 组件 | 用途 |
|------|------|
| `MoePrimaryButton` | 主按钮 |
| `MoeSecondaryButton` | 次级按钮 |
| `MoeIconButton` | 图标按钮 |
| `MoeTextField` | 输入框 |
| `MoeSwitch` | 开关 |
| `MoeSettingsGroup` | 设置分组卡片 |
| `MoeSettingsRow` | 设置行 |
| `MoeLoadingIndicator` | 加载指示器 |
| `MoeEmptyState` | 空状态占位 |
| `MoeActionSheet` | iOS 风格操作菜单 (NEW) |
| `MoeBottomSheet` | 通用底部弹窗 (NEW) |
| `MoeFilterChipBar` | 筛选标签栏 (NEW) |

导入方式：
```dart
import 'package:mygril_flutter/src/ui/shared/widgets/index.dart';
```

---

## 🛠️ 开发规范

### 拆分原则

1. **保持 API 稳定** - 拆分后外部调用方式不变
2. **按职责分组** - 一个服务文件只做一件事
3. **避免循环依赖** - 注意 import 方向
4. **先拆后测** - 每次拆分后运行 `flutter analyze`

### 命名规范

```
服务文件：xxx_service.dart 或 xxx_handler.dart
页面文件：xxx_page.dart
组件文件：xxx_widget.dart
类型文件：xxx_types.dart
```

### 验证命令

```powershell
# 单文件分析
dart analyze lib/src/ui/features/settings/pages/model_list_page.dart

# 全项目分析
flutter analyze

# 运行应用
flutter run
```

---

## ⚠️ 注意事项

1. **PowerShell 不支持 `&&`** - 使用分号或分行执行命令
2. **相关文档位置** - `apps/mygril_flutter/docs/UI重构完整交付报告_20251231.md`
3. **项目 README** - `c:\ide\mygril\readme.md`（工作前必须阅读）

---

## 📞 快速开始

```powershell
cd c:\ide\mygril\apps\mygril_flutter

# 查看待拆分文件
Get-ChildItem -Path "lib" -Filter "*.dart" -Recurse | ForEach-Object { $lines = (Get-Content $_.FullName | Measure-Object -Line).Lines; if ($lines -gt 500) { Write-Host "$lines`t$($_.Name)" } }

# 开始拆分 model_list_page.dart
code lib\src\ui\features\settings\pages\model_list_page.dart
```

---

*本文档用于 AI 上下文交接，确保连续性开发。*
