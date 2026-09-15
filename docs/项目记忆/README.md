# 项目记忆（所有 AI agent 共用）

> 这个目录是 AIcove 项目的长期记忆。任何进入本项目的 agent（Claude Code、Codex、Pi、Gemini 或其他实验性 harness）开工前读这一页，收工时按下面的「写入规则」把本次的关键信息写回来。
> 目录里只有 markdown，没有流程、没有脚本依赖；hook 只是把这一页自动塞进上下文，不装 hook 也能靠 `AGENTS.md` 的规则照常运转。

## 目录

| 文件 | 放什么 | 谁写 |
|---|---|---|
| `README.md`（本页） | 项目总览、架构边界、当前重点 | 架构级变化时由 agent 更新 |
| `需求日志.md` | 用户每次提出的原始需求（原话）+ 一句话结果 | 原话由 hook 自动追加；结果由 agent 收工时补 |
| `决策记录/` | 架构级决策，一事一文件（背景 / 备选 / 决定 / 代价） | agent 做出架构级选择时写 |
| `经验教训.md` | 踩坑后沉淀的硬约束，违反会直接出 bug | agent 修完非平凡 bug 后写 |
| `术语表.md` | 领域术语统一口径 | 出现新术语时写 |
| `Agent上下文运行时规范.md` | Agent Context Runtime 的开发规则与场景契约 | 改 Agent 链路时更新 |
| `模块边界补充.md` | 各模块交付后的当前有效边界全文，本页只留速查行 | 模块批次收工时写 |
| `历史任务/` | 2026-07 起未完成任务的原始方案（prd / design / implement），只读参考 | 不再新增 |

## 写入规则（agent 收工必做）

1. **需求日志**：实际改动任务（改了代码、文档、配置或产出了交付物）收工时，在 hook 写入的条目下把 `结果：（待补）` 改为一句简短结果（做成了什么 / 没做成什么 / 遗留）。纯问答、闲聊或只查看不改动的对话不必手写结果，保留 `（待补）` 不算遗漏。hook 没写入时（例如不支持 hook 的 harness）仅对实际改动任务自行补一条完整条目。
2. **决策记录**：本次若做了库选型、模式选择、数据流/真相源变更、跨层边界调整等架构级决定，新建 `决策记录/NNNN-标题.md`，并在 `决策记录/README.md` 索引加一行。琐碎选择（命名、格式）不写。
3. **经验教训**：本次若修了一个"表面原因和真实原因不一样"的 bug，把硬约束（不是过程）追加进去，附正例文件路径。
4. **本页**：架构边界、当前重点变化时更新对应小节。本页由 hook 每次会话全文注入，只放当前状态、关键边界和索引；模块边界写进 `模块边界补充.md` 并在速查表加一行，实现细节去 `apps/aicove_flutter/docs/`。
5. 需求原话、结果和历史决策保留记录，新增条目带日期。当前规范被新决定取代时原位修订冲突条款并同步入口；旧 ADR 标记 superseded、注明替代者，不能只在文末追加相反规则。保护他人尚未完成的修改，不重排无关内容。

## 项目总览

AIcove 是面向医院场景的 AI 心理陪伴助手。仓库包含 Flutter 客户端和 FastAPI 云端服务。

| 层 | 位置 | 职责 |
|---|---|---|
| Flutter 客户端 | `apps/aicove_flutter/` | UI、本地存储、聊天主链路、多模态消息、插件、Agent Runtime 消费 |
| 云端服务 | `cloud_backend/` | 仅保留云同步 v3 与必要账号能力（正在测试）；旧 API 配发、会员、Studio 及其他云端服务已删除，数据未迁移或清空（ADR0031） |
| 人读文档库 | `apps/aicove_flutter/docs/`（入口 `README.md`，119+ 篇） | 架构、模块、UI、功能说明 |
| 项目记忆 | `docs/项目记忆/`（本目录） | agent 协作时优先加载的长期信息 |
| 临时资料 | `scratch/`、`.codex-temp/` | 排查输出、草稿、一次性报告，不作为规范 |

核心原则：

- 聊天上下文以 DB raw message 为唯一真相源，禁止用 UI 投影或气泡缓存喂模型。
- 新能力跨层调用先定义 Port / Contract / Adapter，UI 不直接依赖具体 Service。
- Agent 方向是上下文管理系统，不是单纯提示词管理系统。
- 全端前端重写方向已确认（2026-09-11）：以 Mac 为基准，共用完整页面与导航，按功能批次验收；旧“UI 只顺手收口”限制失效。业务／数据链路仍按已有契约和对应迁移方案处理。
- Web 端不在目标平台内（2026-07-20 裁决）；2026-09-13 已删除 `web/` 目录、`kIsWeb` 分支、`flutter_web_plugins` 依赖与云端 `/app` 静态挂载，不要再加回。

## 架构边界

Flutter 分层：

```text
UI / Page
  -> Application UseCase
    -> Port / Contract / Interface
      -> Infrastructure Adapter
        -> Service / Repository / API / DB
```

| 类型 | 命名 |
|---|---|
| 应用层端口 | `*Port` |
| 运行时契约 | `*Contract` / `*Runtime` / `*Channel` |
| 外部供应商适配 | `*Adapter` |
| 具体实现 | `*Service` / `*Repository` |

必须抽象的情况：UI 跨层调用业务能力；外部供应商能力（模型、TTS、生图、Embedding、云端 API）；Agent 能力（先有 `AgentDefinition`、`ContextProfile`、装配权限、输出契约和投递通道）；同一能力被 2 个以上 feature 使用。

禁止模式：UI 直接拼 API 请求或直接操作数据库；聊天发送链路绕过 `chat_actions.dart` / 应用层端口；新增 Agent 时只加 prompt，不定义上下文、工具策略和输出契约。

## 当前重点（2026-09-13 更新）

状态只写一句，过程与证据在对应 ADR、需求日志或模块文档里。

| 方向 | 状态 | 资料 |
|---|---|---|
| 云同步 v3 与账号/媒体 | 近期读取服务和两端 Release 已更新；Mac 9,605 条消息及全部角色/设置/预设/摘要/记忆与云端摘要一致，旧冲突与队列归零，云端2,458文件已逐一校验；159无文件历史引用保留占位，Windows 未验，第三方引擎未接入 | ADR0021／0026／0028／0029、[调研](../../apps/aicove_flutter/docs/02_前后端分离与架构规范/云同步开源数据结构调研.md)、[协议](../../cloud_backend/sync_v3/README.md) |
| 全端前端重写（Mac 基准、完整手机界面与详情共用） | 规范已确认（09-11）；09-12 收口三页标题、纯图标底栏与角色单列目录，批次验收见需求日志；各端重写与全量验收待实施 | [界面布局说明](../../apps/aicove_flutter/docs/界面布局说明.md)、ADR0019 |
| 模型思考档位（会话级，三家按档位发请求） | 代码与测试完成（09-04），待真机验证 | ADR0003、`历史任务/09-03-model-thinking-level/` |
| NovelAI V5 Full 默认生图模型 | 进行中 | `历史任务/08-21-novelai-v5-full-default/` |
| AIcove 2.0：DSH Agent 运行时 | 方案阶段，ADR0001 仍为 proposed | ADR0001、`历史任务/08-21-dsh-android-agent-runtime/` |
| 酒馆兼容插件（测试） | 预设／正则／世界书核心接入与逐条开关已实现（09-06）；高级世界书条件后推，不宣称全量 ST 兼容 | [模块说明](../../apps/aicove_flutter/docs/04_功能模块规范/酒馆兼容插件/README.md)、ADR0010 |
| 前端性能观测打点（FrameTiming、重建计数） | 方案阶段 | `历史任务/07-26-perf-observability/` |
| 手机前端响应日志 | 低频页面/气泡/滚动/音频记录与单轮导出已实现并真机确认（09-05）；高频采样不在本批 | ADR0005 |
| Agent 自动抓日志 | 第一批采集器与 Release 电脑读取通道已交付并自动开启（09-10）；故障缓冲/帧摘要待第二批 | ADR0006、ADR0013、[DIAGNOSTICS.md](../../apps/aicove_flutter/tool/DIAGNOSTICS.md) |
| 聊天列表滑动卡顿 | 生成不停与手势优先已修（09-05），离线对照通过；真实生成复验待做 | 经验教训「生成不停与手势优先」、`tool/chat_scroll_probe.dart` |
| 智能回复建议（3 个候选） | 方案阶段 | `历史任务/07-13-smart-reply/` |

## 运行问题排查（当前入口）

手机运行异常先抓当前已落盘日志再定位源码，不把抓取、筛选、导出或截图交给用户；Release 不要求切 Debug、不要求开开关、排查结束不关服务。**行为规则唯一权威位置是根 [AGENTS.md](../../AGENTS.md)「运行问题排查」；命令、凭证获取与持续调试会话见客户端 [tool/DIAGNOSTICS.md](../../apps/aicove_flutter/tool/DIAGNOSTICS.md)，本页不复制。** 决策背景：ADR0006、ADR0013。
## 模块边界速查（改对应模块前读全文）

全文在 [模块边界补充.md](模块边界补充.md)，本页一行一条：

| 模块 | 一句话边界 | 决策 |
|---|---|---|
| 全端共用界面（09-11，当前规范） | Mac 基准；窄屏即手机，宽屏左侧悬浮完整一级界面＋右侧同一套详情栈；统一壳管 900 断点与状态保持，不复制手机／桌面页面。规范确认≠全端已交付 | ADR0019；[界面布局说明](../../apps/aicove_flutter/docs/界面布局说明.md) |
| 插件预设与角色绑定（09-06） | 插件配置统一预设化，角色卡按插件绑定预设，"默认设置"改"默认预设"；绘图、音色已改造，其他逐步接入 | ADR0008／0009 |
| 音色预设（09-06） | 完整预设库，请求时固定 owner 与供应商快照；付费合成未实测 | 见补充文 |
| 酒馆兼容（09-06） | 组合预设沿用 recipeId，按请求 owner 解析，明确绑定缺失不静默回退；世界书只注入 raw 派生副本 | ADR0010 |
| 插件上下文过滤（09-11） | 标签说明由插件提供；插件关闭后请求副本屏蔽对应标签与工具对，原始历史保留 | ADR0017 |
| 联系人 MD 记忆＋手动压缩（09-05） | 每角色独立 MEMORY.md；手动新话题与自动续聊分开；默认272k容量、80%触发；压缩同步提出MD增量，raw保留 | ADR0004／0007／0027 |
| 编辑提交保护（09-06） | 编辑只建按 owner 隔离草稿，发送时校验 raw 版本并同事务落库；旧话题编辑暂拒绝 | ADR0012 |

## 权威入口

- 项目级 Dart MCP 已接入，所有 harness 共用 SDK 启动入口；原生配置、无 MCP 的命令行调用及验收边界见 [DIAGNOSTICS.md「项目级 Dart MCP」](../../apps/aicove_flutter/tool/DIAGNOSTICS.md#dart-mcp)。已实测连接 AIcove Mac Debug 读取组件树与运行时异常，宿主展示／其它平台不据此宣称通过。决定见 ADR0022。
- 项目 Flutter SDK 已切换为独立入口 `apps/aicove_flutter/tool/flutterw`；命令与版本唯一说明见 [DIAGNOSTICS.md「项目 Flutter SDK」](../../apps/aicove_flutter/tool/DIAGNOSTICS.md#项目-flutter-sdk2026-09-12)，升级决定见 ADR0020。不要使用机器全局旧版 Flutter，也不把 SDK 升级当作应用已安装更新。
- Mac 调试与界面验收默认不抢前台：行为规则见根 [AGENTS.md](../../AGENTS.md)。代码生效与 MCP 校验、热重载／热重启、构建／安装及外观／性能的选择，唯一依据是根 [README.md 项目宪法第 7 条](../../README.md)，本页不复制流程。
- 根说明与项目宪法：`README.md`
- Flutter 文档库：`apps/aicove_flutter/docs/README.md`；涉及界面读 `apps/aicove_flutter/docs/界面布局说明.md`，`公共组件总览.md` 只查用到的组件章节
- 云端说明：`cloud_backend/README.md`
- 回查历史对话原文：`trellis mem search <关键词>`（全局 CLI，读取各 agent 自己的会话日志）
