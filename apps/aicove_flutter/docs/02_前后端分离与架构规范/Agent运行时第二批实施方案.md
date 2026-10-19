# Agent 运行时第二批实施方案：内置插件迁移、声明式包与后台收拢

> 状态：2026-10-12 用户确认（第 9 节三项按推荐），2a、2b 已实施并通过审查；2c（2c-1～2c-11）代码完成并经审查，Mac 实机检查待渠道恢复；2d～2g 代码完成，2d～2f 经 Codex 六轮只读复审，10-13 结论有条件通过（唯一 P3 已修）；2f 待手机补验，见第 10 节。
> 决策依据：[ADR0064](../../../../docs/项目记忆/决策记录/0064-Dart微内核Agent运行时与全插件化.md)「分批」第 ② 批；[ADR0060](../../../../docs/项目记忆/决策记录/0060-Agent统一装配与前后台调度分离.md)（统一装配、收拢后台自拼请求）；[ADR0063](../../../../docs/项目记忆/决策记录/0063-插件请求前提醒钩子.md)（请求前提醒钩子，本批实施）；ADR0073（引导 Agent，proposed，本批为它提供插件接口）；ADR0017／0044／0054／0072（上下文过滤、语义标签、标签说明、MCP 连接器）。
> 前置：[第一批方案](../05_历史归档/20261016_文档库修订/Agent运行时第一批实施方案.md)。第一批的 Mac 实机开开关验收尚未完成；本批 2a～2c 不依赖它，2d 与引导 Agent 依赖内核默认打开（见 4 节）。

## 1. 现状：插件接口有，但装配核心认识每一个插件

| 部件 | 位置 | 现状 |
|---|---|---|
| 旧插件接口 | `features/plugins/domain/plugin.dart`（179 行）＋ `base_plugin.dart` | 生命周期、`getSystemPrompt`、`getTools`、`processResponse`、`getCommands`、`getHooks`；`getHooks` 无实现者、无调用方（ADR0063） |
| 内置插件 | `features/plugins/{image,tts,memory,sticker,time_awareness,trigger,web_search,mcp}` | 8 类，全部实现旧接口；MCP 每个连接器一个插件实例 `mcp:<id>`（ADR0072） |
| 插件管理 | `features/plugins/plugin_manager.dart`（349 行） | 初始化、启停、收集工具／命令／钩子；无贡献所有权、无服务容器 |
| 内核宿主 | `packages/aicove_agent_kernel/lib/src/plugin_host.dart`、`scope.dart` | 第一批已有：`KernelPlugin`＋`PluginRegistrar`（只开放 `tool`、`contributor`）、按所有者撤销、run 快照、`ServiceKey` 服务容器；**App 内尚无插件经它注册** |
| 请求装配 | `chat_send_backend_service.dart` `_prepareApiConfig`（第 373–540 行） | 按 `is ImagePlugin／TtsPlugin／StickerPlugin／TimeAwarenessPlugin` 逐个复制“请求快照”；时间感知提醒、画图失败提醒、输出标签提醒、快速路线剔除 `draw_image`、角色绑定生图工具预设都写死在核心 |
| 提示词／工具收集 | `chat_plugin_context_builder.dart`（305 行） | `getEffectivePlugins`（「全部插件」排除 MCP）；拼提示词时对 `ImagePlugin`、`MemoryPlugin` 特判 |
| 回复后处理 | 旧 runner 第 1053–1084 行（内核路径复用）；`chat_send_service.dart:276–295`（缓存回复路径，单独再写一遍并对 `TtsPlugin` 特判） | 两处各自遍历插件 |
| 酒馆兼容 | `features/agent_context/{domain/silly_tavern_*,infrastructure/quickjs_preset_runtime.dart}` | 不是插件，由装配与第一批 ①②③ 阶段直接调用 |
| 后台自拼请求 | `features/auto_reply/data/background_service.dart` `_fetchAiReply`（第 793 行起，Workmanager isolate） | 自取最近消息、自写提示词、`http.post` 直连供应商；ADR0060 点名收拢 |
| 第二套配方 | `features/background_agent/domain/background_context_spec.dart` | 被记忆 Agent、摘要、主动分析器使用；ADR0060 要求并入 `ContextProfile` |
| Agent 契约 | `features/agent_context/domain/agent_runtime_contracts.dart` | `AgentDefinition`（含 `allowedToolNames`、`deliveryChannel`）、`ContextProfile`、权限集合；`proactiveSpecialized` 无调用方 |

**结论**：第二批的本质是把“核心认识插件”反转为“插件向核心贡献”。和第一批一样以等价迁移为主，每一步用请求副本与结果的差分测试兜底；新增行为只有两类：ADR0063 已决定的提醒钩子，以及为 ADR0073 准备的工具授权与撤销能力。

## 2. 目标与不做

**目标**

1. 新插件接口（下称 v2）：插件只通过注册器贡献内容与服务；装配核心、发送链路、后台链路不再出现具体插件类型判断。
2. 8 类内置插件与酒馆兼容迁到 v2，与第三方（MCP、声明式包，以后的脚本插件）走同一注册器。
3. ADR0063 请求前提醒钩子落地，删除 `LLMHook`／`LLMHookManager` 死代码。
4. 工具元数据、授权闸门、可撤销修改日志、密钥不出上下文——这是引导 Agent 的最低接口，本批建好并用假插件测试，不实现引导 Agent 本身。
5. 声明式包 v1：提示词片段、语义标签、技能（Markdown）三类内容，导入后成为 `pkg:<id>` 插件。
6. 收拢后台：`_fetchAiReply` 改走统一装配＋内核；`BackgroundContextSpec` 并入 `ContextProfile`；顺带修 ADR0060 记录的认领不释放与提前标记 `fired`。
7. 适配器暴露结束原因，内核按 `tool_calls` 结束原因才执行工具（第一批推迟到本批的目标态）。

**不做（本批）**

- 不做 QuickJS 脚本插件、对外安装与插件市场（第三批）。
- 不做插件自定义设置页／聊天内组件的声明式界面（ADR0064 的界面扩展，等第三批有第三方需求再定格式）；现有插件设置页保留。
- 不做 ADR0060 的统一事件流替换 `onStreamTextDelta` 等回调；不接聊天“停止”按钮；不做工具级强制取消。
- 不改数据库 schema、不改云同步／局域网同步契约；插件配置键（`aicove.plugins.*`）与预设绑定（ADR0008／0009／0054）原样读取。
- 不实现引导 Agent 的系统联系人、教程与具体工具（ADR0073 另立方案）。

## 3. 设计

### 3.1 分层与目录

| 位置 | 内容 | 依赖 |
|---|---|---|
| `packages/aicove_agent_kernel/` | 新增：`ToolEffect`、`ToolGate`、`ApprovalPort`、`ChangeJournal` 接口、`SecretRedactor`、闸门事件；扩展 `KernelCapability` 与 `PluginRegistrar` | 仅 Dart SDK |
| `lib/src/features/agent_plugins/`（新） | v2 接口 `AicovePlugin`、App 侧注册器扩展、`PluginRequestContext`、贡献类型、`LegacyPluginAdapter`、装配步骤 `PluginContributionStep`、声明式包加载 | Flutter、现有 features |
| `lib/src/features/plugins/*` | 各插件实现原地改为 v2；旧 `domain/plugin.dart` 在 2c 末删除 | 不变 |

内核只放“执行循环必须知道”的东西（工具执行前闸门、撤销记录、脱敏）；提示词、提醒、回复后处理处理的是 App 消息与设置类型，留在 App 侧。

### 3.2 v2 插件接口

```text
AicovePlugin
  id / name / icon / exposure            // 静态元数据
  capabilities: Set<KernelCapability>    // 声明，未声明的注册被拒（第一批已有机制）
  setup(AppPluginRegistrar r)            // 启用时调用；停用时按所有者全部撤销
```

注册器在第一批 `tool`、`contributor` 之上增加：

| 贡献 | 能力名 | 用途（替代的旧逻辑） |
|---|---|---|
| `service(key, impl)` | `services` | 向作用域提供服务（记忆检索、TTS 合成器、生图客户端、预设运行时） |
| `requestSnapshot(fn)` | `request` | 每次请求开始时由插件自己根据 `PluginRequestContext` 产出本次快照（替代核心里 `is ImagePlugin ? ImagePlugin(...)` 的复制链） |
| `prompt(fn)` | `prompts` | 系统提示词片段（替代 `getSystemPrompt`；`ImagePlugin`／`MemoryPlugin` 的特判参数改由 `PluginRequestContext` 提供） |
| `reminder(fn)` | `reminders` | ADR0063 请求前提醒，只读输入、只返回文字；出错 `optional` |
| `tool(KernelTool, effect:, exposure:)` | `tools` | 工具＋元数据（3.4） |
| `toolFilter(fn)` | `tools` | 按本次请求收窄自己的工具（快速生图路线剔除 `draw_image`） |
| `responseProcessor(fn)` | `responses` | 回复后处理（替代 `processResponse`，两条调用路径共用一个遍历器） |
| `contentTags(decls)` | `tags` | 经 ADR0044 `content_tags` 注册表声明标签，说明文字仍取全局一份（ADR0054） |
| `contextFilter(fn)` | `contextFilter` | ADR0017 插件关闭时屏蔽对应标签与工具对；MCP 的成对移除并入此处 |
| `command(handler)` | `commands` | 斜杠命令（替代 `getCommands`） |

`PluginRequestContext`（只读）：会话与角色、`history`（DB raw 派生的只读视图，ADR 真相源不变）、设置快照、模型能力（视觉、工具调用）、生图有效路线（快速／稳定）、`requestTime`、`agentId`、角色自定义绘图提示词、是否含内部图片上下文。核心只负责“按固定顺序收集与放置”，顺序沿用现在插件管理器的注册顺序，保证请求副本逐字不变。

**暴露范围 `exposure`**（统一现有「全部插件」与 MCP 显式开启两套规则）：

| 值 | 含义 | 例 |
|---|---|---|
| `roleDefault` | 角色选「全部插件」时包含 | 现有内置插件 |
| `roleExplicit` | 只有角色显式开启才包含 | MCP 连接器（ADR0072）、声明式包 |
| `agentOnly(ids)` | 只对指定 `AgentDefinition` 可见，角色界面不列出 | 引导 Agent 的体检／设置工具 |

### 3.3 装配：核心只剩“收集→放置”

`_prepareApiConfig` 的插件段替换为一个 `PluginContributionStep`：

1. 按暴露范围与角色开关求出本次插件集合（`getEffectivePlugins` 的规则原样迁入）。
2. 逐个调用 `requestSnapshot`，得到本次快照（相当于第一批的 run 快照，运行中改配置不影响本次）。
3. 收集 `prompt`、`reminder`、`tool`＋`toolFilter`、`contextFilter`，按现有顺序放置：提醒合并后仍按“无预设插在最后一条用户消息前／有预设走预设路径”（ADR0063 放置规则不变）。
4. `buildOutputTagReminder` 改为各插件声明“启用时贡献哪个输出标签提醒”，核心只合并；预设标签部分仍归酒馆兼容插件。
5. `_applyRoleBoundDrawImageToolPreset` 移入生图插件的 `requestSnapshot`。

验收以“请求副本逐字一致”为准（5 节 B 组），同时 `grep` 断言装配与发送目录不再出现 `is ImagePlugin|TtsPlugin|StickerPlugin|TimeAwarenessPlugin|MemoryPlugin`。

注意：`_prepareApiConfig` 在 runner 之前执行，**新旧 runner 都会走新装配**，不受 `AICOVE_AGENT_KERNEL_CHAT` 开关保护；所以 2b 必须先建好黄金请求副本再改，回滚靠 git 还原（6 节）。

### 3.4 工具元数据、授权闸门与撤销（为 ADR0073 准备）

**工具效果 `ToolEffect`**（注册时必填，旧工具经适配器默认 `external`）：

| 值 | 含义 | 手动允许模式下 |
|---|---|---|
| `readDiagnostic` | 只读诊断白名单数据（编号、计数、耗时、状态，ADR0065） | 直接放行 |
| `readPrivate` | 读聊天正文、记忆、角色设定等隐私内容 | 每次询问 |
| `write` | 可撤销的设置／配置修改 | 每次询问 |
| `destructive` | 删除类 | 每次询问，并先备份 |
| `external` | 对外部服务产生副作用（生图、联网搜索、MCP） | 由 Agent 定义决定（普通聊天沿用现状：放行） |

**闸门 `ToolGate`**（内核 ⑦ `ToolBatchExecutor` 在 `executeOne` 前调用）：输入工具调用、效果、`agentId`；返回 `allow`／`deny(原因)`／`ask(说明)`。`ask` 经 `ApprovalPort` 交给界面（一次一问，带工具名、参数摘要与影响说明），超时或拒绝都转为结构化工具结果“用户未允许：…”写回模型，循环继续，不抛异常；取消信号到达时等待中的询问直接按拒绝结束。

- 闸门策略由 `AgentDefinition` 提供（新增字段 `toolPolicy`）：普通聊天 = 全部放行（行为不变）；引导 Agent = 两种授权模式（手动允许：仅 `readDiagnostic` 放行；无限制：全部放行，但 `write`／`destructive` 照样写撤销记录）。
- 每次闸门决定发出 `toolGated` 事件，只带工具名、效果、决定枚举与关联编号，进诊断白名单，不带参数正文。
- 闸门只在内核路径生效。旧 runner 不加闸门：本批只有 `agentOnly` 工具需要闸门，而引导 Agent 只跑内核（ADR0073 决定 2）；普通聊天里没有需要拦的工具，行为与现在一致。

**撤销记录 `ChangeJournal`**：

- `write`／`destructive` 工具不直接改设置，而是经 `ReversibleChange` 接口提交：先读当前值存快照，再写新值，返回记录编号；删除类先把被删对象完整导出到备份再删。
- 日志存本机应用支持目录下的 JSON 文件（只存最近 N 条，默认 50），**不进数据库、不随同步**；撤销 = 把快照写回并记录一条反向操作。选文件而不是新表，是为了本批不做 schema 迁移；若引导 Agent 方案需要跨设备撤销再议。
- 内核只定义接口与调用时机；具体快照实现由提供可改设置的插件给出（设置服务以 `service` 注册）。

**密钥不进上下文**：

- 需要密钥的工具通过服务“使用”密钥（例如“用当前渠道测一次连通性”），工具结果只返回结论。
- 内核在工具结果写回前统一经 `SecretRedactor`：已登记的密钥值（模型渠道 `api_keys`、MCP 令牌、联网搜索密钥、同步凭证）在结果中替换为 `［已隐藏］`；登记来源由各插件的服务提供。这是兜底，不替代“工具本身不返回密钥”的约束。

### 3.5 酒馆兼容作为内置插件

酒馆兼容插件以 `service` 注册第一批里已搬入内核的预设阶段实现（①预设 prepare、②reset 与传输预览、③响应解包、run 初始化中的预设工具与 `toolChoice`），并贡献预设标签提醒与 `contextFilter`。阶段内部逻辑**不改**，只是由“装配直接调用”改为“从作用域取服务”；绑定解析仍按请求 owner（ADR0042／0043），明确绑定缺失不静默回退。MVU 变量（ADR0071）随预设开关走，不单列插件（用户 10-09 裁决）。

### 3.6 声明式包 v1

- 格式：一个目录或 zip，根部 `aicove-package.json`：`{schema: 1, id, name, version, contents: [...]}`；内容项三类：`prompt`（文本片段＋放置位置：系统提示词尾部）、`tags`（ADR0044 标签声明：名称、类别、可选包裹规则）、`skill`（Markdown 文件，作为可按名读取的说明文档，经一个只读工具 `read_skill` 提供给模型）。
- 不能包含任何可执行内容（脚本、正则替换回复、HTML 渲染），解析时遇到未知字段整包拒绝，避免“看起来声明式、实际在执行”。
- 导入后存本机 `Documents/aicove/packages/<id>/`，成为插件 `pkg:<id>`，暴露范围 `roleExplicit`；删除包即撤销其全部注册项。是否随同步：本批不同步（同步契约不在范围），与酒馆预设原件同口径再议。
- 现有酒馆预设、生图／音色预设不改为声明式包（它们已有各自的导入与绑定），v1 只承载新内容类型。

### 3.7 后台收拢（ADR0060）

- `_fetchAiReply` 删除：后台主动回复改为构建一个“无界面装配”——在 Workmanager isolate 内用 `ProviderContainer` 加覆盖项，仅依赖 DB、设置与配方，调用同一个 `prepareApiConfig`（`ContextProfile` 选 `proactiveSpecialized`，`AgentDefinition` 声明投递通道为前台会话原文、带来源标记），再交给内核 runner。
- `BackgroundContextSpec` 并入 `ContextProfile`：新增 `conversationWindow` 层参数（最近 N 条、角色过滤、是否带时间戳）；已保存的后台 Agent 定义按旧字段兼容读取，写回用新字段。
- 顺带修复两处中断缺口：执行权认领改为带过期时间的租约，进程被杀后过期自动释放；任务状态改为“送达后才标记 `fired`”，送达前崩溃会在下次调度重试，并用消息来源编号去重，防止重复发送。
- 平台：Workmanager 只在手机端运行，本步需要手机补验（项目宪法第 7 条手机专属能力）；Mac 上用同一入口函数的单元／集成测试覆盖装配与去重。

### 3.8 结束原因

`SendMessageRichResult` 增加归一化的 `finishReason`（`stop`／`toolCalls`／`length`／`contentFilter`／`unknown`），三家适配器各自映射（OpenAI `finish_reason`、Claude `stop_reason`、Gemini `finishReason`）。内核 ④ 在 `finishReason` 为 `stop`／`length` 却带工具调用时记录诊断事件；**是否据此拒绝执行工具**放到本步最后、在真实三家各跑一次后决定，避免某家把工具调用标成 `stop` 导致工具全部失效。

## 4. 分步交付

| 步 | 内容 | 依赖 | 验收 |
|---|---|---|---|
| 2a | 内核：`ToolEffect`、`ToolGate`、`ApprovalPort`、`ChangeJournal` 接口、`SecretRedactor`、`toolGated` 事件、注册器新能力；App：v2 接口、`AppPluginRegistrar`、`PluginRequestContext`、`LegacyPluginAdapter`（把现有 8 类插件原样包成 v2）、`PluginRuntime`（App 作用域内的内核 `PluginHost`） | 无 | A 组全绿；内核包 `dart test` 不经 Flutter；现有聊天、记忆、主动关怀离线测试不变 |
| 2b | 装配反转：`PluginContributionStep`；ADR0063 提醒钩子；输出标签提醒改插件声明；回复后处理两条路径共用；删除 `LLMHook`／`LLMHookManager` | 2a | B 组：黄金请求副本逐字一致（有／无预设、快速／稳定生图、工具多轮、超限重试）；核心类型判断 `grep` 为零；假插件只改插件侧即可让提醒出现 |
| 2c | 逐个把插件从适配器改为原生 v2：时间感知 → 表情包 → 联网搜索 → TTS → 记忆 → 生图 → 主动关怀 → MCP → 酒馆兼容；最后删除旧 `Plugin` 接口与适配器 | 2b | 每迁一个跑该插件相关离线测试＋B 组；全部迁完后 C 组；Mac 窄屏实机：生图快速／稳定、TTS、联网搜索、预设传输各一次 |
| 2d | 闸门与撤销接入内核 ⑦；`AgentDefinition.toolPolicy`；`ReversibleChange` 的设置实现；假“管家”插件（`agentOnly`，含 `readDiagnostic`／`write`／`destructive` 各一个工具）端到端测试 | 2a；内核默认打开或测试中显式用内核 | D 组 |
| 2e | 声明式包 v1：解析、导入、删除、`read_skill` 工具 | 2a | E 组 |
| 2f | 后台收拢：`_fetchAiReply` 删除、无界面装配、`BackgroundContextSpec` 并入 `ContextProfile`、租约认领与送达后标记 | 2b | F 组；手机补验一次真实后台主动消息 |
| 2g | 结束原因暴露与诊断；按真实三家结果决定是否收紧执行 | 无 | G 组 |

2a→2b→2c 是主线，必须按序；2d、2e、2g 只依赖 2a，可在主线间穿插；2f 依赖 2b。每步单独提交、单独可回滚。

**内核默认打开**：1c 实机验收通过后，建议在 2c 开始前讨论默认打开 `AICOVE_AGENT_KERNEL_CHAT`／`BG`；2d 的闸门只在内核路径生效，引导 Agent 动工前内核必须已默认打开。旧 runner 的删除仍另立任务。

## 5. 测试清单

**差分方法**：沿用第一批。2b 前先在当前代码上生成黄金请求副本（固定时间、固定设置、固定历史），之后每一步逐字比较；结果侧比较 `ApiCallResult` 字段。已知旧缺陷单独登记。

**A 组（2a，内核纯 Dart＋App 适配器）**

1. 新能力：未声明 `prompts`／`reminders`／`services` 等能力的注册被拒；同名工具报错；停用后下次 run 撤销、重新启用恢复。
2. `RunSnapshot` 携带工具效果；`agentOnly` 工具不出现在普通请求的快照里。
3. 适配器：8 类插件经 `LegacyPluginAdapter` 产出的提示词、工具 schema、回复处理结果与直接调用旧接口一致。
4. `SecretRedactor`：登记的值在工具结果中被替换；未登记的不动；空串不登记。

**B 组（2b，装配差分）**

1. 黄金请求副本逐字一致：无预设／有预设（含 Kemini 传输）、快速／稳定生图、TTS 开关、时间感知开关、画图失败提醒有／无、MCP 开启／未开启（成对移除）。
2. ADR0063 验收 1～5：时间固定逐字一致；核心无插件类型判断；假插件只改插件侧即生效；某提醒抛错其余照常；afterResponse 死代码删除、`analyze` 通过。
3. 回复后处理：runner 路径与缓存回复路径（`chat_send_service.dart`）结果一致，含 TTS 快照。
4. 请求快照：准备后修改插件配置不影响本次请求。

**C 组（2c）**：每个插件原有测试全绿；旧接口删除后 `analyze` 零告警；声明能力最小化（每个插件只声明实际用到的能力）的断言测试。

**D 组（2d，闸门与撤销，用假管家插件）**

1. 手动允许模式：`readDiagnostic` 直接执行；`readPrivate`／`write`／`destructive` 触发询问；允许后执行、拒绝／超时后模型收到“用户未允许”结构化结果且循环继续。
2. 无限制模式：不询问，但 `write` 产生撤销记录、`destructive` 先备份。
3. 撤销：执行 `write` 后撤销，设置恢复原值；连续两次修改按逆序撤销；撤销本身记录反向操作。
4. 取消：询问等待中取消 run，询问按拒绝结束，资源恰好释放一次。
5. 密钥：工具故意把渠道密钥写进结果，写回模型前被替换。
6. 普通聊天：闸门策略为全部放行，现有差分测试（第一批 B／C 组）不变。
7. `toolGated` 事件只含白名单字段（工具名、效果、决定、编号）。

**E 组（2e）**：合法包导入后提示词／标签／技能生效；含未知字段或可执行内容的包被整包拒绝；删除包后下一次请求不再出现其内容；角色未显式开启时不生效。

**F 组（2f）**：无界面装配在不建 UI 的测试中仅凭 DB 与设置跑通；主动回复请求副本与前台同角色装配的差异只来自配方（`proactiveSpecialized`）；租约过期自动释放；送达前崩溃重试且不重复发送；旧 `BackgroundContextSpec` 定义可读。

**G 组（2g）**：三家适配器结束原因映射单测；真实 DeepSeek Flash 跑一次带工具与不带工具，记录结束原因；其余两家有可用渠道时各补一次，无渠道则记为缺口。

## 6. 回滚

- 2a、2d、2e 为新增代码，删除即回滚；2d 对普通聊天的唯一改动是“闸门全部放行”，可单独还原。
- 2b、2c 改的是装配主链路，**不受内核开关保护**，按步单独提交，回滚 = 还原该步提交；不涉及数据格式，插件配置键不变。
- 2f 改后台主动消息：租约与“送达后标记”涉及本地任务状态的读写方式，回滚时旧代码仍能读新写入的状态（保留旧字段写入一个版本）。
- 2g 只加字段与诊断；收紧执行若做，单独一个提交。

## 7. 已知风险

| 风险 | 处理 |
|---|---|
| 装配反转后请求副本细微变化（顺序、空行），影响模型行为与前缀缓存（ADR0067） | 黄金副本逐字比较；顺序沿用注册顺序 |
| 插件快照语义与现有 `ImagePlugin(isRequestSnapshot: true)` 等不完全等价 | 2c 每个插件迁移时以 B 组差分为准，不一致以旧行为为基线 |
| 无界面装配在 Workmanager isolate 里缺依赖（插件初始化、QuickJS 原生库） | 2f 先写 isolate 内装配的集成测试；QuickJS 预设在后台默认不启用（与现在后台不带预设一致，见第一批 1b） |
| 闸门询问阻塞运行，用户长时间不响应 | 询问带超时，超时按拒绝；引导 Agent 方案再定具体时长 |
| 撤销日志存文件，多端不同步 | 本批明确只撤销本机修改；跨设备另议 |
| 某家供应商结束原因不可靠 | 2g 先只记诊断，真实验证后再决定是否收紧 |

## 8. 对 ADR0073 的接口承载

| ADR0073 需要 | 本批提供 |
|---|---|
| 工具以内置插件贡献点接入 | v2 注册器 `tool(effect:, exposure: agentOnly)`（3.2、3.4） |
| 只读体检（慢在哪、工具为何未生效） | `readDiagnostic` 效果＋ADR0065 白名单；数据来自 `TraceQueryService`、`ApiLogger` 耗时，由引导 Agent 方案定具体工具 |
| 可撤销的设置修改 | `ReversibleChange`＋`ChangeJournal`（3.4） |
| 手动允许／无限制两种模式按授权拦截 | `ToolGate`＋`ApprovalPort`＋`AgentDefinition.toolPolicy`（3.4） |
| 密钥只“使用”不进上下文 | 服务化使用＋`SecretRedactor` 兜底（3.4） |
| 独立的 `AgentDefinition`，不是角色卡 | 沿用现有 `AgentDefinition`，新增 `toolPolicy`；系统联系人与界面属引导 Agent 方案 |

## 9. 架构选择（2026-10-12 用户确认按推荐执行）

1. **声明式包默认需角色显式开启**（同 MCP）。理由：包里的提示词会改变角色行为，默认混入「全部插件」会让用户难以察觉来源；代价：用户导入后要多点一次开启。
2. **撤销日志只存本机文件、不进数据库、不同步**。理由：本批不做 schema 迁移，管家修改大多是本机设置；代价：在 A 设备上的修改不能在 B 设备上撤销。
3. **授权闸门只在内核路径实现，不给旧 runner 补**。理由：旧 runner 将被删除，引导 Agent 只跑内核；代价：内核默认打开前，引导 Agent 不能上线。

## 10. 实施记录

**2a（2026-10-12）**

| 方案原文 | 实际做法 | 原因 |
|---|---|---|
| 注册器扩展一组 App 贡献（提示词、提醒、快照、过滤、标签等） | 内核只加通用机制：`KernelCapability` 改为可由宿主扩展的 const 类（按身份比较），`PluginRegistrar.service`／`add(ContributionKey, value)`，`RunSnapshot.contributionsOf`；App 侧本步只定义适配器用得到的四种贡献（`prompt`、`requestTools`、`response`、`command`） | 提醒、请求快照、工具过滤、标签、上下文过滤等在 2b 迁移装配时按真实用法再加，避免先定没人用的接口 |
| `tool(KernelTool, effect:, exposure:)` | `KernelTool` 增加 `effect`（默认 `external`）与 `agentIds`（null＝所有 Agent）；`snapshot(agentId:)` 过滤；角色层的 `roleDefault`／`roleExplicit` 是插件级属性，放在 App 的 `PluginExposure` | 工具可见范围是内核运行时决定，角色开关是 App 装配决定 |
| 闸门接入 ⑦ 放在 2d | 2a 已在内核实现 `GatedToolExecutor`（装饰任意 ⑦ 执行器；需询问的批次改串行；拒绝／超时／取消转结构化错误结果；发 `ToolGated` 事件）与 `RedactingToolExecutor`；2d 只做 App 接线（`AgentDefinition.toolPolicy`、界面询问、设置撤销实现） | 纯 Dart 逻辑在内核包里测试最直接 |
| 插件贡献顺序沿用注册顺序 | `PluginRuntime.contributions` 按插件**安装**顺序排序，同插件内按注册顺序 | 重新启用会把注册项排到末尾，按安装顺序才能保证 2b 请求副本逐字不变 |
| `LegacyPluginAdapter` 原样包装 | 生图、记忆两处提示词特判从装配核心搬进适配器；MCP 连接器映射为 `roleExplicit` | 2c 插件原生化后随适配器删除 |

**验证**：内核包 `dart analyze` 无问题，`dart test` 37 项通过（新增 11 项：能力拒绝、贡献顺序与快照、停用撤销服务、Agent 专属工具可见性、闸门放行／拒绝／询问批准／拒绝／超时／无询问通道／取消、批次串行、全放行、脱敏）；App 侧 `test/features/agent_plugins` 4 项通过；`test/features/chat`、`plugins`、`background_agent`、`agent_plugins` 共 795 项通过，1 项失败为既有问题（`conversation_timeline_paging_test`，新旧执行器下都失败，已另开任务）。本步未接入发送链路，运行行为不变。

**前台内核默认打开（2026-10-12，用户确认）**：`AICOVE_AGENT_KERNEL_CHAT` 默认 `true`，构建时传 `=false` 回退旧执行器；后台开关仍默认关。

**2b（2026-10-12）**

| 方案原文 | 实际做法 | 原因 |
|---|---|---|
| 新建 `PluginContributionStep`，按贡献类型（`prompt`、`reminder`、`tool`＋`toolFilter` 等）分别收集 | 每个插件只贡献一个 `AppContributions.requestScope` 工厂：装配开始时用 `PluginRequestInputs`（本次设置、生图配置、语音请求、全局提示词、历史、请求时刻、路由、工具支持等）建出本次 `PluginRequestScope`，由它回答 `prompt`／`reminders`（带 `order`）／`tools`／`rewriteToolSchemas`／`outputTags`／`disablesBuiltinWebSearch`；2a 的 `prompt`／`requestTools`／`response` 三个键删除 | 同一插件的各项贡献依赖同一份请求快照（例如生图失败提醒会改变生图提示词），一个范围对象比一组互不相知的回调更不容易错位 |
| 输出标签提醒由插件声明、核心合并 | 核心持有固定措辞与顺序的 `OutputTagHint`（`imageInline`／`imageTool`／`tts`），插件只声明本次适用哪几项；预设标签部分仍在核心，2c 随酒馆兼容插件迁出 | 保持提醒文本逐字不变 |
| ADR0063 提醒钩子 | `collectPluginReminders`：按 `order` 排序（时间感知 10、生图失败 20），同 `order` 保持插件顺序，空提醒丢弃；`reminders()` 抛错只记日志并跳过该插件，不阻断请求（旧代码会抛出）。生图失败提醒在建范围时算一次（提示词与提醒要一致），出错同样记日志并按“无失败提醒”处理 | 提醒是辅助信息，不应让一次发送失败 |
| `_applyRoleBoundDrawImageToolPreset` 移入生图插件 | 移到 `plugins/image/draw_image_tool_schema.dart` 的 `applyRoleDrawImageToolPreset`，由生图范围的 `rewriteToolSchemas` 在稳定路由时调用 | 同方案 |
| 提示词／工具收集的刷新窗口重试 | `ChatPluginContextBuilder` 改为按来源收集（`buildPromptEntries(List<PluginPromptSource>)`、`collectToolsWithRetry(List<PluginToolSource>)`），重试、日志与条目语义不变；不再认识具体插件类型 | 核心只剩“收集→放置” |
| 插件集合求法 | `PluginRuntime.fromLegacy(pluginManager.getAllPlugins())` 每次请求按当时全局开关镜像，`selectForRole` 按 `PluginExposure` 复现 `getEffectivePlugins` 规则 | 2c 前插件仍由 `PluginManager` 持有，镜像成本可忽略 |
| 删除 `LLMHook`／`LLMHookManager` | 已删除（含 `Plugin.getHooks`、`PluginManager.getHooksByType`），无任何调用方 | 同方案 |
| 回复后处理两条路径共用；`grep` 断言装配与发送目录无插件类型判断 | **移到 2c**。请求装配段已无类型判断；剩余 3 处都在发送执行阶段（`executeApiCall` 的生图／TTS 快照、`chat_send_service` 缓存回复路径的 TTS 快照），连同 trace 构建器里对时间感知插件的判断，随 2c 插件原生化一起处理 | 这些路径需要 v2 的回复处理贡献，2b 只反转请求装配 |

**验证**：新增 `request_assembly_golden_test`（9 个场景：全部插件稳定／快速／不支持工具的模型、无插件、仅生图、生图失败提醒、绑定预设、MCP 启用／未启用；固定请求时钟），在 2b 改动前生成黄金副本，改动后逐字一致；`test/features/agent_plugins` 7 项（含假插件提醒排序、提醒抛错隔离、记忆会话 ID 透传、角色选择与 MCP 显式开启、安装顺序）；内核包 37 项通过；`flutter analyze` 无新增问题。全量 `flutter test` 2811 项通过，14 项失败均为既有问题（在 2a 之前的 `f3aa41268` 上同样失败：聊天多选／绘图配置菜单／手机悬浮控件／绘图预设界面／备份导入布局等界面测试、`conversation_timeline_paging_test`、需本地后端环境变量的 `cloud_sync_contract_test`）。

**2a／2b 审查修订（2026-10-12）**

Codex 服务不可用，由用户另调 Agent 只读审查（结论：不通过）。逐条核实后处理如下：

| 审查问题 | 处理 |
|---|---|
| 批准后、执行前取消，工具仍会执行 | `GatedToolExecutor` 在发事件前后各检查一次取消，未开始的调用一律按“已取消”返回；补测试（事件观察期间取消，handler 调用 0 次） |
| 短密钥被静默忽略 | 去掉最小长度，除空白外登记即遮盖；测试改为断言短值也被遮盖 |
| 询问同步抛错未转拒绝；超时／取消后询问不撤回 | 询问创建纳入错误边界；`ApprovalRequest.withdrawn` 在超时、取消或询问失败时完成一次，正常应答时永不完成，界面据此关闭提示；补三项测试 |
| 停用后保留的注册器还能注册 | 注册器只在本次同步 `setup` 期间有效，之后调用抛错；补测试 |
| 脱敏只处理 `content`，App 续轮读 `payload` | 内核注释写明 `payload` 不经脱敏；**2d 接线前置条件**：模型可见的工具结果唯一来源是 `KernelToolResult.content`，续轮编码不得从 `payload` 取正文，并加完整续轮请求断言 |
| 黄金测试覆盖不足 | 增加 `tts_enabled`（假语音应用返回已启用的请求语音）与 `web_search_takeover`（可用供应商＋接管内置搜索），快照增加 `disableBuiltinWebSearch`；11 份黄金副本在 2b 之前的代码上生成，在 2b 之后的代码上逐字一致。仍未覆盖：角色专属绘图要求、Kemini 传输、工具多轮、超限重试、trace 插件列表——这些由既有专项测试（绘图绑定快照、runner 差分与多轮）提供证据，方案 B 组不算全部由黄金测试完成 |
| 黄金测试依赖本机时区 | 固定时刻改为 UTC，`TZ=UTC` 与本机时区下均通过 |
| 取时提前 | `requestTime` 移回历史组装之后读取（与 2b 前一致），通过 `reminders(requestTime)` 传入；`PluginRequestInputs` 不再带请求时刻 |
| 新增命令初始化错误面 | 适配器收集命令时出错只记日志并跳过，插件仍参与请求；补测试 |
| 快速路由过滤与稳定路由 schema 重写由生图插件发起 | 快速路由过滤只作用于生图插件自己的工具；稳定路由重写由生图范围发起，但仍处理全部插件的 schema 集合、按名称 `draw_image` 匹配，不区分来源。现有只有生图插件贡献该名称，工具集合等价。请求路径的工具直接从各插件范围收集，不经 `PluginHost` 的重名检查；2c 插件原生化、工具改走内核注册时随之获得重名拒绝，在此之前不做来源隔离 |
| “每个范围配置固定”表述过强 | 只有生图、TTS、表情包、时间感知在建范围时做配置快照，其余旧插件仍读实时状态，2c 原生化时补齐；代码注释已同步 |

**验证**：内核包 41 项通过（新增 4 项）；`test/features/agent_plugins`、黄金测试、构建器测试共 27 项通过，黄金测试在 `TZ=UTC` 下同样通过；`test/features/chat`、`plugins`、`agent_plugins`、`background_agent` 共 809 项通过，1 项失败为既有 `conversation_timeline_paging_test`；`flutter analyze` 仅余 2 条既有无关告警。

**复审修订（2026-10-12）**：同一 Agent 复审 `1275f79c9`，结论“有条件通过”，三项条件处理如下：

| 复审问题 | 处理 |
|---|---|
| 事件观察期间取消时，已发出的 `approved` 事件与最终“已取消”结果不一致 | 同一调用补发一条 `cancelled` 事件；约定“同一 `callId` 的最后一条 `ToolGated` 为最终结果”，写入事件注释；测试断言事件序列 `approved → cancelled`、结果为已取消、handler 0 次 |
| 撤回、迟到应答、生图提醒隔离缺测试 | 内核补：同步／异步失败均转拒绝且撤回、超时后与取消后迟到批准都不执行且撤回、批准与拒绝都不撤回；App 补：历史读取即抛错时生图范围仍参与请求、无失败提醒（反向验证：去掉保护后该测试失败） |
| “其它插件同名工具不再被改写”与实现不符 | 已改为如实描述（见上表“由生图插件发起”一行） |

**验证**：内核包 42 项通过；`test/features/agent_plugins` 9 项通过。

**第三轮复审（2026-10-12）**：另一 Agent 只读复审 `568cd5109`，结论**通过**。三项条件全部关闭，撤掉补发事件、撤回保护、生图提醒异常隔离后，对应测试都会失败。2a、2b 审查到此结束。

### 2c 细化（2026-10-12）

**旧接口拆成两部分**：旧 `Plugin` 同时承担两类职责，2c 按职责拆分处理。

- 管理部分（元数据、开关、配置、生命周期、设置页）继续保留。方案“不做插件设置页的声明式界面”，设置页仍然依赖这一部分。
- 执行部分（`getSystemPrompt`、`getTools`、`processResponse`、`getCommands`）全部改由 v2 注册器贡献，2c 末从接口上删除。适配器随之删除。

所以“删除旧 `Plugin` 接口”在本批的落点是删掉执行方法，不删管理接口。

| 步 | 内容 |
|---|---|
| 2c-1 | 执行段收口：<br>• 回复后处理改为 `responseProcessor` 贡献，两条回复路径共用一个遍历器 `runResponseProcessors`。<br>• 运行器入参从 `List<Plugin>` 改为处理器列表。<br>• 工具只从本次请求提供的工具里查找。<br>• Trace 里的时间感知信息改由插件提供。 |
| 2c-2～2c-9 | 按原顺序逐个插件原生化：每个插件自己提供 `AicovePlugin`，请求范围和回复处理器的实现搬到插件目录，适配器里对应的分支随之删除。 |
| 2c-10 | 酒馆兼容插件化（3.5）。 |
| 2c-11 | 删除旧接口的执行方法和适配器，`PluginRuntime` 改为直接安装各插件的 v2 描述。 |

**2c-1 记录**：

| 项 | 做法 | 与旧行为的差异 |
|---|---|---|
| 回复后处理 | 新增 `PluginResponseProcessor`（含 `order`）和 `runResponseProcessors`。旧 runner、内核 runner、缓存回复路径都走同一个遍历器 | 缓存回复路径的语音处理从“按注册顺序排第一”改为“排在最后”，与正常发送一致。语音不再读到其他插件尚未清掉的标签。这是方案 B 组 3 要求的统一 |
| 处理器在准备时固定 | 由 `prepareApiConfig` 按本次绘图、语音快照构建，放进 `ApiConfig.responseProcessors`。执行时不再读取全局插件表，`executeApiCall` 里的生图、语音类型替换随之删除 | 处理器名单在准备时确定，准备后插件开关的变化不影响本轮（B 组 4）。语音快照测试改为验证这一点 |
| 配置拷贝 | 触发提醒注入、自动回复生成的三处 `ApiConfig` 拷贝都转交处理器 | 自动回复生成会多出语音事件和带绘图快照的生图事件，但这些事件不被使用（自动回复只取原文），只影响日志计数。触发提醒路径的生图事件会带上本轮的绘图快照 |
| 运行器入参 | `ApiRunner.executeApiCall` 的 `effectivePlugins` 改为 `responseProcessors`。工具只从 `availableTools`／`config.boundTools` 查找，不再回退到插件 `getTools()` | 前台发送总会传 `boundTools`，后台传空插件列表，生产路径不受影响。测试改为显式传入工具 |
| Trace | `PluginRequestScope.timeContextTrace` 由时间感知范围提供，构建器不再判断插件类型 | 输出字段不变 |

**验证（2c-1）**：新增 5 项测试，覆盖排序、出错隔离、语音排在最后、绘图快照和实时配置两种情况，并断言发送与自动回复目录里没有插件类型判断。把语音排序改回普通后，对应测试失败。`chat`、`plugins`、`agent_plugins`、`background_agent` 四个目录共 826 项通过，1 项失败为既有分页测试。

**2c-2 时间感知原生化**：

- `PluginRequestScope` 不再持有旧插件对象。它改为提供 `pluginId`、`pluginName`、`active`，提示词和工具默认为空。还没迁移的插件经适配器的 `_LegacyScope` 调用旧方法。
- 新增 `ProvidesAgentPlugin` 接口。实现了它的插件由 `PluginRuntime` 直接安装自己的 v2 描述，其余插件仍走适配器。
- 时间感知只声明 `request` 能力，请求范围放在 `time_awareness_agent_plugin.dart`。旧适配器里的时间感知分支已删除；它的回复处理本来就是原样返回，所以不再注册处理器。

验证：黄金请求副本 11 项逐字一致，本机时区与 `TZ=UTC` 下都通过。把提示词改成空，7 项黄金测试失败，说明黄金测试确实走到了新代码。

黄金副本里时间提醒和生图失败提醒从没同时出现，覆盖不到两者的排序，所以另加单测，钉住以下几项：
- 提醒排序值为 10；
- 提示词与快照一致；
- Trace 配置正确；
- 声明的能力最小。

四个目录共 828 项通过，1 项失败为既有分页测试。

**2c-3 表情包原生化**：声明 `request`、`responses` 两项能力。
- 请求范围：用本次请求的模板快照渲染标签提示词。
- 回复处理：作用在注册实例上，与旧适配器一致。

插件里的提示词渲染和标签转换已抽成 `buildSystemPrompt`、`convertStickerTags`，旧方法暂时转调它们，2c-11 删除。`plugin_response.dart` 新增 `ResponseFunction`，用函数直接实现处理器。

验证：
- 黄金副本 11 项逐字一致；把提示词改成空，3 项失败。
- 新增 3 项单测：最小能力声明、模板快照、回复处理结果与旧方法逐项一致。

**2c-4 联网搜索原生化**：只声明 `request` 能力。请求范围直接读注册实例（配置已在实例里，不依赖请求），提供 `web_search`／`web_fetch` 两个工具和「接管模型内置搜索」。回复处理本来就是原样返回，不再注册。

工具仍通过请求范围提供，没有改用内核的 `tool` 注册。原因是请求装配目前按 `AITool` 收集工具；改走内核注册需要同时转换工具类型和收集方式，与 2d 的闸门、工具效果一并处理更合适，届时再统一迁移。

验证：
- 黄金副本 11 项逐字一致。
- 关掉接管或去掉工具，`web_search_takeover` 场景都会失败。
- 新增最小能力声明断言。

**2c-5 语音原生化**：声明 `request`、`responses` 两项能力。注册实例只表示插件可用，请求和回复都使用角色本轮的语音请求快照：

- 请求范围：用带全局 `<tts>` 模板的快照生成提示词，生效时声明 `tts` 输出标签提醒。
- 回复处理：有语音请求时，用 `convertTtsTags` 处理，并排在其他插件之后；没有语音请求时原样返回。

适配器里的语音分支、只给语音用的 `_PlainScope.tags` 和 `PassThroughResponse` 随之删除。

验证：黄金副本逐字一致。以下三处改坏都会被测试抓到：
- 提示词改成空；
- 不声明输出标签；
- 处理顺序不排在最后。

另加最小能力断言。

**2c-6 记忆原生化**：只声明 `request` 能力。请求范围按请求所属会话调用 `buildMemoryPrompt`；没有所属会话时不注入（失败关闭），这一规则不变。记忆插件没有工具，回复处理原样返回，所以不再注册处理器。适配器里的记忆分支删除，原来的会话编号传递测试现在走原生路径；把会话编号改成不传，该测试失败。另加最小能力断言。

**2c-7 生图原生化**：声明 `request`、`responses` 两项能力。原适配器里的 `_ImageScope` 整段搬到 `image_agent_plugin.dart`，逻辑不变，包括：
- 请求快照；
- 失败提醒（排序 20，出错跳过）；
- 按路线组装提示词；
- 快速路线去掉 `draw_image`；
- 稳定路线按名称改写 schema；
- 两种输出标签提醒。

回复处理：有绘图快照时用快照，没有时用注册实例。插件里的内联标签解析抽成 `convertInlineImageTags`。适配器现在只剩「把旧插件原样包装」一条路径，不再有任何按插件类型的分支。

验证：
- 黄金副本逐字一致。
- 提示词改成空、去掉输出标签、去掉失败提醒的异常隔离，都会被现有测试抓到。
- 有两项黄金场景覆盖不到：一是「调用模式为自动、生图路线却是快速」时过滤 `draw_image`（快速模式下插件本身就不提供这个工具）；二是角色有专属绘图要求时改写 schema。为这两项新增单测，撤掉对应逻辑后单测都会失败。
- 另加最小能力断言。
- 四个目录加记忆目录共 846 项通过，1 项失败为既有分页测试。

**2c-8 主动关怀（触发器）原生化**：声明 `request`、`responses`。请求范围提供 4 个提醒工具；回复处理 `handleLegacyTriggerTags` 总是清理旧 XML 标签；只有 XML 兜底开启时才真正增删提醒（规则不变）。两者都读注册实例，与适配器一致。新增单测：最小能力、工具与旧方法一致、回复清理结果一致。

**2c-9 MCP 连接器原生化**：每个连接器自己提供 `AicovePlugin`，只声明 `request`，暴露方式固定为「须角色显式开启」（与适配器按 `mcp:` 前缀判断的结果一致）。请求范围只提供连接器工具，不写提示词，也不处理回复。验证：黄金副本逐字一致；把暴露方式改回默认、或让工具清单返回空，新增单测都会失败，后者 `mcp_enabled` 黄金场景也会失败。

**2c-10 酒馆兼容插件化**：新增内置插件 `tavern_compatibility`，只声明 `services`、`request` 两项能力，暴露方式为新增的 `builtin`：每次请求都包含，角色设置里不列出，是否生效由本次绑定的预设决定。

| 项 | 做法 | 与旧行为的差异 |
|---|---|---|
| 预设运行时 | 插件以 `service` 注册预设运行时的打开函数 `TavernCompatServices.presetRuntime`。准备阶段从插件作用域取出，固定进 `ApiConfig.openPresetRuntime`。两个 runner 都改为用它打开 QuickJS 运行时，没取到时回退到默认实现。预设 prepare、reset 与传输预览、响应解包、预设工具与 `toolChoice` 都是这个运行时对象的方法，阶段内部逻辑不变 | 无 |
| 预设标签提醒 | 由插件范围的 `presetTagNames` 提供，核心只把各范围的结果合并后交给 `buildOutputTagReminder` | 文本逐字不变 |
| 请求副本过滤 | 新增范围钩子 `filterRequestMessages`，在 ADR0017 上下文策略之后依次执行。MVU 更新块清理（ADR0071）搬到这里，与旧行为一样，有没有预设都会执行 | 无 |
| 绑定解析 | 仍由预设端口按请求 owner 一次解析（ADR0042／0043），结果经 `PluginRequestInputs.boundPreset` 交给插件。明确绑定缺失时的处理不变 | 无 |

预设正则（请求侧与回复侧）、世界书和预设组装仍在原位，没有搬进插件；本步只迁移方案 3.5 点名的内容。缓存回复路径不安装该插件，因为它不处理回复。

验证：
- 11 份黄金副本逐字一致；差分测试全部通过。
- 新增插件单测：最小能力、内置暴露、服务随停用撤销、预设标签与 `inferPresetTagMapping` 一致、MVU 清理。
- 新增 runner 测试：两个 runner 都经配置里的服务打开运行时，并且只关闭一次。
- 变异检查：两个 runner 不读服务、预设标签返回空、装配跳过过滤钩子、暴露方式改回默认，都会被测试抓到（装配跳过过滤由既有的 `mvu_request_test` 抓到）。

**2c-11 删除旧执行接口与适配器**：

| 项 | 做法 |
|---|---|
| `Plugin` 接口 | 删掉 `getSystemPrompt`、`getTools`、`processResponse`、`getCommands`，改为要求 `AicovePlugin get agentPlugin`。`ProvidesAgentPlugin` 并入接口后删除 |
| 各插件 | 只做转发的 `getSystemPrompt`／`processResponse` 删除；`getTools` 保留为插件自己的方法，供各自的请求范围调用 |
| 适配器 | 删除 `legacy_plugin_adapter.dart`、`LegacyResponse`。`PluginRuntime.fromLegacy` 改名为 `fromPlugins`，直接安装每个插件的 v2 描述 |
| `PluginManager` | 删除 `getSystemPrompts`、`processResponse`、`getAllCommands`、`getAllTools`、`findToolByName`、`handleCommand`，只保留注册、开关与生命周期 |
| 命令 | 没有任何插件提供命令，也没有调用方。`CommandHandler`、`PluginContext`、命令贡献点与 `commands` 能力一并删除 |
| `ai_tool_collector.dart` | 没有调用方，删除 |
| 后台 Agent 白名单 | 原来从 `PluginManager.getAllTools()` 按名称取插件工具。生产环境里没有任何定义使用插件工具白名单，现在只使用调用方传入的工具；白名单里找不到来源的名称会记一条告警，不会悄悄丢掉。插件工具给 Agent 用的正式通道是 2d 的内核工具注册（`agentOnly`） |
| 测试 | 测试用的假插件改为继承 `TestPlugin`（`test/features/chat/services/test_plugin_support.dart`），它保留旧方法形状，并通过 v2 注册器贡献。原适配器测试改名为 `plugin_runtime_test.dart`，删掉命令与适配器专属用例，其余运行时规则用例保留 |

C 组：
- 各插件原有测试全部通过。
- 每个原生插件和酒馆兼容插件都有能力集合的精确断言（`capabilities` 等于实际用到的集合）。
- `tool/flutterw analyze`：0 error、6 warning，6 条 warning 都在本批未涉及的文件里（聊天列表的未用导入、MCP 页面测试、纳西妲导入脚本）。info 另有一千多条（风格提示，部分在本批改过的文件里），本批没有逐条清理；方案 C 组的“零告警”按 error 与 warning 计，info 未达到零。

验证（2c-11）：
- `test/features` 与 `test/ui/features/plugins` 共 1734 项通过，3 项失败：既有的分页测试，以及 `cloud_sync_contract_test`（setUpAll）、`drawing_preset_ui_test`（角色编辑器保存）两项。后两项在 2c 开工前的提交 `918fc92dd` 上同样失败，与本批无关。
- 11 份黄金副本逐字一致。

**2c 审查（2026-10-12）**：Codex 只读审查 `918fc92dd..5b8a3d6b7`，结论**有条件通过**，没有发现生产功能回归。Codex 的沙箱不允许打开本地端口，应用测试在它那边没能运行；应用测试的结果以本机运行为准（见各步验证）。

| 问题 | 处理 |
|---|---|
| P2：缓存回复入口 `processAssistantReplyWithPlugins` 没有走真实路径的测试 | 新增测试，经 `chatSendServiceProvider` 调用真实入口，覆盖三点：按角色选择处理器、按会话 owner 取语音请求、语音排在最后。两个变异（入口忽略角色选择、入口跳过处理器）都会让该测试失败 |
| P3：analyze 记录与实测不一致 | 改为写明 error、warning、info 分别多少，以及“零告警”按什么计 |
| P3：触发器 XML 清理条件表述不准 | 改为“总是清理标签，兜底开启时才增删提醒” |
| P3：自动回复的生图事件差异漏记 | 已补进 2c-1 记录 |

**2d 闸门与撤销接线（2026-10-12）**

| 方案原文 | 实际做法 |
|---|---|
| `AgentDefinition.toolPolicy` | 新增枚举 `AgentToolAuthorization`，三种模式：`allowAll`（默认，普通聊天）、`manual`（手动允许）、`unrestricted`（无限制）。作为 `AgentDefinition.toolPolicy` 字段，默认 `allowAll` |
| 闸门接入内核 ⑦ | App 侧 `AgentToolPolicy` 是运行期对象，包含授权模式、询问通道、脱敏器、询问超时，经 `ApiConfig.toolPolicy` 传给内核 runner。runner 用它包住 ⑦：内层是 `RedactingToolExecutor`，外层是 `GatedToolExecutor`。`toolPolicy` 为空时 ⑦ 就是 runner 自己，与接线前完全一样。旧 runner 不加闸门（第 9 节决定 3） |
| 闸门策略 | `AuthorizationToolGate`：`allowAll`／`unrestricted` 全部放行；`manual` 只放行 `readDiagnostic`，其余询问，询问说明按效果给出 |
| 工具效果 | `AITool` 增加 `effect`，默认 `external`。runner 按工具名查效果，查不到的按 `external` 处理 |
| 续轮只用 `content`（2a／2b 审查留下的前置条件） | `afterTools` 不再直接取 `payload`。模型看到的工具结果一律取自 `KernelToolResult.content`。被闸门拦下的调用没有 `payload`，由 `content` 生成结果。被脱敏改过的结果保留原来的音频和图片附件，只替换正文。Trace 与日志里的工具结果和异常信息，经内核 runner 时用同一个脱敏器处理（2d～2f 审查后补上）；旧 runner 不登记密钥，日志照旧 |
| Agent 专属工具 | 插件用内核 `tool` 注册，并带上 `agentIds`。`PluginRuntime.agentTools(snapshot(agentId: …))` 把这些工具转成 runner 用的 `AITool`，同时带上效果。普通聊天的工具仍来自请求范围 |
| `ReversibleChange` 的设置实现与 `ChangeJournal` | `FileChangeJournal`：本机应用支持目录下的 `agent_change_journal.json`，只留最近 50 条，写入先写临时文件再改名替换。`commit` 先记录、后写新值；`undo` 把原值写回、标记已撤销，再追加一条反向记录，重复撤销会报错。`PreferenceChangeApplier` 负责一项本机设置（SharedPreferences）：`before` 是快照，值为 null 表示删除，所以删除类修改的 `before` 就是备份 |
| 密钥登记来源 | `redactorForCredentials` 登记模型渠道 `apiKeys`、MCP 令牌与请求头值、联网搜索密钥。同步凭证没有登记，留给引导 Agent 方案按需补上 |

D 组（`test/features/agent_plugins/butler_tool_gate_test.dart`，假管家插件只对 `butler` Agent 可见，经真实内核 runner 运行）：
- 可见性：其他 Agent、普通角色运行都看不到这些工具。
- D1 手动允许：诊断直接执行；隐私读取和修改会询问，批准后执行。拒绝时工具不执行，模型收到“用户未允许”，循环继续。超时按拒绝处理并撤回询问。没有询问通道时一律拒绝。
- D2 无限制：不询问；修改写入撤销记录；删除前先备份。
- D3：两次修改按逆序撤销，设置回到原值，并记两条反向记录；重复撤销报错。
- D5：工具把密钥写进结果，发给模型的续轮请求和返回结果里都只有遮盖后的文本；渠道密钥能被登记。
- D6：没有策略时工具照常执行，结果原样交给模型；第一批的差分测试不变。
- D4（询问等待中取消）与 D7（`ToolGated` 事件只含白名单字段）由内核包测试覆盖：App 还没有接聊天停止按钮（第 2 节“不做”），也没有订阅内核事件。

变异检查：去掉闸门包装、续轮改回读 `payload`、手动模式放行隐私读取、撤销不写回、效果一律按 `external`，都会让 D 组测试失败。

验证（2d）：内核包 56 项通过；`test/features` 与 `test/ui/features/plugins` 共 1745 项通过，3 项既有失败（同 2c-11）；analyze 只有那 6 条既有 warning。

**2g 结束原因（2026-10-12）**

| 方案原文 | 实际做法 |
|---|---|
| `SendMessageRichResult` 增加归一化的 `finishReason` | 内核新增 `FinishReason`（`stop`／`toolCalls`／`length`／`contentFilter`／`unknown`）。`ApiCallResult` 与 `SendMessageRichResult` 原样保存供应商给出的 `rawFinishReason`，`finishReason` 由 `normalizeFinishReason` 换算。三家的原始取值互不重名，所以共用一张表。没有上报时为 null，与 `unknown` 区分开 |
| 三家适配器各自映射 | 非流式：OpenAI 兼容读 `choices[0].finish_reason`，Claude 读 `stop_reason`，Gemini 读 `candidates[0].finishReason`。流式：OpenAI 兼容取最后一个非空的 `finish_reason`，Claude 取 `message_delta.delta.stop_reason`，Gemini 取候选的 `finishReason`。预设传输改写响应时保留这个字段 |
| 内核 ④ 在 `stop`／`length` 却带工具调用时记录诊断事件 | 解包后、执行工具前，内核发出 `FinishReasonMismatch`（结束原因、工具调用数），工具照常执行。App 的内核 runner 把它写成一条应用日志警告，只记名称和数量 |
| 是否据此拒绝执行工具 | **本批不收紧**，理由见下面的真实记录 |

真实记录（隔离副本，真实渠道）：
- 当天较早验收的接口日志：OpenAI 兼容代理渠道（`wind/k3-low`）有工具调用的 2 次流式响应都是 `tool_calls`；带工具但没调用的 11 次（含非流式）和不带工具的 3 次都是 `stop`；没有“`stop` 却带工具调用”的情况。
- 本次重跑：该渠道处于配额低水位，`wind/k3-low` 返回 503，`claude-opus-5-5` 被上游拦截。应用按“模型失败等用户决定”流程等待，验收脚本无法替用户选择，两个场景都超时，与本批代码无关。中途切到 `muse-spark-1.2-contributor` 的那次成功：带工具（预设传输）但没调用，流式结束原因解析为 `stop`，没有发出不一致诊断。
- 缺口：DeepSeek Flash 没测到（副本里这个会话的请求实际走了默认渠道，原因未查）；Claude、Gemini 没有可用渠道。三家要等渠道可用后各补一次，再决定是否收紧。

G 组单测：映射表覆盖三家常见取值；三家非流式解析各一项，三家流式解析各一项；内核 6 项（`stop`／`length` 带工具时上报且工具照常执行、上报在 `ToolCallsDetected` 之前，`toolCalls`／`unknown`／未上报以及不带工具时都不上报）。变异检查：三家流式不取结束原因，对应测试都会失败。全量：内核 62 项；`test/core`、`test/features`、`test/ui/features/plugins` 共 1919 项通过，3 项既有失败。

**2e 声明式包 v1（2026-10-12）**

| 方案原文 | 实际做法 |
|---|---|
| 格式 `aicove-package.json`：`{schema: 1, id, name, version, contents}` | 根字段只允许 `schema`（必须为 1）、`id`（小写字母、数字、`-`、`_`，1～40 位）、`name`、`version`、`description`（可选）、`contents`（非空）。任何未知字段都会让整包被拒绝 |
| 内容项 `prompt`（放在系统提示词尾部） | `{type, text}`。包启用时，各条提示词用空行连起来，作为该插件的提示词条目放在插件提示词区 |
| 内容项 `tags`（名称、类别、可选包裹规则） | 收窄为 `{name, aliases?, display: text \| hidden}`。包不能声明替换规则或 HTML 渲染，也就是方案里的“包裹规则”不开放，避免“看起来声明式、实际在执行”。标签归属 `pkg:<id>`，与第一方同名时以第一方为准 |
| 内容项 `skill`，经只读工具 `read_skill` 提供 | `{type, name, title?, file}`。`file` 必须是包内的相对 `.md` 路径，不能含 `..`、绝对路径或反斜杠。工具名按包区分：`read_skill_<id>`，参数 `name` 是技能名枚举，效果为 `readDiagnostic`。这个工具名也登记在包的标签提供方下：包未启用时，历史里它的调用与结果会成对移除 |
| 不能包含可执行内容 | 包里每个文件都必须被清单引用，否则整包拒绝，所以脚本之类的文件进不来。点文件与 `__MACOSX` 直接忽略（不算包内容）；整包不超过 2 MB、200 个文件 |
| 导入后存 `Documents/aicove/packages/<id>/`，成为 `pkg:<id>`，`roleExplicit` | `PackageStore` 提供三种导入：文件表、文件夹、zip（zip 里只有一层顶级文件夹时自动去掉）。先完整校验，再写到这次导入独有的临时目录；替换时先把旧包移到一边，新包移入后再删旧包，失败就放回旧包；进程在中间被杀，下次列出时自动还原。同一个包根目录下的导入与删除逐个执行。文件夹和 zip 里的链接一律拒绝，zip 重名条目拒绝，读取过程中按 2 MB／200 个文件累计，超限立即停止。`aicovePackagesProvider` 列出已装的包，`pluginManagerProvider` 像 MCP 连接器一样逐个注册，删除的包同步注销 |
| 删除包即撤销其全部注册项 | 删除目录，再刷新列表，插件随之注销。下一次请求不再有它的提示词、工具和标签 |
| 角色显式开启 | 角色插件区每个包占一行开关（与 MCP 连接器相同），编辑页保存时保留 `pkg:` 开头的 id |
| 核心不认识具体插件 | `AicovePlugin` 新增可选的 `contentTags`。装配核心把已安装插件声明的标签提供方交给 `ChatPluginContextPolicy.firstParty(extraProviders:)`，不做类型判断 |

不做：导入界面（文件选择、包管理页）没有做，目前只有存储与 provider 接口；包不参与同步（与方案一致）。

E 组：
- `test/features/plugins/packages/aicove_package_test.dart`：解析与拒绝（未知字段、脚本类型、未声明文件、HTML 显示、越界路径、错误 id／schema）；请求过滤（包未启用时标签和工具成对移除）；存储（zip 带顶级文件夹与 `__MACOSX`、导入失败保留旧包、重新导入覆盖、删除拒绝越界 id）。
- `test/features/plugins/packages/package_request_test.dart`：经真实 `prepareApiConfig` 装配。角色显式开启时，提示词、标签和工具都生效，工具能读出技能正文；“全部插件”不包含这个包，它的标签被过滤；删除后下一次请求里没有它的内容。

变异检查：不传包的标签提供方、改成 `roleDefault`、删除时不注销，都会让 E 组失败。

**2f 后台收拢（2026-10-12）**

| 方案原文 | 实际做法 |
|---|---|
| `_fetchAiReply` 删除，后台改为无界面装配，调用同一个 `prepareApiConfig` | 新增 `ProactiveReplyGenerator`，前台派发与后台任务共用：从 DB 读最近 10 条原文，经 `prepareApiConfig` 装配（模型按主动回复设置），提醒作为最后一条用户消息，关闭原生工具，单轮执行。后台在 WorkManager isolate 里用 `generateHeadlessProactiveReply` 新建一个 `ProviderContainer`，只依赖 DB、设置与磁盘上的预设。后台自拼请求（`_fetchAiReply` 及其系统提示词模板）已删除 |
| `ContextProfile` 选 `proactiveSpecialized` | 当前 `prepareApiConfig` 还不接收 `ContextProfile`，前后台主动回复因此都按角色的完整聊天装配。两边走同一个生成器，“差异只来自配方”这一点由构造保证：测试逐字比较前后台的请求副本 |
| `BackgroundContextSpec` 并入 `ContextProfile` | 新增 `ConversationWindowSpec`（最近 N 条、角色过滤、时间戳），作为 `ContextProfile.conversationWindow`。`BackgroundAgentDefinition` 改为持有 `contextProfile`（默认 `backgroundAnalyzer`），`ContextProfile.background(window)` 便于构造。后台 Agent 定义只存在于代码里，没有已保存的旧数据，Trace 里的 `contextSpec` 字段名保持不变 |
| 执行权认领改为带过期时间的租约 | 认领表新增 `completed_at`。`tryClaim` 是单条 upsert，返回这次认领独有的令牌：没有记录就插入；已有记录只在“未开始送达且超过 10 分钟”时接管。生成完成、写消息之前调用 `beginDelivery(令牌)`，仍持有才原子地标记为已开始送达，然后才写；被接管的旧持有方在这一步被拒，不写任何东西，释放时也只能删除自己令牌的记录。已开始送达的认领永不被接管。代价：生成阶段崩溃会重试，写消息那一小段崩溃不再重试（至多一次，宁缺不重）。后台写入失败时事务已回滚，`abortDelivery` 撤销认领让下次重试接手。旧表在开库时按列是否存在补列，旧记录一律视为已完成。不升 schema 版本，多个 isolate 同时补列时，后到的一方会重新检查 |
| 送达后才标记 `fired` | 后台本来就是先写消息再标记，这次改动的是前台：派发前不再把触发器持久化为 fired，送达成功后由 `completeTriggeredSend` 标记。发送期间，进程内的 in-flight 表（含令牌）让轮询跳过这个触发器的全部判断，包括精确窗口作废；表项随租约过期。派发器写消息前用令牌调 `beginDelivery`，被接管就放弃（结果 `superseded`，由对方收尾）；开始写入后再失败按不可重试处理。可重试失败时，如果用户在发送期间暂停或作废了触发器，只释放认领，保留用户的决定。派发本身抛异常也走一次可重试的失败收尾 |
| 用消息来源编号去重 | 后台消息编号固定为 `bg_trigger_<triggerId>`，消息、会话摘要与未读数在同一事务里写入。认领后先查这条消息是否已存在：已存在说明上次写入后、标记前被杀，本次只补标记 fired、推进主动状态，不重复生成和发送。前台交付经过 TTS／生图等多段流程，做不到同一事务，所以前台靠上面的“开始送达”标记保证不重复 |
| （审查补充）后台认领失败 | 对方已送达就结束；对方仍在租约内，就把任务改期到租约过期后一分钟再试，免得对方中途被杀后无人接手（WorkManager 会把本次返回当作成功）|
| （审查补充）首次装配读到默认配置 | `prepareApiConfig` 开头等待各插件配置与包列表从磁盘读完（`ensurePluginConfigsLoaded`），冷启动和后台新建的容器第一次请求就能带上已开启的包与插件配置 |

F 组：
- `test/features/auto_reply/auto_reply_claim_lease_test.dart`：租约内拒绝、过期后接管；被接管的旧持有方既不能开始送达，也释放不掉新认领；已开始送达的认领不被接管；释放与撤销送达后可立即认领；旧表补列后，旧记录视为已完成。
- `test/features/auto_reply/background_delivery_test.dart`：调用 WorkManager 任务本体（不经调度）。用固定编号送达一次，标记 fired 并完成认领；模拟“写入后被杀”，重跑不产生第二条消息、不重复加未读；租约内的他方认领不受影响；对方已开始送达时本任务不写任何东西。
- `test/features/auto_reply/headless_proactive_reply_test.dart`：只凭 DB 与设置生成，请求带人设、历史与末尾提醒，不带工具；后台请求与前台生成器的请求副本逐字一致；会话不存在时不发请求。

变异检查：去掉租约时间条件、去掉两处去重、送达后不完成认领、不追加提醒，都会让 F 组失败。

待补：手机上真实跑一次后台主动消息（项目宪法第 7 条手机专属能力）。前台“发送期间保持活动状态”也要实机观察列表与作废检查的表现。

验证（2e＋2f，审查修正后）：全量 `tool/flutterw test` 2896 项通过（修正前 2885），14 项失败。其中 11 项（`test/ui/features/chat` 下 3 个文件、`frontend_shared_audit_test` 2 项）在改动前的提交 `abd794a51` 上同样失败，另 3 项是已知的既有失败；analyze 只有既有 warning。

**2d～2f 审查（2026-10-12）**：Codex 只读审查 `d59e86692..b75302398`，结论**不通过**，共 12 条（P1 两条、P2 九条、P3 一条），都有实际探针支撑，已逐条处理（复审发现其中 6 处处理不完整，见下方「2d～2f 复审」）：

| 问题 | 处理 |
|---|---|
| P1 前台送达后崩溃，重试会再次发送 | 认领令牌＋写消息前 `beginDelivery`：开始写入后不再重试 |
| P1 文件夹导入跟随链接，读到包外文件 | 遍历不跟随链接，遇到链接整包拒绝；zip 里的链接也拒绝 |
| P2 租约过期后旧持有方仍能送达、还能删掉新认领 | 每次认领一个令牌，开始送达与释放都校验令牌 |
| P2 后台在租约内重试被当作成功结束 | 对方仍在租约内时改期到租约过期后 |
| P2 新容器首次请求漏掉已装的包和插件配置 | `prepareApiConfig` 先等配置读完 |
| P2 发送期间被精确窗口作废、暂停被撤销、异常不收尾 | 轮询先跳过发送中的触发器；可重试失败尊重用户暂停／作废；派发异常也走失败收尾 |
| P2 后台恢复跳过摘要与未读数 | 消息、摘要、未读数同一事务写入 |
| P2 包替换丢旧包的窗口，并发导入共用临时目录 | 每次导入独有临时目录，按包根目录串行；旧包先移开、失败放回、中断后自动还原 |
| P2 2 MB 限制在读完之后才检查 | 读取／解压过程中累计，超限立即停；加 200 个文件上限；zip 按实际解压输出计数，不信任声明大小（复审 D 后的口径） |
| P2 撤销日志并发写入丢记录 | 按日志文件串行读改写，每次写用独立临时文件 |
| P2 工具原始结果先进日志 | 内核 runner 把脱敏器传给工具执行，结果与异常进日志、Trace 前先脱敏；实施记录里过强的表述已改正 |
| P3 zip 重名条目被静默覆盖 | 按 zip 原始目录检查重名，重名整包拒绝 |

新增测试：链接文件／链接文件夹、zip 重名、大小与数量上限、同包并发导入、替换中断后还原、新容器首次请求带上包、撤销日志并发追加与并发撤销、令牌校验（旧持有方不能送达也不能释放）、开始送达后不可接管、撤销送达。变异检查：跟随链接、不查重名、日志不加锁、不等配置、释放不校验令牌，都会让对应测试失败。

仍是缺口：前台控制器“发送期间”的状态处理（暂停、精确窗口、异常收尾）没有自动测试，只做了代码层面的修正，要靠实机观察；后台“生成期间被接管”的写入拦截只在认领仓库层验证（旧持有方 `beginDelivery` 被拒），没有在任务层构造这段时序。

**2d～2f 复审（2026-10-13）**：Codex 只读复审 `2bd8587b7`，结论**不通过**，指出上一轮 6 处处理不完整（A～F），逐条核实后处理如下：

| 问题 | 处理 |
|---|---|
| A 前台认领令牌没有绑定到这次发送，迟到的完成回调可能收尾新的一次认领 | `fired` 事件带上认领令牌，发送服务把令牌一路传到 `completeTriggeredSend`；令牌不一致的完成回调只返回“已被取代”（只覆盖开始送达被拒的情况，其余失败见第三轮）；测试发送走单独的 `dispatchTestTrigger`，不占认领 |
| B 已开始送达但没有标记完成的触发器，前台会一直卡住；清理旧认领会删掉仍在用的记录 | 前台认领失败且记录处于“已送达”时，按稳定消息 id 查库：消息在就补标记已发，不在就以「开始送达后中断，未重试」结束；清理认领时保留仍活跃的触发器 |
| C 后台认领丢失只处理了“对方已送达”一种 | 分三种：空闲就重新认领；对方租约内就改期到租约过期后（改期失败抛错，让 WorkManager 重试）；已送达就按消息是否存在收尾；读不到状态也抛错 |
| D zip 解压仍先整条解出再计数 | 读原始目录，压缩条目用分块解压并在输出超过剩余额度时立即停；未压缩条目同样按剩余额度判断；加密条目拒绝 |
| E 删除包不清理替换中断时移开的旧副本，下次列表会把它还原回来 | 删除时一并移除同 id 的 `.id.*.new／old` 临时副本 |
| F 中断恢复会处理任何以点开头的文件夹 | 只认 `.<id>.<微秒>.new／old` 严格命名，其他隐藏文件夹不动 |

新增测试：认领清理保留活跃触发器；开始送达后未写入就被杀的后台任务以中断结束、不重试；对方仍在租约内时任务不按成功结束；对方已开始送达时不写入；解压超出额度；删除连带临时副本且不动无关隐藏文件夹。变异检查：清理不保留活跃触发器（M10）、已送达不收尾（M11）、删除不清临时副本（M12）、恢复放宽命名（M13），都会让对应测试失败。后台认领与投递相关 38 项测试连续 8 次全部通过。全量 `tool/flutterw test` 2900 项通过，失败仍是上文同样的 14 项既有失败；analyze 只有既有 warning。

仍是缺口：前台控制器“发送期间”的状态处理（暂停、精确窗口、异常收尾、令牌不一致）仍没有控制器级自动测试；后台“生成期间被接管”只在认领仓库层验证；WorkManager 后台主动消息待手机实测；包导入界面未做。

**2d～2f 第三轮复审（2026-10-13）**：Codex 只读复审 `3f57dbe45`，结论**不通过**：D、E、F 关闭；A、B、C 仍不完整，另有两处文档表述过强。处理如下：

| 问题 | 处理 |
|---|---|
| 被接管的旧发送返回空内容、异常等失败时，仍会改期或作废新一轮触发器 | `completeTriggeredSend` 改触发器前先确认本次令牌仍是当前认领（`isCurrent`），不是就直接结束；读不到认领状态也不改 |
| “已开始送达”被直接当成“进程已中断”，会把正在正常写入的一方作废 | 开始送达时记下时间；一个租约内视为对方仍在写，前台与后台都不插手；超过租约才按中断补成终态 |
| 后台认领空出后再次没抢到就按成功结束 | 最多再处理两轮最新状态，仍认领不到就抛错交给 WorkManager 重试 |
| 前台中断恢复只认后台固定编号的消息 | 认领表加 `message_id`，开始送达时记下将写入的原始消息编号（前台是 raw message id，后台是固定编号）；恢复按它判断，旧记录退回后台固定编号 |
| 文档过强：令牌不一致不改状态、zip 声明大小比对 | 已改正（见上两表） |

新增测试：控制器级——被接管的旧发送完成（可重试与不可重试）不改触发器、当前持有方正常改期并释放认领；后台任务级——前台中断的送达按记下的消息编号补记已发、租约内的送达交给持有方；认领仓库——令牌是否当前、送达记录消息编号与中断判定、旧表补 `message_id`。变异检查：完成回调不校验令牌（M14）、租约内也按中断处理（M15）、恢复忽略记下的编号（M16），都会让对应测试失败。全量 `tool/flutterw test` 2906 项通过，失败仍是同样 14 项既有失败；相关 44 项连续 5 次通过；analyze 无新增 warning。

取舍：送达中断要等满一个租约（10 分钟）才补终态，这段时间触发器保持待发但不会重发（第四轮修订见下）。

**2d～2f 第四轮复审（2026-10-13）**：Codex 只读复审 `478b3b0ee`，结论**不通过**：后台二次认领、前台按记下的消息编号恢复两项关闭；另有四项 P2、一项文档表述。处理如下：

| 问题 | 处理 |
|---|---|
| 完成回调确认令牌后、写触发器前仍可能被接管 | 失败收尾先续租（`renew`：仍由本令牌持有且未开始送达时把租约从现在重新算起），续上了才改触发器，之后一个租约内没人能接管；续不上而令牌仍是当前认领，说明本次已开始送达，这种认领永不再被接管。触发器存在 SharedPreferences、认领存在 SQLite，无法放进同一事务，续租是这里的原子保护 |
| 后台遇到租约内的送达直接按成功结束，对方若中途被杀就无人收尾 | 改期到送达租约结束后一分钟再检查，改期失败抛错 |
| 迟到的成功回调会把“中断作废”改回已发 | 保留现行为并改正文档：成功回调只在消息确实写入后到达，此时记为已发才是真实状态；不会产生第二条消息 |
| 精确窗口与业务作废检查绕过送达保护 | 轮询对已到点的触发器先看送达记录：已开始送达就只按送达记录收尾（租约内跳过、超过租约补终态）；读之后才开始送达的竞态由第五轮的“作废先认领”关闭 |
| 文档“后续收尾不会覆盖作废状态”不符 | 已删除，改为上表第三行的口径 |

新增测试：控制器级——失败收尾续租后租约从完成时重新计算、开始送达后的失败仍由持有方收尾；认领仓库——续租只对未送达的当前令牌生效；后台任务级——租约内的送达改期检查（无 WorkManager 时抛错，不按成功结束）。变异检查：不续租（M17）、只续租不认已送达（M18）、后台不改期（M19），都会让对应测试失败。全量 `tool/flutterw test` 2909 项通过，失败仍是同样 14 项既有失败；相关 47 项连续 5 次通过；analyze 无新增 warning。

仍是缺口：完成回调“确认后被接管”的并发时序只能用续租语义间接验证。

**2d～2f 第五轮复审（2026-10-13）**：Codex 只读复审 `1309871a9`，结论**不通过**：续租、后台改期两项关闭，迟到成功的取舍接受；精确窗口一项仍不完整，并引入一处回归。处理如下：

| 问题 | 处理 |
|---|---|
| 轮询前移的送达检查不看触发器状态，已发的触发器每轮都被重新“补记已发”，刷新发送时间与最小间隔 | 只对仍有效的触发器做送达检查；中断收尾本身也先确认触发器仍有效，已发或已作废的不再改写 |
| 送达检查只是一次读取：读完后对方才开始送达，前台仍会作废；读取失败也放行作废 | 自动作废（精确窗口、业务作废）改为先认领执行权，认领到才作废，认领留着挡住对方之后的 `beginDelivery`；没认领到（对方在生成或已开始送达）本轮不作废；认领状态读不到本轮跳过 |

新增测试（控制器轮询级，经 `pollDueTriggersForTest` 调用）：对方正在送达时不作废；对方持有认领时不作废；无人认领时作废并保留认领；已发的触发器不被再次收尾。变异检查：作废不先认领（M20）、对已结束触发器仍收尾（M21），都会让对应测试失败。全量 `tool/flutterw test` 2913 项通过，失败仍是同样 14 项既有失败；相关 51 项连续 5 次通过；analyze 无新增 warning。

**2d～2f 第六轮复审（2026-10-13）**：Codex 只读复审 `8b24b0ca4`，结论**有条件通过**：上一轮两项 P2 关闭，没有 P1／P2。唯一 P3：已暂停、已发或已作废的精确触发器过了窗口仍会先认领再发现无需作废，留下无用认领。已修：作废前先确认触发器仍有效，非活跃的不认领；新增测试“非活跃的精确触发器过窗口不留认领”（需开启精确提醒），去掉该检查（M22）测试即失败。全量 `tool/flutterw test` 2914 项通过，失败仍是同样 14 项既有失败；相关 52 项连续 3 次通过；analyze 无新增 warning。

2d～2f 审查到此结束。仍需实机：Mac 窄屏检查（渠道恢复后）、手机上 WorkManager 后台主动消息；`proactiveSpecialized` 未接入、包导入界面未做，属后续批次。
