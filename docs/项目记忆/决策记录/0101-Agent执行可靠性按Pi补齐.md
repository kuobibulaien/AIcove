---
status: accepted
date: 2026-10-22
---

# 0101：Agent 执行可靠性按 Pi 补齐

关联：ADR0038（上下文）、0064（内核）、0088（后台杂活任务）、0097（工具模式角色）。0061 的按时间清理与 0062 的陪伴压缩口径不在本批实施。

## 背景

对照 Pi 固定提交 `58c0b02ce552adab76014e7ed712ab7981359aa8` 的调查发现：内核的轮数耗尽状态在 App 适配层丢失；杂活任务未装配运行时压缩；取消没有到达 HTTP；大结果与续做记录直接截断；过程要等整个 runner 返回才保存。已有工具循环无需重写，补齐这些边界即可改善长任务执行。

## 决定

### 1. 结束状态不能由回复文字推断

> 2026-10-22：本节的轮数预算、`budgetExhausted` 与预算续做机制由 ADR0108 取代：删除轮数上限，不保留可选预算；下列条目是原决定的历史记录。

- `ApiCallResult` 与 `TaskRunOutcome` 使用 `ApiRunStatus`：`completed / budgetExhausted / cancelled / failed`，另带 `stopReason`。内核的 `maxRounds` 映射为 `budgetExhausted`，快速生图主动结束等原有业务停止保留原语义。
- 保持调用方原来的异常契约：取消仍抛 `KernelCancelledException`，失败仍抛原异常；任务服务分别结案为 cancelled／failed，不把异常包装成正常回复。
- 杂活预算耗尽结案为 needsInput，问题固定为「工具轮数用完了，任务还没做完。要我接着做吗？」；摘要取最后一轮模型原话，空时用「做到一半，轮数用完了。」。回答后沿用既有 reply 链路，并携带已完成工具结果。
- 工具模式聊天返回同样状态，日志与最终 trace 元数据记录状态、停止原因。旧执行器也保留轮数耗尽状态，不能再次假完成。

### 2. 共用上下文服务，结果引用属于任务／会话

- 杂活任务装配聊天已有的 `RuntimeContextService`、`ContextWindowPolicy` 与同一个 `contextSummarizerProvider`；预算包含新增工具 schema。当前模型轮次的溢出恢复沿用原来的单次强制压缩，不重跑工具。
- checkpoint 在原有 JSON 文件中增加可选 `messages`，保存任务说明、逐个已完成步骤的文本资料与用户回答／追加要求；旧 checkpoint 仍可直接读取，无数据库迁移。提供给模型的是这些独立消息，完整自然语言 transcript 仍留作记录。不能把不断增长的历史全部塞进一个受保护的“最新用户消息”，否则无法压缩。
- 新增共享 `ToolResultStore`。文本超过 **8192 个 UTF-16 码元**时，先完整写入，再向模型返回随机引用、前 4096／后 1024 码元预览。MCP 不再在传输层截去 20000 字符以后的内容；task transcript 不再做 2000 字符硬截断。运行时压力裁剪也使用同一存储服务。
- 存储位置：`appDataDirectory()/agent_tool_results/<base64url(owner)>/<随机128位reference>.txt`。owner 是 taskId 或 conversationId，不是单轮 runId。引用没有绝对路径；只读工具 `read_tool_result(reference, offset=0, limit=4096)` 只能读取当前 owner，不能跨任务／会话或读取任意路径。offset／next_offset 使用 UTF-16 码元；limit 上限 8192，JSON 转义后过大时缩小实际页，下一页以 next_offset 为准，页边界不拆 Unicode 字符。
- 压缩摘要之外显式保留原始 `reference=...`，不依赖摘要模型记住引用。读回工具的返回页也控制在行内上限内，避免生成“引用的引用”。
- **保留与清理**：只在本机保存，不加入云同步，不按时间或大小自动删除，避免尚可续做的引用过期。随应用数据保留；清理属于用户另行授权的本机数据清理操作，本批不新增清理入口。代价是磁盘占用随大结果增长。

### 3. 每步先落盘，再执行后续步骤

- 内核工具执行器的外层逐个接收已结算结果（包括拒绝／校验错误），经过现有脱敏后保全完整文本，并 await 任务服务的 step 回调。杂活带持久化回调时使用串行批次；普通聊天仍保留原有批次并行策略。
- 每步原子替换 checkpoint 并追加过程日志。追加要求、回答与步骤写入由同一任务的串行写入链协调，避免临时文件互相覆盖。收尾只补摘要，不重复追加整批工具日志。
- 外部副作用开始前 await `markSideEffectUncertain`，保留原有语义。重启仍将运行中任务标为 interrupted，不自动重放未确定完成的外部调用；最后已完成的步骤、结果引用与消息资料留在 checkpoint 中。

### 4. 同一取消信号贯通请求与工具

- 各 provider adapter 只负责格式转换，实际 HTTP 共用 `AgentApiClient`。通过请求局部 `RequestControl` 把 `KernelCancellation` 交给 `http.AbortableRequest`，同时让 runner 立即结束等待；响应头前的非流式请求和响应头后的流式读取都可中止。请求局部 Zone 不改变现有 client／adapter 方法签名。
- 每次模型尝试有独立取消信号，继承本轮取消；失败、超时和退出时中止该次 HTTP，再开始下一次尝试。单次尝试不另设总时长，沿用客户端原有超时（流式只限到响应头），长回复和慢思考不会被截断重试。取消不会触发流式回退或重试。压缩请求也继承调用链取消信号。
- 聊天生成任务持有取消信号，软中断在清理临时态之前发出取消；模型切换链遇取消直接退出。`ApiConfig.copyWith` 保留运行控制、预设 runtime、响应处理器及其他快照字段。
- `AITool.controlledHandler` 可选接收取消信号与 progress 回调；一参数 handler 与 richHandler 原签名保留。MCP 接入请求级 abort，不关闭共享客户端；共享握手被一个任务取消时，未取消的等待者重新握手，不继承其他任务的取消，也不重放工具调用；workspace 在执行和提交边界检查取消，并报告进度。旧的不支持取消的 handler 仍需自行结束，不宣称能撤回已发生的外部操作。
- `TaskAgentService.steer(taskId, instruction)` 先持久化要求：运行中交给当前 `AgentLoop.steer()`，启动装配期间暂存，排队／等待中并入下次上下文。最终模型回复返回时若仍有 steering，要再执行一轮；继续执行直到自然结束，不能丢掉新要求。聊天派活插件新增 `steer_task`，不增加界面。当前追加要求只作用于本机拥有的任务；未扩展跨设备 control 协议。

### 5. 工具先校验，模型只重试当前轮

- 统一在 handler 前检查 JSON Schema 常用子集：object／array／string／integer／number／boolean／null、required、enum、const、嵌套 properties／items、additionalProperties、长度／数量／数值上下限。未知关键词交给现有 handler；未实现完整 JSON Schema、远程 `$ref` 或组合逻辑。
- 错误作为 `isError=true`、`error.code=invalid_tool_arguments` 和带字段路径的 details 返回模型。MCP 单独保留原始 validationSchema，供应商 schema 投影丢掉的关键词不会影响执行校验。
- 429、5xx、网络断开和超时最多重试 3 次（含首次最多 4 次请求），退避 500／1000／2000 ms；Retry-After 支持秒数和 HTTP 日期，作为最短等待时间。等待可取消，400 等永久错误不重试。重试闭包仅包住当前模型请求，之前的工具不重放。

## 契约变化与范围

- 请求里有可能产出长结果的工具时才增加 `read_tool_result`；只有 `delegate_task`／`steer_task` 的普通聊天请求不带它（`ToolResultStore.wantsReader`）。聊天派活能力另增 `steer_task`。对应请求 golden 已更新，原有 messages 未改变，未通过过滤差异来放宽新旧执行器对照。
- 新控制链、逐步持久化和退避重试以默认启用的内核执行器为交付入口。编译时显式关闭内核的旧执行器保留作对照／回退，不承诺这些内核能力；本批只同步其结果状态、工具 schema 和公共参数校验。
- 不改 widget、数据库 schema、生产环境；不做调查报告第 5、6 项。

## 验收证据

- App：`agent_reliability_regression_test.dart` 将原调查探针改成已修复断言；`agent_execution_reliability_test.dart` 覆盖预算续做、长任务压缩／溢出、引用回读、N 步后中断恢复、steering、进度、校验与退避；`provider_cancellation_test.dart` 用本地 HTTP 服务验证四类适配的流式／非流式 abort 和 MCP abort；聊天动作测试覆盖软中断信号。
- 内核：原有测试加最终回复期间 steering、预算边界 steering 与取消绑定回归。
- 真实模型（DeepSeek Flash）：`agent_reliability_real_model_test.dart` 5 项通过——3 轮预算做 5 步，等待后续做且每步只执行一次；2.4 万字结果经 `read_tool_result` 读到尾部暗号；运行中追加的步骤被执行；流式取消 2ms 返回且之后无输出；首个 503 带 Retry-After 后同轮重试成功。
- 完整执行记录、全量测试的范围外失败和未验证项见本地 `scratch/agent-reliability-20261022/report.md`。手机、Windows 和跨设备控制未实测。
