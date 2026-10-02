# AIcove - AI 心理陪伴助手

> 以 macOS 为设计与开发基准的跨平台 Flutter AI 对话客户端，各端共用同一套界面。AI 通过工具调用生成多模态消息（文本、语音、图片、表情包），并能主动触发关怀消息。曾用名 mygril。

## 架构分层

| 层 | 位置 | 说明 |
|---|---|---|
| 前端 | `apps/aicove_flutter/lib/src/ui/` | 页面、组件、主题 |
| 本地后端 | `apps/aicove_flutter/lib/src/features/`、`lib/src/core/` | 聊天主链路、Agent Runtime、插件、记忆、本地数据库。它是 Flutter 进程内的 Dart 代码，前端通过方法调用使用它，不走 HTTP。**本项目所说的"后端"一律指这一层。** |
| 云端 | `cloud_backend/` | 只承担云同步及必要账号认证（客户端已接入，正在测试）；旧 API 配发、会员及其他云端服务已删除。 |

界面规范：以 Mac 为基准，窄屏即手机模式，宽屏为左侧悬浮完整手机一级界面加右侧同一套二级页面。规则正文只在[项目宪法第 3 条](#项目宪法)和[全端共用界面架构与布局规范](apps/aicove_flutter/docs/界面布局说明.md)，此处不复制。

## Agent Context Runtime

项目架构方向是 **Agent 上下文管理系统**（不是提示词管理系统）。核心公式：`Agent = 模型 + 上下文策略 + 工具策略 + 输出契约 + 后处理器`。

五类 Agent（Chat / Proactive / Analyzer / Memory / Renderer）共享同一个 `AgentDefinition` 定义面，用 `AgentContextAssemblyPermissions` 限定各自能读取哪些上下文来源。前台聊天只是一个联系人级 `ChatAgent`。

详细设计：[Agent 上下文管理总架构](apps/aicove_flutter/docs/02_前后端分离与架构规范/Agent上下文管理总架构.md)

## 契约层规范（Port / Adapter）

上层只依赖抽象契约，具体实现由下层 Adapter / Service / Repository 承接，目的是让聊天主链路、Agent Runtime、模型供应商、插件都能被替换和测试，而不是互相直接调用。

### 分层依赖原则

```
UI / Page                       lib/src/ui/
  -> Application UseCase        lib/src/features/<feature>/application/
    -> Port / Contract          lib/src/features/<feature>/domain/
      -> Infrastructure Adapter lib/src/features/<feature>/infrastructure/ 或 data/
        -> Service / Repository / API / DB
```

Agent 链路按运行时视角理解：

```
AgentDefinition
  -> ContextProfile / AgentContextAssemblyPermissions
    -> ProviderRenderer / ToolPolicy
      -> AgentRuntime / AgentScheduler
        -> AgentOutputContract / AgentDeliveryChannel
```

### 当前已有关键契约（类名与代码一致）

| 领域 | 契约 | 位置 | 说明 |
|---|---|---|---|
| Agent Runtime | `AgentDefinition` / `ContextProfile` / `AgentContextAssemblyPermissions` / `AgentOutputContract` / `AgentRuntime` / `AgentScheduler` / `AgentDeliveryChannel` | `apps/aicove_flutter/lib/src/features/agent_context/domain/agent_runtime_contracts.dart` | Agent 定义、上下文装配权限、执行、调度、输出投递 |
| Chat Application | `ChatSendPort` / `ChatHistoryPort` | `apps/aicove_flutter/lib/src/features/chat/application/chat_ports.dart` | UI 与聊天发送、历史读写之间的应用层端口 |
| Provider Adapter | `ProviderAdapter` | `apps/aicove_flutter/lib/src/core/api/providers/provider_adapter.dart` | OpenAI / Claude / Gemini / 第三方兼容格式的统一适配接口 |
| Plugin | `Plugin` / `BasePlugin` | `apps/aicove_flutter/lib/src/features/plugins/domain/` | 插件能力统一入口，用于文本、TTS、图片、表情包等扩展 |
| Image Provider | `ImageProviderAdapter` | `apps/aicove_flutter/lib/src/core/api/image_providers/image_provider_adapter.dart` | 生图供应商适配接口 |
| TTS | `TtsSynthesisAdapter` / `TtsVoiceProvider` | `apps/aicove_flutter/lib/src/features/plugins/tts/` | 语音合成与声音目录供应商接口 |
| Memory | `EmbeddingService` | `apps/aicove_flutter/lib/src/features/memory/services/embedding_service.dart` | 记忆向量化能力接口 |

### 新功能契约规则

1. **跨层调用必须有契约**：UI 不直接依赖具体 Service；UseCase 依赖 Port，Port 再由 Adapter 接现有实现。
2. **跨供应商能力必须有 Adapter**：模型、TTS、生图、Embedding 等外部能力统一走 Adapter。
3. **新增 Agent 先定义契约再接执行**：先有 `AgentDefinition`、`ContextProfile`、装配权限（`AgentContextAssemblyPermissions`）、输出契约（`AgentOutputContract`）和投递通道（`AgentDeliveryChannel`），再写具体执行逻辑。只加 prompt 不算新增 Agent。
4. **同一能力被 2 个及以上 feature 使用时先抽 Port**，不继续散落调用（与宪法第 6 条"重复 ≥ 2 处先抽公共组件"同一口径）。
5. **命名保持一致**：应用层用 `*Port`，运行时用 `*Contract` / `*Runtime` / `*Channel`，外部适配用 `*Adapter`，具体实现用 `*Service` / `*Repository`。

### 迁移策略

前端页面与导航按全端共用界面规范重写，可整体重新设计并分批验收。以下渐进策略只约束业务／Agent 链路，不限制前端重写：

- 聊天主链路继续强化 `ChatSendPort` / `ChatHistoryPort`，让 UI 只面对 UseCase。
- Agent Context 继续以 `AgentRuntime` / `AgentOutputContract` / `AgentDeliveryChannel` 为核心契约。
- 插件、工具、TTS、生图、记忆逐步改成可被 `AgentScheduler` 调度的能力接口。
- 旧 Service 不强制立刻拆，只有在新增 Agent、主动回复、插件调度或多供应商兼容时再顺手收口。

## 插件配置架构（2026-09-06）

**插件配置统一预设化：角色卡按插件绑定预设，由预设集中管理渠道、模型及能力参数；"默认设置"改为"默认预设"。** 绘图与音色已按此改造，其他插件逐步接入，不代表全量完成。正式规范：[插件预设与角色卡绑定规范](apps/aicove_flutter/docs/02_前后端分离与架构规范/插件预设与角色卡绑定规范.md)。

## 核心功能

| 功能 | 说明 |
|---|---|
| AI 对话 | 多轮对话，流式输出，角色人设可自定义 |
| 多模态消息 | 文本、TTS 语音、AI 绘图、表情包 |
| 插件系统 | 语音（硅基流动/阿里云/MiniMax）、绘图、表情包、酒馆兼容（预设／正则／世界书） |
| 主动关怀 | 定时与触发器驱动，AI 主动发消息 |
| 记忆系统 | 每个角色独立 MEMORY.md，手动压缩摘要，向量召回 |
| 云同步 | [v3 后端](cloud_backend/sync_v3/README.md) 与客户端已接入，完整多端对齐和实机速度正在测试 |
| 数据备份 | 离线导入导出 |
| 皮肤主题 | 可切换 UI 皮肤 |
| 角色卡 | 多角色管理 |

## 技术栈

- **前端**：Flutter / Dart（[项目 SDK 与命令入口](apps/aicove_flutter/tool/DIAGNOSTICS.md#项目-flutter-sdk2026-09-12)，SDK 3.44.6 经 `tool/flutterw` 调用，不用机器全局 Flutter）· Riverpod · GoRouter · Drift
- **云端**：FastAPI + Uvicorn · SQLAlchemy · JWT · Docker
- **平台**：macOS（基准）、Android（真机验收）、iOS、Windows、Linux 目录保留；Web 已于 2026-09-13 移除

## 目录结构

```
aicove/
├── AGENTS.md                      # AI 协作规范：执行方式、授权边界、文档索引（唯一权威）
├── CLAUDE.md / GEMINI.md          # 各 harness 入口，只指向 AGENTS.md
├── README.md                      # 本文件：架构约束 + 项目宪法（验证流程唯一权威）
├── hooks/memory.py                # 会话钩子：自动注入项目记忆、追加需求日志
├── docs/项目记忆/                  # 所有 agent 共用的长期记忆
│   ├── README.md                  #   总览、当前重点、模块边界速查（hook 每次注入）
│   ├── 需求日志.md                 #   用户原话 + 一句话结果
│   ├── 决策记录/                   #   架构级决定（ADR），一事一文件
│   ├── 经验教训.md                 #   踩坑硬约束
│   ├── 术语表.md / 模块边界补充.md
│   └── 历史任务/                   #   未完成任务的原始方案，只读
├── apps/aicove_flutter/           # Flutter 客户端（主开发目录）
│   ├── lib/main.dart              #   启动入口
│   ├── lib/src/app.dart           #   根组件与路由
│   ├── lib/src/ui/                #   前端：features/（按页面）· shared/（公共组件）· theme/（tokens、主题）
│   ├── lib/src/features/          #   本地后端：一个业务一个目录
│   │   ├── chat/                  #     application/（UseCase、Port）· domain/ · data/ · infrastructure/ · presentation/（聊天专用组件）· chat_actions.dart（发送主链路）
│   │   ├── agent_context/         #     Agent 契约与装配（domain/agent_runtime_contracts.dart）
│   │   ├── plugins/               #     插件：tts/ · image/ · sticker/ · memory/ · trigger/ · time_awareness/
│   │   ├── memory/ auto_reply/ backup/ sync/ settings/ observability/ …
│   ├── lib/src/core/              #   横切能力：api/（供应商适配）· database/（Drift）· network/ · media/ · models/ · utils/ · config.dart
│   ├── assets/                    #   静态资源、默认提示词 JSON
│   ├── test/ integration_test/ test_contract/
│   ├── tool/                      #   开发工具（见 tool/DIAGNOSTICS.md）
│   │   ├── flutterw               #     项目 Flutter SDK 入口，所有 flutter 命令经它执行
│   │   ├── mac_debug_session.py   #     Mac 持续调试会话：start / reload / restart / status / wait / stop
│   │   ├── dart_mcp_server        #     项目级 Dart MCP 启动入口（各 harness 共用）
│   │   ├── collect_diagnostics.py #     从手机/Mac 抓取应用日志
│   │   └── DIAGNOSTICS.md         #     日志、调试会话、MCP 命令说明（唯一权威）
│   ├── docs/                      #   人读文档库（入口 docs/README.md）
│   ├── android/ ios/ macos/ windows/ linux/   # 平台工程
│   └── third_party/               #   本地补丁依赖（lucide_icons）
├── cloud_backend/                 # 云端（只维护 sync_v3/，启动方式见其 README）
├── opusdocs/ scratch/             # 历史资料与临时产物，不作为规范
```

说明：`lib/src/features/*/presentation/` 放只属于该业务的组件（例如聊天气泡、输入框），整页和跨业务组件放 `lib/src/ui/`。新页面一律放 `lib/src/ui/features/<页面>/`。

## 快速开始（macOS）

所有 Flutter 命令都通过 `tool/flutterw`，不要直接敲 `flutter`。

**人工试跑**（自己看效果，终端里按 `r` 热重载、`R` 热重启）：

```bash
cd apps/aicove_flutter
tool/flutterw run -d macos
```

**Agent 日常开发**（脚本管理一个常驻 Debug 会话，改完代码发热重载，不重新编译）：

```bash
cd apps/aicove_flutter
python3 tool/mac_debug_session.py start     # 已有会话就复用
python3 tool/mac_debug_session.py reload    # 改了普通 Dart 代码
python3 tool/mac_debug_session.py restart   # 改了 main / 初始化逻辑 / 依赖
```

会话起来后，用项目级 Dart MCP 读取运行时异常和组件树做检查。热重载、热重启、重新构建的选择规则见[项目宪法第 7 条](#项目宪法)；脚本细节、MCP 连接方式见 [tool/DIAGNOSTICS.md](apps/aicove_flutter/tool/DIAGNOSTICS.md)。

云端如需启动：见 [cloud_backend/README.md](cloud_backend/README.md)。

## 资源文档索引

| 文档 | 说明 |
|---|---|
| [docs/README.md](apps/aicove_flutter/docs/README.md) | **文档库总入口** |
| [公共组件总览](apps/aicove_flutter/docs/公共组件总览.md) | 前端 UI 积木速查 |
| [API 架构说明](apps/aicove_flutter/docs/API架构说明.md) | API 架构与聊天流程 |
| [聊天上下文真相源规范](apps/aicove_flutter/docs/02_前后端分离与架构规范/聊天请求上下文真相源与组装规范.md) | 数据库真相源基石规范 |
| [Agent 上下文总架构](apps/aicove_flutter/docs/02_前后端分离与架构规范/Agent上下文管理总架构.md) | Agent Runtime / 装配 / 迁移原则 |
| [全端共用界面架构与布局规范](apps/aicove_flutter/docs/界面布局说明.md) | Mac 基准、完整手机界面复用、悬浮主从布局与导航验收 |
| [tool/DIAGNOSTICS.md](apps/aicove_flutter/tool/DIAGNOSTICS.md) | 日志采集、调试会话、Dart MCP |
| [cloud_backend/README.md](cloud_backend/README.md) | 云同步协议、测试与运行配置 |

---

# 项目宪法

> 每次写代码都必须遵守。做不到先停下来问。

**0) 范围与目录**：应用实现位于 `apps/aicove_flutter/`（前端 + 本地后端）、`cloud_backend/`（云端，仅 sync_v3）；规范维护可同步根 `README.md`、`AGENTS.md` 与 `docs/项目记忆/`。其余目录按任务授权处理，保护已有工作树修改。

**1) 前端目录地图**
- 前端（UI 层）：`lib/src/ui/`（`theme/` · `shared/` · `features/<页面>/`）；新页面只放这里
- 本地后端（业务层）：`lib/src/features/<feature>/`，按需包含 `application/`（UseCase、Port）· `domain/` · `data/` · `infrastructure/` · `providers/` · `services/` · `presentation/`（仅该业务专用组件）
- 横切能力（核心层）：`lib/src/core/`（`api/` · `database/` · `network/` · `media/` · `models/` · `utils/`）

**2) UI 强约束**：颜色用 `tokens.dart`、组件用 Moe 系列、导入用 `shared/widgets/index.dart`、提示用 MoeToast。详见[公共组件总览](apps/aicove_flutter/docs/公共组件总览.md)。

**3) 全端共用界面**：以 Mac 为基准；窄屏就是手机模式，宽屏左侧悬浮完整手机一级界面、右侧展开同一份二级及更深页面。沿用统一 900 逻辑像素断点，共用页面、导航栈和状态，按局部面板宽度排布；禁止复制手机／桌面业务页面。详见[界面架构与布局规范](apps/aicove_flutter/docs/界面布局说明.md)。

**4) 数据流**
- 统一 Riverpod，UI 不直接发请求
- **DB raw message 是聊天上下文唯一真相源**——禁止拿 UI 投影、气泡缓存喂模型。详见[上下文规范](apps/aicove_flutter/docs/02_前后端分离与架构规范/聊天请求上下文真相源与组装规范.md)
- Agent 迁移按上下文管理系统演进；新增 Agent 必须先按[新功能契约规则第 3 条](#新功能契约规则)定义契约。详见[总架构](apps/aicove_flutter/docs/02_前后端分离与架构规范/Agent上下文管理总架构.md)

**5) API**：外部 HTTP 走 `lib/src/core/api_client.dart`（`lib/src/features/sync/data/api_client.dart` 只服务云同步），AI/消息走 `lib/src/features/chat/chat_actions.dart`，错误处理统一

**6) 复用**：重复 ≥ 2 处先抽公共组件/工具，新建必须登记[公共组件总览](apps/aicove_flutter/docs/公共组件总览.md)

**7) 交付检查**：按改动类型选择验证，不对所有改动套同一条完整流程。本条是验证流程的唯一权威位置，其他文档只放链接不复制。
- 依赖：只在 `pubspec` / 锁文件或 Flutter、SDK 环境变化时单独执行 `flutter pub get`；其余情况由后续 `flutter` 命令自带的依赖检查覆盖。
- 静态检查与相关回归：改动范围内跑一次；通过后相关代码没有再变化，收尾时不重复跑。
- 纯云端、脚本、工具或测试改动：只验证对应部分（云端测试、脚本实际运行、目标测试），不编译启动 Flutter 应用。
- 日常 Dart 迭代：复用现有 Debug 会话（`tool/mac_debug_session.py`），修改后先热重载并确认本次成功，再按改动范围用 Dart MCP 读取运行时异常、组件树及执行相关行为检查；通常保留当前页面与状态，不为普通校验重新构建或安装。需要重跑 main／初始化逻辑或改了依赖时使用热重启，它会重置 Dart 状态。**MCP 不会自动同步源码；连接成功、工具可见或旧组件树可读，都不能证明本次修改已生效。** 命令与连接方式见[调试与日志说明](apps/aicove_flutter/tool/DIAGNOSTICS.md#dart-mcp)。
- 只排查当前运行状态：未修改代码时可直接用 MCP 读取，不先重载、重启或安装；先保留现有异常现场。手机 Release 问题继续按 AGENTS 的日志采集流程处理。
- 重新构建与安装：Swift／Kotlin／原生插件、SDK 或需重新构建的依赖变更，以及正式交付／切换 Profile、Release 时，重新构建目标版本；项目命令经 `tool/flutterw`，按需用 `run --no-resident`。安装只在交付、用户明确要求或目标设备验证需要更新应用时进行，不因"做一次校验"固定重装。没有调试或性能对照需要时，不先跑 Debug 再构建 Release 重复验收。
- 测试设备（2026-09-23）：界面、交互与性能测试默认直接在 Mac 窄屏（手机模式）完成，不需要手机，也不为测试占用、操作或等待用户手机。仅 Mac 无法模拟的手机专属能力（系统安全区、软键盘、系统返回手势）才在手机上补验；未补验的在交付中注明缺口。手机 Release 运行问题的现场日志仍按 AGENTS「运行问题排查」采集。
- 性能验证：使用 Profile 读取帧耗时等实际性能数据；MCP 异常为空、Debug 流畅或组件树正常均不能作为性能通过的证据。Mac GPU 明显强于手机，窄屏测性能时除了看掉帧，还要与同条件基线（如空白页、纯色材质）对比 UI／光栅耗时的相对增量，按增量判断手机上的风险。
- 界面验证按实际影响选择：不改变界面行为的修改不做界面验收；改动某个页面时检查该页面在窄／宽两种承载下的实际界面；改动公共组件或主题时，按其影响范围从[界面架构与布局规范](apps/aicove_flutter/docs/界面布局说明.md)第 8 节挑选对应矩阵项（例如只改按钮颜色，检查该组件在浅／深主题下的实际显示即可）；只有触及布局壳、导航栈、断点或跨页面共享排布机制时才执行完整矩阵。证据优先用日志、MCP 运行时异常与组件树、布局断言；颜色、模糊、间距等外观仍需查看实际界面或截图，不能由组件树替代。涉及移动端时补实际手机安全区、软键盘与返回验证，未验平台说明缺口。
- 纯文档改动：检查链接、规则一致性与完整差异，无需编译安装。
