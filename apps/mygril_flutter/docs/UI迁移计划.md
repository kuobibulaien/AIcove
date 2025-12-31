# UI 层迁移计划

> 更新日期：2025-12-31
> 状态：第一、二阶段已完成 ✅  
> 提交：已推送到 GitHub (commit: 338fa6c)

---

## 🎯 项目背景

MyGril Flutter 项目架构重构，目标是将前后端分离，建立清晰的目录结构。参考 Kelivo 项目的分层模式，采用 `core/`（后端）+ `ui/`（前端）的二层架构。

### 核心原则
- **core/** = 后端（models + providers + services），不包含 UI
- **ui/** = 前端（theme + shared + features），所有 UI 相关
- **前后端完全分离**

---

## ✅ 已完成工作（重构一阶段）

### 1. 主题迁移 ✅
**路径变更：**
```
core/theme/ → ui/theme/
├── tokens.dart
├── skin_config.dart
├── skin_provider.dart
└── skins/moetalk_skin.dart
```

**影响文件：** 46 个文件的 import 路径已更新

**方法：** 使用 Dart 脚本 `tool/migrate_structure.dart` 安全迁移

---

### 2. 公共组件迁移 ✅
**路径变更：**
```
core/widgets/ → ui/shared/
├── widgets/          # UI 组件
│   ├── moe_app_bar.dart
│   ├── moe_toast.dart
│   ├── meotalk_dialog.dart
│   ├── image_crop_dialog.dart
│   ├── settings_drawer_panel.dart
│   └── settings_drawer_wrapper.dart
│
├── effects/          # 视觉效果
│   ├── frosted_glass_card.dart
│   ├── gradient_blur_card.dart
│   ├── smooth_clip.dart
│   └── role_background_hero.dart
│
└── animations/       # 动画
    ├── expanding_page_route.dart
    └── parallax_slide_page_route.dart
```

**影响文件：** 18 个文件的 import 路径已更新

**方法：** 使用 Dart 脚本 `tool/migrate_widgets.dart` + `tool/fix_imports.dart`

---

### 3. 修复编译问题 ✅

#### 问题 1：BlurredBackgroundCache 类缺失
**现象：** 代码引用了 `BlurredBackgroundCache` 类，但实际文件只有 `BlurredBackgroundUtils`

**解决：** 在 `core/utils/blurred_background_cache.dart` 添加了空壳类
```dart
class BlurredBackgroundCache {
  static final ValueNotifier<int> ticker = ValueNotifier(0);
  static (ImageProvider, bool) getOrFallback(...) { ... }
  static Future<ImageProvider?> getBlurredFuture(...) async { ... }
  static void warm(...) { ... }
}
```

**文件：** `lib/src/core/utils/blurred_background_cache.dart` (新增 45 行)

---

#### 问题 2：Conversation 缺少 blurredBackground 字段
**现象：** 数据库转换器引用了 `conversation.blurredBackground`，但实体类没有这个字段

**解决：** 给 `Conversation` 添加字段
```dart
final String? blurredBackground; // 模糊背景图（base64）
```

**文件：** `lib/src/features/chat/domain/conversation.dart` (新增 3 处)

---

#### 问题 3：isDark 变量未定义
**现象：** `character_detail_page.dart` 使用了 `isDark` 但没有定义

**解决：** 添加变量定义
```dart
Builder(builder: (context) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return Container(...);
})
```

**文件：** `lib/src/features/chat/presentation/pages/character_detail_page.dart`

---

### 4. 验证结果 ✅
- **Flutter analyze:** 0 error（10 个 error → 0）
- **Flutter run:** 成功运行在设备 2211133C
- **Git commit:** 338fa6c "重构一阶段"
- **GitHub:** 已推送到 main 分支

---

## 📋 待完成工作（重构二阶段）

### 页面分组迁移（24 个文件）

#### 迁移顺序（按风险从低到高）

| 顺序 | 模块 | 文件数 | 风险 |
|------|------|--------|------|
| 1 | auto_reply | 2 | ⭐ 低 |
| 2 | plugins | 5 | ⭐ 低 |
| 3 | settings | 9 | ⭐⭐ 中 |
| 4 | character | 4 | ⭐⭐ 中 |
| 5 | chat | 2 | ⭐⭐⭐ 高 |
| 6 | home | 2 | ⭐⭐⭐ 高 |

#### 详细文件清单

**1. auto_reply/pages/ (2 个文件)**
```
chat/presentation/pages/auto_reply_settings_page.dart
  → ui/features/auto_reply/pages/auto_reply_settings_page.dart

chat/presentation/pages/auto_reply_trigger_list_page.dart
  → ui/features/auto_reply/pages/auto_reply_trigger_list_page.dart
```

**2. plugins/pages/ (5 个文件)**
```
chat/presentation/pages/plugin_settings_page.dart
chat/presentation/pages/tts_plugin_detail_page.dart
chat/presentation/pages/tts_tool_detail_page.dart
chat/presentation/pages/memory_plugin_detail_page.dart
chat/presentation/pages/sticker_settings_page.dart
  → ui/features/plugins/pages/
```

**3. settings/pages/ (9 个文件)**
```
chat/presentation/pages/settings_page.dart
chat/presentation/pages/ui_settings_page.dart
chat/presentation/pages/model_list_page.dart
chat/presentation/pages/provider_selector_page.dart
chat/presentation/pages/import_model_dialog.dart
chat/presentation/pages/message_format_settings_page.dart
chat/presentation/pages/chunk_settings_page.dart
chat/presentation/pages/log_viewer_page.dart
chat/presentation/pages/profile_page.dart
  → ui/features/settings/pages/
```

**4. character/pages/ (4 个文件)**
```
chat/presentation/pages/role_card_page.dart
chat/presentation/pages/character_detail_page.dart
chat/presentation/pages/contact_edit_page.dart
chat/presentation/pages/favorites_page.dart
  → ui/features/character/pages/
```

**5. chat/pages/ (2 个文件)**
```
chat/presentation/pages/chat_page.dart
chat/presentation/pages/split_chat_page.dart
  → ui/features/chat/pages/
```

**6. home/pages/ (2 个文件)**
```
chat/presentation/pages/main_page.dart
chat/presentation/pages/contacts_page.dart
  → ui/features/home/pages/
```

---

## 🛠️ 迁移工具脚本

已创建的工具（在 `tool/` 目录下）：

1. **migrate_structure.dart** - 主题迁移脚本（已用）
2. **migrate_widgets.dart** - 组件迁移脚本（已用）
3. **fix_imports.dart** - import 路径修复脚本（已用）
4. **analyze_errors.dart** - 错误分析脚本

**使用方法：**
```bash
# 运行迁移脚本
dart run tool/[script_name].dart

# 验证编译
flutter analyze

# 验证运行
flutter run --device-id 2211133C
```

---

## ⚠️ 重要注意事项

### 1. PowerShell 编码问题
**问题：** PowerShell 的 `Set-Content` 会破坏 UTF-8 编码的中文文件

**解决：** 必须使用 Dart 脚本进行文件操作，不要用 PowerShell 批量替换

### 2. 迁移前已存在的问题
以下问题在迁移前就存在，已修复但需注意：
- `BlurredBackgroundCache` 未实现（已添加空壳类）
- `Conversation.blurredBackground` 缺失（已添加）
- `isDark` 变量未定义（已修复）

### 3. 依赖关系
迁移时需注意文件之间的引用关系：
- `settings_drawer_panel.dart` 引用 `settings_page.dart`
- `role_card_page.dart` 引用 `character_detail_page.dart`
- 需先迁移被依赖的文件

### 4. app.dart 路由更新
迁移页面后必须更新 `lib/src/app.dart` 中的 import 路径

### 5. 验证步骤
每次迁移后必须：
1. 运行 `flutter analyze`（确保 0 error）
2. 运行 `flutter run`（确保功能正常）
3. 提交 git

---

## 📁 当前目录结构

```
lib/src/
├── core/                              # 后端
│   ├── api/
│   ├── database/
│   ├── models/
│   ├── sync/
│   └── utils/
│
├── features/                          # 业务逻辑
│   ├── chat/
│   │   ├── domain/
│   │   ├── data/
│   │   ├── providers/
│   │   └── presentation/
│   │       ├── pages/                 # 待迁移 ⚠️
│   │       └── widgets/               # 待迁移 ⚠️
│   ├── settings/
│   ├── plugins/
│   └── ...
│
└── ui/                                # 前端
    ├── theme/                         # ✅ 已完成
    │   ├── tokens.dart
    │   ├── skin_config.dart
    │   ├── skin_provider.dart
    │   └── skins/
    │
    ├── shared/                        # ✅ 已完成
    │   ├── widgets/
    │   ├── effects/
    │   └── animations/
    │
    └── features/                      # ⚠️ 待创建
        ├── home/pages/
        ├── chat/pages/
        ├── character/pages/
        ├── settings/pages/
        ├── auto_reply/pages/
        └── plugins/pages/
```

---

## 📊 工作量估算

| 阶段 | 状态 | 文件数 | 耗时 |
|------|------|--------|------|
| ✅ 一阶段：theme + widgets | 已完成 | ~20 | 1h |
| ⚠️ 二阶段：页面分组 | 待执行 | 24 | ~2h |
| 📅 三阶段：组件整理 | 待规划 | ~12 | ~1h |

---

## 🔧 调试信息

### 当前编译状态
- **Errors:** 0
- **Warnings:** 多个（主要是 deprecated API 警告）
- **设备:** 2211133C (Android)
- **Flutter:** 使用中国镜像 https://storage.flutter-io.cn

### Git 状态
- **分支:** main
- **最新提交:** 338fa6c "重构一阶段"
- **远程:** https://github.com/kuobibulaien/AIcove.git
- **状态:** 已推送，工作区干净

---

## 💡 下一步行动建议

### 立即可执行
1. 从 `auto_reply` 模块开始迁移（风险最低）
2. 创建迁移脚本 `tool/migrate_auto_reply.dart`
3. 执行迁移并验证

### 脚本模板
```dart
// tool/migrate_auto_reply.dart
void main() async {
  final moves = {
    'lib/src/features/chat/presentation/pages/auto_reply_settings_page.dart':
        'lib/src/ui/features/auto_reply/pages/auto_reply_settings_page.dart',
    // ...
  };
  
  // 1. 创建目标目录
  // 2. 复制文件
  // 3. 更新 import
  // 4. 删除源文件
  // 5. 验证
}
```

---

## 📞 交接清单

### 已提供
- ✅ 完整的迁移计划文档
- ✅ 已完成阶段的总结
- ✅ 待完成工作的详细清单
- ✅ 迁移工具脚本
- ✅ 注意事项和常见问题

### 需要了解
- 📖 参考 Kelivo 项目的架构（`参考素材/kelivo-master/`）
- 📖 查看已创建的调研文档（`docs/学习笔记/kelivo架构分析.md`）
- 📖 遵循用户规范（`GEMINI.md` 中的最高优先级规范）

### 关键文件位置
- **迁移计划:** `apps/mygril_flutter/docs/UI迁移计划.md`
- **架构方案:** `apps/mygril_flutter/docs/架构重构方案.md`
- **迁移工具:** `apps/mygril_flutter/tool/*.dart`
- **用户规范:** `GEMINI.md`

---

**准备就绪，可以开始二阶段迁移！** 🚀
