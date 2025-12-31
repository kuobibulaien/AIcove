# UI 层迁移计划

> 更新日期：2025-12-31
> 状态：第一、二阶段已完成，第三阶段待执行

---

## 📋 已完成的工作

### ✅ 第一阶段：主题迁移
- `core/theme/` → `ui/theme/`
- 更新了 46 个文件的 import 路径

### ✅ 第二阶段：公共组件迁移
- `core/widgets/` → `ui/shared/`
- 分类到 widgets/、effects/、animations/ 三个子目录

---

## 📋 第三阶段：页面分组迁移

### 目标结构
```
lib/src/
├── core/                          # 后端（保持不变）
│   ├── models/
│   ├── providers/
│   └── services/
│
└── ui/                            # 前端
    ├── theme/                     # ✅ 已完成
    ├── shared/                    # ✅ 已完成
    │   ├── widgets/
    │   ├── effects/
    │   └── animations/
    │
    └── features/                  # 待迁移
        ├── home/pages/
        ├── chat/pages/
        ├── character/pages/
        ├── settings/pages/
        ├── auto_reply/pages/
        └── plugins/pages/
```

### 详细分组

#### 1. home/pages/ - 主框架（2 个文件）
| 当前路径 | 目标路径 |
|----------|----------|
| `chat/presentation/pages/main_page.dart` | `ui/features/home/pages/main_page.dart` |
| `chat/presentation/pages/contacts_page.dart` | `ui/features/home/pages/contacts_page.dart` |

#### 2. chat/pages/ - 聊天功能（2 个文件）
| 当前路径 | 目标路径 |
|----------|----------|
| `chat/presentation/pages/chat_page.dart` | `ui/features/chat/pages/chat_page.dart` |
| `chat/presentation/pages/split_chat_page.dart` | `ui/features/chat/pages/split_chat_page.dart` |

#### 3. character/pages/ - 角色管理（4 个文件）
| 当前路径 | 目标路径 |
|----------|----------|
| `chat/presentation/pages/role_card_page.dart` | `ui/features/character/pages/role_card_page.dart` |
| `chat/presentation/pages/character_detail_page.dart` | `ui/features/character/pages/character_detail_page.dart` |
| `chat/presentation/pages/contact_edit_page.dart` | `ui/features/character/pages/contact_edit_page.dart` |
| `chat/presentation/pages/favorites_page.dart` | `ui/features/character/pages/favorites_page.dart` |

#### 4. settings/pages/ - 应用设置（9 个文件）
| 当前路径 | 目标路径 |
|----------|----------|
| `chat/presentation/pages/settings_page.dart` | `ui/features/settings/pages/settings_page.dart` |
| `chat/presentation/pages/ui_settings_page.dart` | `ui/features/settings/pages/ui_settings_page.dart` |
| `chat/presentation/pages/model_list_page.dart` | `ui/features/settings/pages/model_list_page.dart` |
| `chat/presentation/pages/provider_selector_page.dart` | `ui/features/settings/pages/provider_selector_page.dart` |
| `chat/presentation/pages/import_model_dialog.dart` | `ui/features/settings/pages/import_model_dialog.dart` |
| `chat/presentation/pages/message_format_settings_page.dart` | `ui/features/settings/pages/message_format_settings_page.dart` |
| `chat/presentation/pages/chunk_settings_page.dart` | `ui/features/settings/pages/chunk_settings_page.dart` |
| `chat/presentation/pages/log_viewer_page.dart` | `ui/features/settings/pages/log_viewer_page.dart` |
| `chat/presentation/pages/profile_page.dart` | `ui/features/settings/pages/profile_page.dart` |

#### 5. auto_reply/pages/ - 主动消息（2 个文件）
| 当前路径 | 目标路径 |
|----------|----------|
| `chat/presentation/pages/auto_reply_settings_page.dart` | `ui/features/auto_reply/pages/auto_reply_settings_page.dart` |
| `chat/presentation/pages/auto_reply_trigger_list_page.dart` | `ui/features/auto_reply/pages/auto_reply_trigger_list_page.dart` |

#### 6. plugins/pages/ - 插件管理（5 个文件）
| 当前路径 | 目标路径 |
|----------|----------|
| `chat/presentation/pages/plugin_settings_page.dart` | `ui/features/plugins/pages/plugin_settings_page.dart` |
| `chat/presentation/pages/tts_plugin_detail_page.dart` | `ui/features/plugins/pages/tts_plugin_detail_page.dart` |
| `chat/presentation/pages/tts_tool_detail_page.dart` | `ui/features/plugins/pages/tts_tool_detail_page.dart` |
| `chat/presentation/pages/memory_plugin_detail_page.dart` | `ui/features/plugins/pages/memory_plugin_detail_page.dart` |
| `chat/presentation/pages/sticker_settings_page.dart` | `ui/features/plugins/pages/sticker_settings_page.dart` |

---

## 📋 第四阶段：组件分类整理

### 公共组件（移到 ui/shared/widgets/）
| 组件 | 原因 |
|------|------|
| `character_list_item.dart` | 被联系人列表、收藏页等多处使用 |
| `audio_player_widget.dart` | 通用音频播放组件 |
| `common_app_bar.dart` | 通用导航栏 |

### 功能专用组件（随页面迁移）

#### home/widgets/
| 组件 | 说明 |
|------|------|
| `contacts_list_content.dart` | 联系人列表内容 |
| `contacts_sub_header.dart` | 联系人次级标题 |
| `custom_bottom_nav.dart` | 底部导航栏 |

#### chat/widgets/
| 组件 | 说明 |
|------|------|
| `message_bubble.dart` | 消息气泡 |
| `composer.dart` | 输入框 |
| `chat_settings_dialog.dart` | 聊天设置弹窗 |

#### character/widgets/
| 组件 | 说明 |
|------|------|
| `profile_content.dart` | 个人资料内容 |
| `contact_edit_dialog.dart` | 角色编辑弹窗 |

#### auto_reply/widgets/
| 组件 | 说明 |
|------|------|
| `auto_reply_trigger_form.dart` | 触发器表单 |

### 待删除（未使用）
| 组件 | 原因 |
|------|------|
| `sidebar.dart` | 0 次引用 |
| `character_display.dart` | 0 次引用 |
| `composer.dart.bak` | 备份文件 |
| `model_list_page.dart.backup` | 备份文件 |

---

## 📋 执行计划

### 迁移顺序（风险从低到高）

| 顺序 | 模块 | 文件数 | 依赖关系 | 风险 |
|------|------|--------|----------|------|
| 1 | auto_reply | 2 | 独立性高 | ⭐ 低 |
| 2 | plugins | 5 | 独立性高 | ⭐ 低 |
| 3 | settings | 9 | 被 home 引用 | ⭐⭐ 中 |
| 4 | character | 4 | 被 chat 引用 | ⭐⭐ 中 |
| 5 | chat | 2 | 核心功能 | ⭐⭐⭐ 高 |
| 6 | home | 2 | 主入口 | ⭐⭐⭐ 高 |

### 每个模块的迁移步骤

```
1. 创建目标目录
2. 复制文件到新位置
3. 更新文件内部的相对 import 路径
4. 更新其他文件对该模块的引用
5. 删除原文件
6. 运行 flutter analyze 验证
7. 运行 flutter run 验证功能
8. 提交 git
```

### 迁移脚本模板

每个模块使用 Dart 脚本迁移，避免手工操作出错：

```dart
// tool/migrate_[module].dart

void main() async {
  // 1. 定义移动映射
  final moves = {
    'lib/src/features/chat/presentation/pages/xxx.dart': 
        'lib/src/ui/features/[module]/pages/xxx.dart',
  };
  
  // 2. 定义 import 替换规则
  final replacements = {
    'old/path': 'new/path',
  };
  
  // 3. 执行移动
  // 4. 执行全局替换
  // 5. 验证
}
```

---

## 📊 工作量估算

| 阶段 | 文件数 | 预计时间 |
|------|--------|----------|
| auto_reply 迁移 | 2+1 | 10 分钟 |
| plugins 迁移 | 5 | 15 分钟 |
| settings 迁移 | 9 | 25 分钟 |
| character 迁移 | 4+2 | 20 分钟 |
| chat 迁移 | 2+3 | 20 分钟 |
| home 迁移 | 2+3 | 20 分钟 |
| 清理未使用组件 | 4 | 5 分钟 |
| **总计** | **~38** | **~2 小时** |

---

## ⚠️ 注意事项

1. **app.dart 路由更新**  
   迁移 pages 后需要更新 `app.dart` 中的 import 路径

2. **跨模块引用**  
   - `settings_page` 被 `settings_drawer_panel` 引用
   - `character_detail_page` 被 `role_card_page` 引用
   - 需要先迁移被依赖的模块

3. **Provider 位置**  
   目前 providers 在 `features/chat/` 下，暂不迁移，保持功能可用

4. **测试验证**  
   每迁移一个模块后必须运行 `flutter run` 验证功能正常

---

## 📁 最终目录结构预览

```
lib/src/
├── core/                              # 后端
│   ├── api/
│   ├── database/
│   ├── models/
│   ├── sync/
│   └── utils/
│
├── features/                          # 业务逻辑（保留）
│   ├── chat/
│   │   ├── domain/                    # 实体
│   │   ├── data/                      # 数据层
│   │   └── providers/                 # 状态管理
│   ├── settings/
│   ├── plugins/
│   └── ...
│
└── ui/                                # 前端
    ├── theme/                         # ✅ 主题
    ├── shared/                        # ✅ 公共组件
    │   ├── widgets/
    │   ├── effects/
    │   └── animations/
    │
    └── features/                      # 功能页面
        ├── home/
        │   └── pages/
        ├── chat/
        │   ├── pages/
        │   └── widgets/
        ├── character/
        │   ├── pages/
        │   └── widgets/
        ├── settings/
        │   └── pages/
        ├── auto_reply/
        │   ├── pages/
        │   └── widgets/
        └── plugins/
            └── pages/
```

---

**需要开始执行时，请告诉我从哪个模块开始！**
