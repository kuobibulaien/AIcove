# AIcove - AI 心理陪伴助手

> 面向医院场景的心理医疗辅助 App，让 AI 像真实伴侣一样陪伴抑郁症患者。
>
> 跨平台（Android / Windows / Web）AI 对话客户端。AI 通过工具调用生成多模态消息（文本、语音、图片、表情包），并能主动触发关怀消息。曾用名 mygril。

## 架构分层

| 层 | 位置 | 说明 |
|---|---|---|
| 前端 | `apps/aicove_flutter/` | Flutter 客户端：UI、本地存储、聊天主流程、多模态交付 |
| 后端 | 本地后端 / 本地网关 | 本地接口承接与转发（本文档中"后端"默认指此层） |
| 云端 | `cloud_backend/` | **默认忽略，只做云备份，不参与功能开发**。目前所有开发和需求默认围绕 Flutter 本地客户端 |

## Agent Context Runtime

项目架构方向是 **Agent 上下文管理系统**（不是提示词管理系统）。核心公式：`Agent = 模型 + 上下文策略 + 工具策略 + 输出契约 + 后处理器`。

五类 Agent（Chat / Proactive / Analyzer / Memory / Renderer）共享同一套 `AgentDefinition` 定义面，通过 `ContextAssemblyPermissions` 收窄职责。前台聊天只是一个联系人级 `ChatAgent`。

详细设计：[Agent 上下文管理总架构](apps/aicove_flutter/docs/02_前后端分离与架构规范/Agent上下文管理总架构.md)

## Interface / 契约层规范

这里的 **Interface** 不是指 UI 界面，而是项目内部的稳定边界：上层只依赖抽象契约，具体实现由下层 Adapter / Service / Repository 承接。目标是让聊天主链路、Agent Runtime、Provider、插件和本地/云端能力都能被替换、测试和调度，而不是互相直接调用。

### 分层依赖原则

```
UI / Page
  -> Application UseCase
    -> Port / Contract / Interface
      -> Infrastructure Adapter
        -> Service / Repository / API / DB
```

Agent 链路按运行时视角理解：

```
AgentDefinition
  -> ContextProfile / ContextAssembler
    -> ProviderRenderer / ToolPolicy
      -> AgentRuntime / AgentScheduler
        -> OutputContract / DeliveryChannel
```

### 当前已有关键 Interface

| 领域 | Interface / 契约 | 位置 | 说明 |
|---|---|---|---|
| Agent Runtime | `AgentRuntime` / `AgentScheduler` / `AgentDeliveryChannel` | `apps/aicove_flutter/lib/src/features/agent_context/domain/agent_runtime_contracts.dart` | Agent 执行、调度、输出投递的统一运行时契约 |
| Chat Application | `ChatSendPort` / `ChatHistoryPort` | `apps/aicove_flutter/lib/src/features/chat/application/chat_ports.dart` | UI 与聊天发送、历史读写之间的应用层端口 |
| Provider Adapter | `ProviderAdapter` | `apps/aicove_flutter/lib/src/core/api/providers/provider_adapter.dart` | OpenAI / Claude / Gemini / 第三方兼容格式的统一适配接口 |
| Plugin | `Plugin` / `BasePlugin` | `apps/aicove_flutter/lib/src/features/plugins/domain/` | 插件能力统一入口，用于文本、TTS、图片、表情包等扩展 |
| Image Provider | `ImageProviderAdapter` | `apps/aicove_flutter/lib/src/core/api/image_providers/image_provider_adapter.dart` | 生图供应商适配接口 |
| TTS | `TtsSynthesisAdapter` / `TtsVoiceProvider` | `apps/aicove_flutter/lib/src/features/plugins/tts/` | 语音合成与声音目录供应商接口 |
| Memory | `EmbeddingService` | `apps/aicove_flutter/lib/src/features/memory/services/embedding_service.dart` | 记忆向量化能力接口 |

### 新功能 Interface 规则

新增或重构功能时，按下面规则判断是否需要先定义 Interface：

1. **跨层调用必须有 Interface**：UI 不直接依赖具体 Service；UseCase 依赖 Port，Port 再由 Adapter 接现有实现。
2. **跨供应商能力必须有 Adapter**：模型、TTS、生图、Embedding、云端 API 等外部能力统一走 Adapter。
3. **Agent 能力必须先有契约**：新增 Agent 先定义 `AgentDefinition`、`ContextProfile`、装配权限、输出契约和投递通道，再接具体执行。
4. **重复调用点超过 2 个先抽 Port**：同一能力被多个 feature 使用时，先抽稳定接口，不继续散落调用。
5. **命名保持一致**：应用层用 `*Port`，运行时用 `*Contract` / `*Runtime` / `*Channel`，外部适配用 `*Adapter`，具体实现用 `*Service` / `*Repository`。

### 迁移策略

不做一次性大重构。现阶段按“新功能先规范、旧链路逐步收口”的方式推进：

- 聊天主链路继续强化 `ChatSendPort` / `ChatHistoryPort`，让 UI 只面对 UseCase。
- Agent Context 继续以 `AgentRuntime` / `ContextAssembler` / `OutputContract` / `DeliveryChannel` 为核心契约。
- 插件、工具、TTS、生图、记忆逐步改成可被 Agent Scheduler 调度的能力接口。
- 旧 Service 不强制立刻拆，只有在新增 Agent、主动回复、插件调度或多供应商兼容时再顺手收口。

### Agent Context Studio Web 面板

云端内置零依赖单文件管理面板，三模式顶栏切换：

| 模式 | 入口 | 用途 |
|---|---|---|
| Prompt Studio | `/prompt-admin` | 维护 Dart 默认提示词常量，保存后 codegen |
| Agent Builder | 同上，顶栏切换 | 旧 `agents` 配置 |
| **Agent Context** | `/api/v1/prompt-defaults-admin/panel`（同一主面板顶栏切换） | 上下文管理运维入口 |

Agent Context 二改口径：**Node Studio + Agent Build 流程图**。Node Studio 管理所有组成 Agent 上下文的元素（角色卡、预设、prompt、prompt_order、世界书、记忆、运行时事实、tool、输出契约等）；Agent Build 像流程图一样把节点库子节点拖到画布并连线，触发策略和投递流程作为画布右侧属性管理。每个联系人默认对应一个独立 `chat_agent:<contactId>`。
后端：`cloud_backend/agent_context_admin_api.py`，数据落 `data/agent_context_admin.json`（不入 DB、不写 Dart）。API 详见 [cloud_backend/README.md](cloud_backend/README.md)。

## 核心功能

| 功能 | 说明 |
|---|---|
| AI 对话 | 多轮对话，流式输出，角色人设可自定义 |
| 多模态消息 | 文本、TTS 语音、AI 绘图、表情包 |
| 插件系统 | 语音（硅基流动/阿里云/MiniMax）、绘图、表情包 |
| 主动关怀 | 云触发器驱动，AI 主动发消息 |
| 记忆系统 | 本地 + 云端记忆存储与召回 |
| 云同步 | 增量同步 v2（Scope/回收站） |
| 数据备份 | 云端备份/恢复，离线导入导出 |
| 皮肤主题 | 可切换 UI 皮肤 |
| 角色卡 | 多角色管理 |

## 技术栈

- **前端**：Flutter 3.22+ / Dart 3.3+ · Riverpod · GoRouter · Drift
- **云端**：FastAPI + Uvicorn · SQLAlchemy · JWT · Docker

## 目录结构

```
AIcove/
├── apps/aicove_flutter/           # Flutter 客户端（主开发目录）
│   ├── lib/src/
│   │   ├── core/                  # 核心层：API客户端、数据库、工具
│   │   ├── features/              # 业务层：chat、memory、plugins 等
│   │   └── ui/                    # UI层：features/ · shared/ · theme/
│   ├── assets/                    # 静态资源
│   ├── docs/                      # 文档库（索引见 docs/README.md）
│   └── test/
│
├── cloud_backend/                 # 云端服务（详见 cloud_backend/README.md）
│   └── start.ps1                  # 一键启动（Windows）
├── AGENTS.md                      # AI 协作规范（CLAUDE.md 仅作指针指向此文件）
└── README.md                      # 本文件
```

## 快速开始（Windows）

```powershell
# 启动云端（FastAPI，需先配置 cloud_backend/.env）
cd cloud_backend
.\start.ps1

# 移动端开发
cd apps/aicove_flutter
flutter pub get && flutter run
```

Web 端构建并集成到云端 `/app` 路径的步骤见 [apps/aicove_flutter/README.md](apps/aicove_flutter/README.md)。

启动后：
- 云端 API / Swagger：`http://localhost:8000` · `http://localhost:8000/docs`
- Web UI：`http://localhost:8000/app/#/`
- Prompt Studio：`http://localhost:8000/prompt-admin`
- **主面板（Prompt Studio / Node Studio / Agent Build）**：`http://localhost:8000/api/v1/prompt-defaults-admin/panel`

首次部署详见 [cloud_backend/README.md](cloud_backend/README.md)。

## 资源文档索引

| 文档 | 说明 |
|---|---|
| [docs/README.md](apps/aicove_flutter/docs/README.md) | **文档库总入口** |
| [公共组件总览](apps/aicove_flutter/docs/公共组件总览.md) | 前端 UI 积木速查 |
| [API 架构说明](apps/aicove_flutter/docs/API架构说明.md) | API 架构与聊天流程 |
| [聊天上下文真相源规范](apps/aicove_flutter/docs/02_前后端分离与架构规范/聊天请求上下文真相源与组装规范.md) | 数据库真相源基石规范 |
| [Agent 上下文总架构](apps/aicove_flutter/docs/02_前后端分离与架构规范/Agent上下文管理总架构.md) | Agent Runtime / 装配 / 迁移原则 |
| [界面布局说明](apps/aicove_flutter/docs/界面布局说明.md) | 响应式布局（断点 900px） |
| [cloud_backend/README.md](cloud_backend/README.md) | 云端 API 端点、部署、配置 |

---

# 项目宪法

> 每次写代码都必须遵守。做不到先停下来问。

**0) 只动允许的目录**：`apps/aicove_flutter/`（前端）、`cloud_backend/`（云端）。根目录其他文件夹默认不改。

**1) 前端目录地图**
- UI 层：`lib/src/ui/`（`theme/` · `shared/` · `features/`）
- 业务层：`lib/src/features/<feature>/`（`domain/` · `data/` · `providers/`）
- 核心层：`lib/src/core/`

**2) UI 强约束**：颜色用 `tokens.dart`、组件用 Moe 系列、导入用 `shared/widgets/index.dart`、提示用 MoeToast。详见[公共组件总览](apps/aicove_flutter/docs/公共组件总览.md)。

**3) 宽屏/窄屏同步**：断点 900px，改页面必须说明两端适配。详见[界面布局](apps/aicove_flutter/docs/界面布局说明.md)。

**4) 数据流**
- 统一 Riverpod，UI 不直接发请求
- **DB raw message 是聊天上下文唯一真相源**——禁止拿 UI 投影、气泡缓存喂模型。详见[上下文规范](apps/aicove_flutter/docs/02_前后端分离与架构规范/聊天请求上下文真相源与组装规范.md)
- Agent 迁移按上下文管理系统演进；新增 Agent 必须先定义 `AgentDefinition` / `ContextProfile` / `ContextAssembler` / `OutputNormalizer`。详见[总架构](apps/aicove_flutter/docs/02_前后端分离与架构规范/Agent上下文管理总架构.md)

**5) API**：REST 走 `api_client.dart`，AI/消息走 `chat_actions.dart`，错误处理统一

**6) 复用**：重复 ≥ 2 处先抽公共组件/工具，新建必须登记[公共组件总览](apps/aicove_flutter/docs/公共组件总览.md)

**7) 交付检查**：`flutter pub get` → 编译运行 → 窄/宽屏各验一次
