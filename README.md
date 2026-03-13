# AIcove - AI 心理陪伴助手

> 面向医院场景的心理医疗辅助 App，让 AI 像真实伴侣一样陪伴抑郁症患者。

## 项目简介

AIcove 是一个跨平台（Android / iOS / Windows / Web）AI 对话客户端，核心思路是让 AI 通过工具调用生成多模态消息（文本、语音、图片、表情包），并能主动触发关怀消息，模拟真实异地伴侣的沟通体验。
曾用名mygril，可能有部分路径残留。
**架构特点：** 所有 AI 对话逻辑在 Flutter 客户端完成；后端以认证、数据同步为主，提供备份、云触发器、云记忆、额度管理等云端能力。

## 核心功能

| 功能 | 说明 |
|------|------|
| AI 对话 | 多轮对话，支持流式输出，角色人设可自定义 |
| 多模态消息 | 文本、TTS 语音、AI 绘图、表情包，拆分顺序交付 |
| 插件系统 | 语音（硅基流动/阿里云/MiniMax）、绘图、表情包等可插拔插件 |
| 主动关怀 | 云触发器驱动，AI 能像真人一样主动发消息 |
| 记忆系统 | 本地 + 云端记忆存储与召回，让 AI 记住用户 |
| 云同步 | 增量同步 v2（Scope/回收站），多设备数据一致 |
| 数据备份 | 云端备份/恢复，离线导入导出 |
| 皮肤主题 | 可切换的 UI 皮肤系统 |
| 角色卡 | 多角色管理，自定义 AI 人设 |

## 技术栈

**前端（Flutter）**
- Flutter（建议 3.22+）/ Dart >= 3.3.0
- Riverpod（状态管理）
- GoRouter（路由）
- Drift（本地 SQLite ORM）

**后端（Python）**
- FastAPI + Uvicorn
- SQLAlchemy ORM
- JWT 认证
- Docker 容器化部署

## 目录结构

```
AIcove/
├── apps/
│   └── aicove_flutter/              # Flutter 客户端（主开发目录）
│       ├── lib/src/
│       │   ├── core/                # 核心层：API客户端、数据库、网络、工具
│       │   ├── features/            # 业务层：chat、memory、plugins、diary 等
│       │   └── ui/                  # UI层
│       │       ├── features/        #   页面：chat、home、settings、plugins 等
│       │       ├── shared/          #   公共组件：widgets、animations、effects
│       │       └── theme/           #   主题：tokens、skins
│       ├── assets/                  # 静态资源（角色、表情、图标）
│       ├── docs/                    # 项目文档库（索引见 docs/README.md）
│       └── test/                    # 测试
│
├── cloud_backend/                   # Python 后端（认证/同步/云服务）
│   ├── main.py                      # 入口（路由挂载 + Web 静态站点）
│   ├── auth.py                      # JWT 认证
│   ├── sync_api_v2.py               # 增量同步 v2
│   ├── backup_api.py                # 备份/恢复
│   ├── trigger_api.py               # 云触发器
│   ├── memory_api.py                # 云记忆库
│   ├── key_distribution.py          # Key 分发与额度
│   └── ...                          # 详见 cloud_backend/README.md
│
├── start.ps1                        # 一键启动脚本（Windows）
├── CLAUDE.md                        # AI 协作规范
└── README.md                        # 本文件
```

## 快速开始（Windows）

### 1. 一键启动后端 + Web

```powershell
.\start.ps1                  # 自动安装依赖、构建 Web、启动后端
.\start.ps1 -SkipFlutter     # 跳过 Flutter Web 构建，只启动后端
.\start.ps1 -Clean           # 清理缓存后重新构建
```

启动后：
- 后端 API：`http://localhost:8000`
- Web UI：`http://localhost:8000/app/#/`
- API 文档：`http://localhost:8000/docs`

### 2. 移动端开发调试

```powershell
cd apps/aicove_flutter
flutter pub get
flutter run                  # 连接手机/模拟器运行
```

> 需要后端接口时，保持第 1 步的服务在跑。

### 3. 首次部署后端

```powershell
cd cloud_backend
cp .env.example .env         # 编辑 .env 设置 SECRET_KEY
python main.py               # 或用 Docker：docker-compose up -d
```

详细后端文档见 [cloud_backend/README.md](cloud_backend/README.md)。

## 资源文档

| 文档 | 说明 |
|------|------|
| [docs/README.md](apps/aicove_flutter/docs/README.md) | 文档库索引（入口） |
| [docs/公共组件总览.md](apps/aicove_flutter/docs/公共组件总览.md) | 前端公共组件速查（新手推荐） |
| [docs/API架构说明.md](apps/aicove_flutter/docs/API架构说明.md) | API 架构与聊天流程 |
| [docs/聊天发送链路拆分总结_20260226.md](apps/aicove_flutter/docs/聊天发送链路拆分总结_20260226.md) | 聊天发送链路排障入口 |
| [docs/绘图功能/README.md](apps/aicove_flutter/docs/绘图功能/README.md) | 绘图工具说明、配置与排障 |
| [docs/日志中心全链路监控重构方案_20260302/README.md](apps/aicove_flutter/docs/日志中心全链路监控重构方案_20260302/README.md) | 日志中心全链路监控重构说明 |
| [docs/界面布局说明.md](apps/aicove_flutter/docs/界面布局说明.md) | 响应式布局设计 |
| [cloud_backend/README.md](cloud_backend/README.md) | 后端完整文档（API 端点、部署、配置） |

---

# 项目宪法（每次写代码都必须遵守；如做不到先停下来问）

## 0) 只动允许的目录
- 允许修改：`apps/aicove_flutter/`（前端）、`cloud_backend/`（后端）
- 根目录其他文件夹多为参考资料：默认不改

## 1) 目录地图（像"零件箱 vs 房间"）
- 前端 UI 层：`apps/aicove_flutter/lib/src/ui/`
  - 主题/颜色：`apps/aicove_flutter/lib/src/ui/theme/`（优先用 tokens，不要页面里手写颜色）
  - 公共组件：`apps/aicove_flutter/lib/src/ui/shared/`（含 widgets, effects, animations）
  - 页面路由：`apps/aicove_flutter/lib/src/ui/features/<feature>/pages/`
- 后端业务层：`apps/aicove_flutter/lib/src/features/<feature>/`
  - 业务模型：`domain/`
  - 数据与服务：`data/`
  - 状态管理：`providers/` 或 `*_providers.dart`
- 公共核心：`apps/aicove_flutter/lib/src/core/` (utils, logic)
- 备注：如果发现 `lib/core/` 和 `lib/src/core/` 并存，默认以 `lib/src/` 为主。

## 2) UI/主题强约束（禁止"单页作品"）
- 颜色/字体/间距/圆角：只能用现有 Theme/tokens（`apps/aicove_flutter/lib/src/ui/theme/tokens.dart`）
- 按钮/弹窗/提示：优先复用 Moe 系列公共组件（见 `apps/aicove_flutter/docs/公共组件总览.md`）
- 统一导入：`import 'package:aicove_flutter/src/ui/shared/widgets/index.dart'`
- 提示统一用 MoeToast（不要到处自己写 SnackBar/Toast）

## 3) 宽屏/窄屏必须同步
- 断点与页面骨架以 `apps/aicove_flutter/docs/界面布局说明.md` 为准（900px）
- 改页面时要说明：窄屏/宽屏是否都适配，哪里需要联动修改

## 4) 数据流/状态管理
- 统一使用 Riverpod（不要混用多套状态管理）
- UI 不直接发请求：页面只负责展示与触发 action；请求放 data/service/provider

## 5) API 调用与错误处理
- 后端 REST：优先走 `apps/aicove_flutter/lib/src/core/api_client.dart`
- AI/消息相关：优先看聊天入口 `apps/aicove_flutter/lib/src/features/chat/chat_actions.dart`；架构说明见 `apps/aicove_flutter/docs/API架构说明.md`（以当前实现为准）
- 错误提示/重试逻辑要统一，别每个页面各写一套

## 6) 复用规则（防止越写越散）
- 发现"重复代码 >= 2 处"：先抽到 `apps/aicove_flutter/lib/src/ui/shared/widgets/` 或 `apps/aicove_flutter/lib/src/core/utils/`，再实现需求
- **主动抽象**：写新功能时，如果某段逻辑/组件明显可复用（如通用按钮、格式化工具、数据转换），应直接写成公共类，而非等重复后再抽取
- **入库登记**：新建的公共组件/工具类必须登记到 `apps/aicove_flutter/docs/公共组件总览.md`，格式参照已有条目（名称、文件路径、用途说明）

## 7) 交付检查清单（避免基础操作遗漏）
- 依赖是否安装：`flutter pub get`
- 后端是否启动（需要接口时）
- 本次改动后至少编译/运行一次；并说明怎么验证（窄/宽屏各看一眼）
