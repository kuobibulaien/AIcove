# Agent 运行时第一批实施方案：内核循环与插件宿主

> 状态：1a、1b、1c 代码与离线差分、真实模型对照均已完成（2026-10-08）；后台与前台开关（`AICOVE_AGENT_KERNEL_BG`／`AICOVE_AGENT_KERNEL_CHAT`）默认关；Mac 实机开开关聊天验收未做；默认打开与删除旧 runner 另行决定。实施记录见第 10 节。
> 决策依据：[ADR0064](../../../../docs/项目记忆/决策记录/0064-Dart微内核Agent运行时与全插件化.md)（Dart 微内核＋全插件化）、[ADR0060](../../../../docs/项目记忆/决策记录/0060-Agent统一装配与前后台调度分离.md)（统一装配）；同日并行决定 [ADR0061](../../../../docs/项目记忆/决策记录/0061-旧工具结果按时间清理.md)、[ADR0062](../../../../docs/项目记忆/决策记录/0062-聊天自动压缩改用陪伴口径.md)、[ADR0063](../../../../docs/项目记忆/决策记录/0063-插件请求前提醒钩子.md) 的衔接见第 9 节
> 范围：ADR0064「分批」第 ① 批。第 ② 批（现有功能迁内置插件、声明式包）与第 ③ 批（QuickJS 脚本插件）另立方案。

## 1. 现状：工具循环已经存在，只是没有内核

下文行号均指 `lib/src/features/chat/services/chat_send_api_runner.dart`（另注明者除外）。

| 现有部件 | 位置 | 现状 |
|---|---|---|
| 工具循环 | `chat_send_api_runner.dart`（1086 行）＋ `_tool_support`（704 行）＋ `_text_support`（493 行），共 2283 行 | `for round` 循环，最多 `maxRounds` 轮（聊天 5、记忆 Agent 4、摘要 1） |
| 循环调用方 | 前台 `chat_send_backend_service.dart`；后台 `background_agent_service.dart` 的 `BackgroundAgentExecutor`（第 60–66、107–113 行） | 前后台共用 runner，上层各自保留：前台经 `ChatSendUseCase`，后台由 `BackgroundAgentService` 直接调用并消费结果（第 247–275 行）；两个上层本批都不动 |
| 插件接口 | `features/plugins/domain/plugin.dart` | 有生命周期、`getTools`、`getCommands`、`getHooks`；`LLMHook` 无人调用（ADR0063 将清理） |
| 插件管理 | `features/plugins/plugin_manager.dart` | 已有初始化、启停、销毁、工具／命令／钩子收集与异常隔离（第 134–347 行）；**缺**服务容器、贡献所有权与自动撤销 |
| 工具来源 | `chat_types.dart:126–128`、`_tool_support:224` | `availableTools` 非空即为权威集合（显式空列表也不回退查插件）；前台 `boundTools` 闭包固定了本次联系人；后台传空插件列表＋独立工具 |
| 取消 | `chat_send_use_case.dart:167–181、284–298` | runner 无取消参数；上层等调用返回后才判断是否仍有效；`AgentApiClient` 无关闭出口 |
| 结束原因 | `core/api/agent_api.dart:26–39` | `SendMessageRichResult` 不暴露 `finish_reason`／`stop_reason` |
| 续轮消息格式 | `core/api/providers/*_adapter.dart`、`_tool_support:632–689` | 非统一 OpenAI 形状：Gemini 为 `model/parts`（含思考签名）、Claude 为 `tool_use/tool_result` 块、OpenAI 区分 `tool_calls` 与旧 `function_call` |
| 契约 | `agent_context/domain/agent_runtime_contracts.dart` | `AgentRuntime`／`AgentScheduler`／`AgentOutputEvent`／`AgentDeliveryChannel` 可复用 |

**结论：第一批是“等价抽取”，不是重写，也不顺手改行为。** 循环里的每个业务分支都要在新结构里有明确落点，任何行为变化（如工具全部串行、统一消息格式）都不属于本批。

## 2. 目标与不做

**目标**

1. 新增纯 Dart 内核包 `packages/aicove_agent_kernel`：循环、阶段接口、插件宿主、领域类型。包的 `pubspec.yaml` 不依赖 Flutter，由编译器保证纯 Dart（含间接依赖），不靠扫描 import。
2. 现有 runner 的每个分支迁到内核的固定阶段里，**行为与现在一致**。
3. 后台先切、前台后切，各有编译期开关，默认关闭，旧 runner 原样保留。

**不做（本批）**

- 不改插件实现、不改数据库与落库格式、不改同步契约；DB raw message 仍是唯一真相源。
- 不统一各家续轮消息格式；不按结束原因收紧工具执行（需适配器先暴露结束原因，放第 ② 批）。
- 不把取消接到聊天页“停止”按钮；取消与追加指令只做内核能力和测试（见 3.6）。
- 不做暂停（无使用场景）、脚本插件、MCP、声明式包。
- 不新增逐轮持久化或崩溃恢复（见 3.7）。

## 3. 设计

### 3.1 包与目录

| 位置 | 内容 | 依赖 |
|---|---|---|
| `packages/aicove_agent_kernel/` | `AgentLoop`、阶段接口、`PluginHost`、`KernelScope`、内核自有的消息／工具调用／结果类型、取消与追加指令 | 仅 Dart SDK |
| `lib/src/features/agent_kernel/`（App 内） | 各阶段的具体实现（搬自旧 runner）、`KernelApiRunner`、类型转换 | 可依赖 Flutter 与现有 `core/api` |

内核类型与现有 `ToolCall`／`ToolResult`（`core/api/providers/provider_adapter.dart`）之间由 App 侧适配层转换；消息内容仍按现有格式透传（`Map<String, dynamic>`），内核不解析各家结构。

### 3.2 循环：固定阶段，而不是万能钩子

初稿用五个通用钩子承载全部业务，审查证实表达不了现有分支（预设响应解包、并发生图、执行后决定续轮）。改为**固定阶段管线**：每个阶段是一个有明确输入输出的接口，旧 runner 的分支逐一落到某个阶段的实现里。

```text
KernelApiRunner 打开 run 作用域，执行 run 初始化（见 3.5 工具来源）
try:
 AgentLoop 每一轮：
  ① RoundPreparer      运行中消息 → 请求消息（首次模式）
  ② 一次请求尝试（受超限恢复保护）：预设变换后预算检查 → 预设 reset → ModelPort 发送（含流式与传输层回退）
     └ 上下文超限（服务端报错或本地预算检查）：OverflowRecovery 用①的恢复模式
        （只做强制压缩 → 预设 prepare，不重做清洗、媒体解析与普通压缩）后重试②，仅一次
  ③ ResponseUnpacker   原始响应 → 本轮回复（正文、工具调用、是否已被预设消费）
  ④ ToolCallResolver   本轮回复 → 待执行工具调用（文本兜底；已消费则跳过）
  ⑤ PreToolDecision    工具执行前的决定（稳定生图审图：批准／重画／放弃）
  ⑥ 无工具调用 → 结束
  ⑦ ToolBatchExecutor  按策略执行工具批次（并发或串行），每个工具带超时
  ⑧ PostToolDecision   工具执行后的全部停止判断：快速路线停止、maxRounds 截止、补充轮预算；判定停止即结束，不进入⑨
  ⑨ ContinuationEncoder 仅在继续时：本轮回复＋工具结果 → 追加到运行中消息的续轮消息，进入下一轮
 ResultFinalizer（3.4）
finally：释放 run 作用域（AgentLoop 与 ResultFinalizer 都结束后，不论成功、失败、取消）
```

三份消息状态严格分开：**运行中消息**（原文派生，压缩只作用于它）、**请求消息**（经预设变换，只用于本次发送）、**模型原始响应**。

### 3.3 各阶段的现行实现（逐项对应旧 runner）

| 阶段 | 搬入的现行逻辑 | 旧位置 |
|---|---|---|
| ① RoundPreparer | 首次模式：非视觉清洗 → 媒体解析 → `runtimeContext.prepare`（压缩，含 ADR0061 裁剪）→ 预设 `prepare`。恢复模式：`runtimeContext.prepare(force: true)` → 预设 `prepare` | 266–275；505–511 |
| ② 请求尝试 | 顺序固定为：预设变换后预算检查（位于超限恢复保护范围内）→ 预设 `reset`（会执行脚本，必须在预算检查通过之后）→ 流式／非流式发送；流式失败回退非流式（预设 reset、清空已流出文本、本轮及后续禁用流式）；50ms 合并的预设传输预览与异步输出排空；流式事件携带**工具参数增量快照**（含 `rawArguments`），不只是“发现工具调用” | 285–360、375–496 |
| OverflowRecovery | 仅在配置了 `runtimeContext` 且为上下文超限（含本地预算检查抛出的超限）时：用①恢复模式重新渲染、清空传输预览与流式状态，重试②一次；第二次失败终止；不重复执行工具 | 497–517 |
| ③ ResponseUnpacker | 预设 `response()`：替换正文、剔除已消费的传输工具调用、保留 `hiddenThoughtParts`、不保留旧 `rawResponse`，产出“已消费”标志 | 520–543 |
| ④ ToolCallResolver | 文本工具兜底解析与签名去重；“已消费”时跳过 | 553–589 |
| ⑤ PreToolDecision | `applyStableReviewDecision`：按正文占位或重画调用决定待审图片去留 | 220–264；调用 590–594 |
| ⑦ ToolBatchExecutor | 策略：快速生图路线（快速模式且本批全为 `draw_image`）用 `Future.wait` 并发，其余串行；单工具执行、超时、结果转换沿用 `_executeToolCall`；结果收集（音频、图片、稳定路线待审图片）沿用 `collectToolOutcome` | 194–217、635–707；`_tool_support` 471–478 等 |
| ⑧ PostToolDecision | 全部停止判断集中于此：快速路线无异步受理的生图即停；`maxRounds` 截止；快速路线补充轮预算 1 耗尽即停。判定停止时不调用⑨ | 783–829 |
| ⑨ ContinuationEncoder | 兜底调用构造 assistant 消息或从原始响应重建（保留 Gemini 签名）；`adapter.buildToolResultMessages`；非视觉清洗；预设路径下 Gemini `model`→`assistant`；追加稳定审图消息 | 831–866；`_tool_support` 632–689 |

第 ① 批**不改各阶段内部逻辑**，只搬位置并补接口。每个阶段的现行实现即“内置默认实现”，后续批次可由插件替换或追加。

### 3.4 结果处理在循环外，但在 `KernelApiRunner` 内

旧 runner 循环结束后还有一整段结果处理（880–1046），前台 `ChatSendUseCase` 与后台 `BackgroundAgentService` 都只消费返回值，**不会代做**。因此 `KernelApiRunner` 在调用 `AgentLoop` 之后必须原样执行 `ResultFinalizer`：

1. 跨轮叙述合并、排除工具指令文本、完成提示、图片占位清理、文本清洗与完成提示兜底（880–925）
2. 显示正则（928–933）
3. 插件 `processResponse`，逐插件隔离异常（945、1053–1084）
4. Trace `finalReplyReady` 与 `ApiLogger` 记录（957–1018）
5. 合并插件事件、媒体、音频、全部工具调用与结果、最终 `hiddenThoughtParts`，状态文案抑制，组装 `ApiCallResult`（1020–1046）

`ApiCallResult` 每个字段的来源在实现时列成映射表，差分测试逐字段比较。

run 作用域由 `KernelApiRunner` 持有，按“打开 → try { AgentLoop；ResultFinalizer } → finally 释放”的顺序；快照插件与预设运行时在 `ResultFinalizer` 用完后才释放，与旧 runner 在返回值构造之后才关闭运行时（1032–1050）一致。内核独占、Finalizer 不再使用的临时资源可在循环内提前释放。

### 3.5 插件宿主（只做本批真正用到的）

| 能力 | 本批实现 |
|---|---|
| 作用域 | 应用作用域 → run 子作用域。注册项（工具、阶段实现、服务、可关闭资源）记录**所有者插件**与撤销句柄；由 `KernelApiRunner` 在循环与结果处理都结束后的 `finally` 中无条件释放，不依赖任何钩子 |
| 服务容器 | 只做键控查找、子作用域覆盖与释放；不做依赖自动启动、热替换传播（YAGNI） |
| 工具来源与 run 初始化 | 优先级保持现行：显式 `availableTools` → `config.boundTools` → 本次快照插件的 `getTools()`；前两者只要非 null 即为权威集合，空列表也有效（runner:88）。run 初始化负责：普通与预设工具 schema 合并并查重（95–100）、注册预设业务工具 handler（101–112）、应用预设 `toolChoice`（114–118）。不在 run 中重新向全局插件取工具，`boundTools` 闭包原样使用 |
| 插件停用 | run 开始时对插件集合做快照，运行中停用不影响本次 run；停用后新 run 不再出现其注册项；重新启用后恢复 |
| 插件钩子 | 只开放“贡献内容”类钩子（首个实例是 ADR0063 的请求前提醒），出错策略 `optional`（记录并跳过）；内核阶段属可信代码，出错策略 `required`（run 失败） |
| 权限闸门 | 插件注册时声明能力（本批：`tools`、`hooks.contribute`），未声明的注册被拒 |

### 3.6 取消与追加指令（内核能力，本批不接聊天页）

- 取消：内核 `KernelCancellation`。在途模型请求通过关闭本次 `AgentApiClient`（新增 `close()`）中断；取消产生的异常**不触发**流式回退或超限恢复；执行中的工具不强杀、结果丢弃；资源由作用域无条件释放。
- 现行 `executeApiCall` 签名不变，上层暂不传取消信号，所以聊天“停止”行为与现在相同。接线到界面另立任务。
- 追加指令：入队，当前轮完整结束后作为 user 消息注入；run 结束后拒绝。

### 3.7 持久化与失败边界（沿用现状，写清楚不承诺什么）

- 循环中的消息追加只在内存。前台：工具调用与结果只有在 run 成功返回后，经 `ChatSendUseCase` 下游的 `chat_message_processor.dart` 构造 ToolBlock 才落库。后台：结果由 `BackgroundAgentService` 组装为 `BackgroundAgentRunResult` 交给各自调用方（记忆整理、摘要等），本批不改其去向。
- run 失败或取消：已执行工具的副作用不回滚，也不落库工具记录（与现在一致）。
- 工具超时用 `Future.timeout`，底层工作可能迟到完成，结果被丢弃（与现在一致）。
- 不提供逐轮持久化与崩溃恢复。Trace 只作诊断，不作为聊天真相源。

### 3.8 Trace 阶段归属

| 阶段 | 记录方 |
|---|---|
| 请求构造、流式聚合 | `AgentApiClient`（不动） |
| 单工具开始／结束 | ⑦ 中沿用 `_executeToolCall` |
| `toolCallDetected`、工具批次聚合（含 payload）、`roundCompleted` | 循环在对应阶段之后调用 Trace 观察者，`await` 完成后再进入下一步，保持现有时序 |
| `finalReplyReady`、最终 `ApiLogger` | 3.4 的 `ResultFinalizer` |

### 3.9 接线与开关

- 抽出接口 `ApiRunner`（`executeApiCall` 签名与旧 runner 相同），旧 `ChatSendApiRunner` 与新 `KernelApiRunner` 都实现它。
- 按 run 回退：`KernelApiRunner` 在 run 初始化时检查本次是否用到尚未迁移的能力（1b 阶段为：带预设脚本，或工具集合含 `draw_image`），是则整次委托旧 runner 并记录日志；1c 迁完后删除这条回退。这样后台开关可以覆盖整个 `BackgroundAgentService`，不必假设后台用不到生图（其白名单收集不排除 `draw_image`，见 `background_agent_service.dart:570–602`）。
- Provider 用工厂选择实现：`createApiRunner({required bool useKernel})`；生产传入编译期常量 `bool.fromEnvironment('AICOVE_AGENT_KERNEL_BG')`／`AICOVE_AGENT_KERNEL_CHAT`，测试直接传 `true`／`false`。
- 回退：不带定义重新构建。这不是运行时即时回退，且共享依赖（如 `AgentApiClient.close()`）的改动不随开关撤销。

## 4. 分步交付

| 步 | 内容 | 验收 |
|---|---|---|
| 1a | 内核包：循环、八个阶段接口（①②③④⑤⑦⑧⑨）与 OverflowRecovery 编排、宿主、作用域、取消、追加指令；测试用假阶段与假模型 | 第 5 节 A 组全绿；内核包 `dart analyze`、`dart test` 通过（不经 Flutter） |
| 1b | App 侧：除预设与生图外的全部阶段实现、run 初始化（不含预设部分）、`ResultFinalizer`、`KernelApiRunner`（含按 run 回退）、`ApiRunner` 工厂、`AgentApiClient.close()`；后台开关接入 `backgroundAgentServiceProvider` 与 `_defaultExecutor`，覆盖整个后台服务 | B 组差分测试对两种 runner 全绿；新增接线测试断言开关为真时确实调用 `KernelApiRunner`，且带预设或 `draw_image` 的 run 委托旧 runner；DeepSeek Flash 真实跑一次记忆 Agent 与一次摘要，比较**工具调用轨迹与业务结果**（不比生成文本逐字） |
| 1c | 预设部分（①中预设 `prepare`、②中预设 reset 与变换后预算检查及传输预览、③、run 初始化中的预设工具与 `toolChoice`）与生图路线（⑤⑦⑧⑨ 中的生图部分）；删除按 run 回退；前台开关接入 `chat_send_backend_service.dart` | C 组差分测试全绿；Mac 实机开开关聊天：普通回复、生图工具（快速与稳定各一）、预设传输各一次，按项目宪法第 7 条验收 |

1b 按后台**实际会走到的分支**划分，不按“前台／后台功能”名称划分：后台同样经过非视觉清洗、媒体解析、文本工具兜底与结果处理；后台普通配置不设 `runtimeContext` 与预设（`background_agent_service.dart:217–236`）；生图不是后台的保证条件，由按 run 回退兜住。

1c 通过后再讨论默认打开；打开后观察一段时间，再另立任务删除旧 runner。

## 5. 测试清单

**差分方法**：先在旧 runner 上跑出行为基线，再让新 runner 跑同一用例比较。现有 6 个 `chat_send_api_runner_*_test.dart` 与 `kemini_transport_pipeline_test`、`voice_chat_snapshot_test`、`background_agent_service_test` 改为对 `ApiRunner` 工厂参数化。已知违反现行规范的旧缺陷单独登记，不以“与旧 runner 一致”为唯一正确标准。

**A 组（1a，纯 Dart）**

1. 无工具：一轮结束，事件顺序正确。
2. 工具多轮：按策略串行执行，结果写回后下一轮收尾。
3. 并发策略：策略返回并发时同批工具同时启动，结果按调用顺序写回。
4. `maxRounds` 截止。
5. 执行后决定：⑧ 返回停止时不再请求；补充轮预算耗尽后停止。
6. 超限恢复：只恢复一次，从运行中消息出发，不重复执行工具；第二次失败终止；非超限错误直接抛出；本地预算检查抛出的超限同样可恢复；调用轨迹断言为“首次：清洗 → 媒体 → 普通压缩 → 预设；恢复：强制压缩 → 预设”，预算检查通过后、实际发送前执行 reset；本地预算检查失败的尝试不执行 reset；流式失败回退时另有一次 `reset(false)`（runner:477）。
6a. 截止不编码：⑧判定停止（含达到 `maxRounds`）时 ⑨ 不被调用。
7. 取消：请求前／请求中／工具中／恢复前各一；取消不触发回退或恢复；资源恰好释放一次；迟到结果不被采用；取消一个 run 不影响并发的另一个。
8. 追加指令：轮内入队、下一轮开头按序注入；run 结束后拒绝。
9. 作用域：成功、异常、取消三种结束方式下 run 作用域都释放；父作用域不受影响；子作用域覆盖的服务在释放后恢复父值。
10. 插件停用：run 中停用不影响本次；新 run 不含其注册项；重新启用恢复。
11. 出错策略：`required` 阶段出错 run 失败并带来源；`optional` 贡献钩子出错只跳过自身且不留下半修改结果。
12. 权限：未声明能力的注册被拒；工具重名报错；工具超时返回结构化结果、循环继续。

**B 组（1b，差分）**

1. 工具来源：显式空 `availableTools`、仅设置 `config.boundTools` 而未显式传 `availableTools`、后台独立工具、前台 `boundTools` 闭包；准备后切换角色不影响本次请求。
1a. 按 run 回退：带预设或工具含 `draw_image` 的 run 走旧 runner，结果与直接调用旧 runner 一致。
2. 文本兜底：解析、签名去重、重复跳过。
3. 流式回退：部分文本已流出后失败、后续轮次禁用流式。
4. 超限恢复（服务端超限）。
5. 跨供应商续轮：OpenAI 现代与旧 `function_call`、Claude 内容块、Gemini `parts`／思考签名／`hiddenThoughtParts`。
6. 结果处理：raw／显示／processed 三种文本区分，显示正则与插件处理顺序，跨轮叙述合并，状态文案抑制。
7. Trace：单工具与批次阶段、关联编号、payload、`finalReplyReady` 时序。
7a. 真实 `KernelApiRunner` 生命周期：`ResultFinalizer` 执行时快照插件与预设运行时仍有效；Finalizer 抛异常时作用域恰好释放一次（基线 runner:945–1049）。
8. 接线：开关真／假时分别调用到对应 runner；成功结果经真实消息构造链保留工具调用与结果配对；失败与取消不产生成功记录。
9. ADR0063 联合（若已实施）：固定时间，有／无预设、工具多轮、超限重试下，提醒只在 run 前装配一次，不随轮次累加。

**C 组（1c，差分）**

1. 预设解包：传输工具被消费、业务工具保留；消费后不触发文本兜底；不重放旧 `rawResponse` 中的传输调用。
2. 增量传输：工具参数分片、`rawArguments`、累积快照重写，50ms 合并与输出排空。
3. 预设超限：本地变换后超限与服务端超限两种。
4. 预设＋流式回退：reset 与已流出文本清空。
5. 快速生图：纯生图并发、混合工具串行、异步受理后续轮与预算。
6. 稳定生图：批准、重画、不发送、最后一轮仍有待审图片。

## 6. 回滚

- 1a 只新增内核包，删除即回滚。
- 1b／1c 由编译期开关控制，默认关；旧 runner 只做声明实现 `ApiRunner` 接口等机械接线修改，不改执行逻辑。
- `AgentApiClient.close()`、`ApiRunner` 接口为新增，不改变现有调用行为，但不随开关撤销。

## 7. 已知风险

| 风险 | 处理 |
|---|---|
| 抽取后行为细微偏差 | 第 5 节差分测试；不一致时以旧 runner 为基线修新实现，除非确认是旧缺陷并登记 |
| 无法按结束原因决定是否执行工具 | 维持现状，第 ② 批由适配器暴露结束原因后收紧 |
| 取消不能中断执行中的工具（如生图 HTTP） | 本批丢弃结果；工具级取消随第 ② 批工具接口升级处理 |
| 阶段接口为现有业务量身定做，后续插件化可能需要调整 | 接受；第 ② 批迁内置插件时再按真实需求泛化，不提前设计 |

## 8. 对 ADR0064 的修订

已同步修订 ADR0064：第一批以等价抽取为主；插件能力的两个维度（宿主设计与第三方代码加载）分开论证；Node／iOS 等未独立核实的说法改为有限定的表述；验收门 3 对齐 `QuickJsSession` 出错即关闭会话的现状。

## 9. 与同日 ADR0061／0062／0063 的衔接

三条决定都由并行会话写成、代码均未实施，作用于本方案要抽取的同一条链路。Codex 审查结论：均不冲突。

| ADR | 内容 | 与本方案的关系 |
|---|---|---|
| 0063 插件请求前提醒钩子 | 新增“插件请求前贡献提醒文字”钩子，放置由核心决定；时间感知与画图失败提醒从发送核心迁出；删除无人调用的 `LLMHook` afterResponse 与 `LLMHookManager` | 它是 3.5“插件钩子只能贡献内容”的首个实例，出错策略同为 `optional`。提醒在 `chat_send_backend_service.dart` 的 `prepareApiConfig`（第 134 行起，第 400–480 行收集并插入）里生成，属于 run 开始前的一次性装配，不在 runner 每轮内。`KernelApiRunner` 接收的已是装配好的 `ApiConfig`，不触碰这一步；它将来归入 ADR0060 的装配机器，**不得**登记为每轮执行的阶段，否则会逐轮累加。本方案不再单独处理 `LLMHook`，以 0063 的清理为准 |
| 0061 旧工具结果按时间清理 | `RuntimeContextService.pruneToolResults` 改为保留最近 3 次、更早整条换占位，只改请求副本 | 落在 ① RoundPreparer 的 `runtimeContext.prepare` 内部，本方案只搬调用位置不改其逻辑；需保持闭合工具组与调用 ID，覆盖各家原生续轮格式；差分测试须在同一实施状态下比较 |
| 0062 聊天自动压缩改用陪伴口径 | 自动压缩拆陪伴口径与任务口径，运行时压缩保留任务口径 | 不影响内核接口。现行 `runtime_context_service.dart:92–94` 以 `ContextSummaryKind.auto` 调用摘要器，0062 实施时须确认运行时压缩不会误用陪伴模板 |

## 10. 实施记录与偏差（2026-10-07）

**1a**：`apps/aicove_flutter/packages/aicove_agent_kernel`。实施中把两个决策阶段的方法名定为 `beforeTools`／`afterTools`（同名 `decide` 会让一个类无法同时实现两个阶段）；`KernelToolCall.origin` 透传原始工具调用（保住 Gemini `thoughtSignature` 等内核不建模的字段）；`KernelContextOverflow` 携带原始错误与堆栈，供适配层在不可恢复时原样抛出。

**1b**：

| 方案原文 | 实际做法 | 原因 |
|---|---|---|
| 阶段实现放 `lib/src/features/agent_kernel/` | 放在 `chat_send_api_runner_kernel.dart`，作为旧 runner 库的 `part` | 直接复用旧 runner 的库内私有辅助函数，不搬动、不复制旧逻辑；旧 runner 只多了 `part`、`implements ApiRunner`、一处 `show ProviderAdapter` 三处机械改动 |
| 新增 `AgentApiClient.close()` | 未加 | 取消本批不接线，加了就是没人调用的代码；接线取消时再加 |
| run 作用域由 `KernelApiRunner` 持有 | 1b 未建作用域 | 非预设路径没有需要释放的资源；1c 接入预设运行时再引入，规则不变 |
| 按 run 回退 | 已实现：带预设脚本、工具中含 `draw_image`（schema、显式工具、绑定工具或插件工具任一）或 `maxRounds < 1` 时整次委托旧 runner | 同方案 |
| 后台接线 | 新增 `backgroundApiRunnerProvider`（可在测试中覆盖），`_defaultExecutor` 同走 `createApiRunner` | 便于断言接线 |

生图路线的⑤⑦⑧⑨逻辑已一并搬入（快速路线判断、并发、补充轮预算、稳定审图），但在 1c 补齐 C 组测试前仍由回退规则拦住、不会走到。

**验证**：`chat_send_api_runner_*` 6 个文件、`kemini_transport_pipeline_test`、后台服务测试对两种 runner 参数化，共 103 项通过；其中内核路径实际执行 14 项，其余按回退规则走旧 runner。新增 `kernel_api_runner_differential_test.dart`：12 个场景（无工具、多工具＋插件后处理、仅 boundTools、文本兜底与去重、最大轮次、流式失败回退、流式带工具、超限恢复、无压缩器超限、非超限错误、Claude 内容块、Gemini 思考签名与隐藏思考）在新旧 runner 上逐字段比较请求、回调、Trace 阶段与 `ApiCallResult`，全部一致；人为在内核里埋两处错误（恢复时不强制压缩、跳过插件后处理）均被对应场景抓到。`voice_chat_snapshot_test` 用的是替身 runner，与本批无关，未参数化。

**真实模型**：`test/features/background_agent/kernel_real_model_test.dart`（设置 `DEEPSEEK_API_KEY` 才运行）经真实后台服务跑记忆 Agent 与摘要 Agent，新旧执行器工具轨迹一致，2 项通过。

**未做**：B 组第 7a 项（真实 `KernelApiRunner` 作用域生命周期）随 1c 引入作用域时补。

**1c（2026-10-08）**：

- 预设：run 初始化（预设工具 schema 合并查重、业务工具 handler、`toolChoice`、诊断日志）、①首次／恢复两模式的预设 `prepare`、②“预算检查 → reset → 发送”与 50ms 合并的传输预览和输出排空、流式回退时 `reset(false)` 与已流出文本清空、③ `presetRuntime.response()` 解包与“已消费”标志、⑨预设路径下 Gemini `model`→`assistant`，全部搬入 `chat_send_api_runner_kernel.dart`。
- 预设运行时登记在 run 作用域，`KernelApiRunner` 在循环与结果处理都结束后的 `finally` 中释放（B 组 7a）；为测试释放时机加了 `scopeFactory` 构造参数。
- 删除按 run 回退：只剩 `maxRounds < 1` 交旧 runner。
- 前台：`ChatSendBackendService` 的执行器改为 `ApiRunner`，默认 `createApiRunner(useKernel: kAgentKernelChat)`。

**验证（1c）**：预设、Kemini、快速／稳定生图测试改为真正跑内核后全部通过（chat/services＋后台＋语音快照共 274 项）；差分测试增至 15 个场景＋2 个作用域生命周期测试。埋错检查：保留已被预设消费的工具调用 → 6 项失败；跳过稳定审图 → 3 项失败；快速路线改串行 → 起初**无测试发现**，补上“纯生图批次并发／混合工具回落串行”两个场景（须显式打开快速模式，默认设置下未知模型走稳定路线）后被抓到。真实模型（DeepSeek Flash）：后台记忆、后台摘要、前台流式聊天带工具三组新旧一致（前台两边同样调用一次工具、同样 9 段流式输出、回复逐字相同）。

**仍未做**：Mac 实机打开 `AICOVE_AGENT_KERNEL_CHAT` 聊天验收（普通回复、生图快速／稳定、预设传输）；它会用用户真实数据与模型额度，需用户确认后进行。

