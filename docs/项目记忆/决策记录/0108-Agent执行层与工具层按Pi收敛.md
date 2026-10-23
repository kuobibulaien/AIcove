---
status: implemented
date: 2026-10-22
---

# 0108：Agent 执行层与工具层按 Pi 收敛

## 背景

「我想玩这个」在旧聊天执行器的第五轮结束，留下过程话术而没有结果。问题不只是上限偏小，而是把短聊天的停止、文本猜调用与结果改写规则当成了通用 Agent 规则。依据《code-mode照抄Pi实施方案》及内核审计的九项探针实施；Pi 对照版本 `476a303`。合入 main 后，审批遵循 ADR0106／ADR0107；后台同步遵循 ADR0104，空间网页运行遵循 ADR0105。

本 ADR 取代 ADR0098 第 3、4 条中旧 JS／shell 的工具名、参数、期限和脚本审批限制；取代 ADR0101 的轮数预算、budgetExhausted、旧执行器回退与自然语言 checkpoint 条款。文件撤销、条件提交、快照恢复、隐私授权和其他可靠性机制继续有效。

## 决定

### 执行由同一个内核负责

- 删除任务轮数上限及可选轮数／费用／总运行时长预算。模型自然结束或用户取消；快速生图已经交付时可业务停止，不保留其额外补充轮数上限。
- 结构化工具调用是唯一执行来源。`length` 携带工具时一律回错误并要求完整重发；没有工具时返回 truncated。不再猜 `<execute_tool>`，不按名称＋参数去重，不按工具名把失败改成成功。
- 通用工具超时仍采用现有 30 秒配置，但先取消调用局部信号，等待至多 5 秒收尾；不能确认停止时明确 `outcome_unknown`。脚本、命令自管期限，默认无限，用户取消可终止。
- 工具可通过类型化 `KernelStopReason` 要求停止；等待用户时同批后续调用不启动，记录未执行结果。停止原因跨执行阶段传枚举，只在 `ApiCallResult`／存储边界转字符串。
- 助手响应在副作用前记录；结果、最终答复及取消占位在停止判断前入账。encoder 是无 I/O 的记录格式转换，下一轮的请求准备另行执行。checkpoint 直接保存内核 transcript，系统提示每次装配，不重复存入历史；旧 checkpoint 仍可读取。运行时压缩继续保留结果引用。
- `ChatSendApiRunner` 仅作为历史入口转发。所有聊天、杂活、主动回复、语音、摘要、记忆都使用 `AgentLoop`；删除两个编译期开关，不存在第二套循环。预设响应处理、图片审核、投影和交付在独立产品阶段适配器中，批次并行只看效果声明与审批需求，不看生图快慢路由。

### 工具少声明，能力不减少

- `AITool.exposure` 为 direct／codemode／deferred，默认 direct。只有工具模式和杂活装配启用 compact loadout，纯聊天角色保持原装配。
- 桌面直接声明 read／write／edit／bash／codemode；手机不声明 bash。其他应用、工作区和结果回读工具放在 codemode，MCP 默认 deferred；仍可检索并调用。
- 文件和命令工具相对运行时 cwd，不接受 workspace 参数。open({id})、create 会切换 cwd；授权与撤销仍由 WorkspaceStore 负责。安装扩展的显式来源选择键改为 workspaceId，不与文件操作的 cwd 参数混淆。
- JSON Schema 渲染为 TypeScript 声明，包含必填、数组、联合、局部引用及约束标签；输入类型超过 16000 字符降为 unknown。说明总预算 3000 估算 token，分 namespace 轮转选择；未列工具通过 BM25 searchTools／describeTool／describeNamespace／ALL_TOOLS 发现。

### codemode 使用现有 QuickJS 异步宿主

- 唯一参数 code。首行 @options 只允许 max_output_tokens（默认 10000）与 timeout_ms（可选）；没有默认超时。同步预设运行时不变。
- 顶层 await／return、text／image／console／exit、store／load、工具目录、fetch 和二进制 ws 读写可用。没有 Node、原生文件系统或定时器。fetch 保留是手机端的必要能力：走应用 HttpClient／系统代理，不检查公网地址；保留 8 MiB 与五跳重定向限制，响应头支持 get／has。
- 脚本本身以 external 效果参与现有闸门，覆盖内置 fetch／ws 字节写入；嵌套工具仍独立经过闸门。外层拒绝或参数错误同样保存为 Script failed 和空调用列表。
- 每个嵌套调用经过与直接调用相同的校验、闸门、脱敏与取消。取消脚本会取消在途嵌套调用；脚本不能递归调 codemode，已发生副作用不撤销。审批遵循 ADR0107：默认直接执行、不走审核模型；用户开启「修改前每次问我」后，直接与嵌套调用均逐次确认。bash／安装不声明 requiresHumanApproval，handler 接受 allowed；手动 approved 仍需真人标记。
- 嵌套输出按 outputSchema 返回结构化值，否则返回文字；失败、拒绝和参数错误 reject Error。bash 非零退出码是结构化结果，不变成调用异常。
- store／load 按 conversationId 或 taskId 隔离，只在成功脚本后原子保存；单值不超过 262144 字符，合计不超过 1048576 字符。状态在本地 `.codemode-state/`，不做同步。
- 输出以 Script completed／Script failed 开头，包含耗时、文本／图片路径、console、错误及嵌套摘要。超量保留头尾，全文保存 `.aicove/outputs/`，不再经过通用工具结果的二次截断。

### 持久化供界面直接消费

- 最后一条助手消息的 rawPayload.runStatus 为 truncated／waitingForUser／cancelled／failed；completed 不写键。可选 stopReason 为字符串。取消时先保全已有回复，再清临时态；重载投影只把状态附在最后一条助手气泡。
- codemode ToolBlock.arguments 只有 code；result.content 是模型看到的完整结果，result.codemodeCalls 始终是列表。每项包含 `<调用 id>/<序号>`、name、紧凑 args（最多 200 字符）、终态 status、可选 durationMs 与 error（最多 300 字符）。结构化元数据与原始消息一起落库。
- 界面由 Claude 在独立提交 `54e114ba1` 消费契约，本次后端不修改 `lib/src/ui/**`。

## 代价与偏差

- 默认不限制任务总时长，磁盘与模型用量由任务本身决定；用户取消、单次请求超时、工具收尾期限仍有效，不是任务预算。
- 审批与 main 的 ADR0106／ADR0107 一致；不新增 shell 装配范围，不绕过工作区授权、隐私隔离、参数校验、取消或文件锁。
- 未提供 transcript 的既有注入 executor 保留原 checkpoint 文本格式；提供 transcript 的内核路径只存执行记录，不丢旧调用方的续做资料。
- 保留 WorkspaceScript.extension 的已发布资源与 tools.list／describe 契约；新 codemode 使用新目录全局，避免破坏已有扩展。
- Pi 仓库浅克隆的 HEAD 已前进到 be14d97，随后另取固定 476a303 的五份源文件核对。移植保留上游 MIT 来源，未引入新核心依赖。

## 验收

离线和真实模型的逐步提交、命令、计数及产物路径见本次 `codex-backend-report.md`；源测试包括 agent_execution_audit、transcript、codemode、workspace_cwd、chat_run_status_persistence、unified_api_runner 及调用方契约 fixtures。Mac 原生 QuickJS／进程／HTTP 已在测试中执行；手机实机与 Windows 未验。源码渲染预览由界面负责人交付。
