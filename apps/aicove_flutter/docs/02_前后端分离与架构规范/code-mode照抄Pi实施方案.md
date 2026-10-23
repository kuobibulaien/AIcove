# Agent 执行层修复与 code mode 照抄 Pi 实施方案

- 日期：2026-10-22
- 合并来源：本次现场排查；Codex 内核设计复核（原始材料在主目录 `scratch/agent-kernel-design-audit-20261022/`；9 项探针已迁入本分支的 `agent_execution_audit_test.dart`、`chat_run_status_persistence_test.dart` 和内核 `transcript_test.dart`。原审计针对主目录 HEAD `03a9edf5b`，不含本 worktree 已删的轮数上限）。
- 用户决定：轮数上限直接删除，**不保留可选预算**（Codex 报告第 1 条建议的「预算作为可选策略」不采纳）。
- 状态：已实施（2026-10-22，后端步骤 1～11；第 3 步界面由 Claude 在独立提交交付）。ADR0108 已登记，取代 ADR0098 第 3、4 条及 ADR0101 的预算、旧执行器和 checkpoint 冲突条款。本次合入 main 后审批遵循 ADR0106／ADR0107：默认免审批、不走审核模型，主动开启「修改前每次问我」后才逐次确认。
- 对照版本：badlogic/pi-mono `476a303`（2026-10-22），读 `packages/coding-agent/src/extensions/codemode/{tool,execute}.ts`、`packages/coding-agent/docs/codemode.md`、`packages/codemode/src/{declarations,source}.ts`、`packages/agent/src/agent-loop.ts`。
- 用户原话：「我们为什么会有个工具轮数上限？pi 没有，我们就把这玩意儿删了」「工作区参数说明我们的 code mode 和没写一样」「不要担心安全风险了，我们是本地软件」「规划一下 code mode 方案（照抄 pi），让模型别再因为调用工具而产生一堆问题」。

## 1. 现场：一次「我想玩这个」为什么失败

2026-10-22 05:02，Mac，AIcove酱，deepseek-flash，trace `tr_1792670560031032`（`~/Library/Containers/com.example.aicoveFlutter/Data/Documents/logs/trace/`）。

| 轮 | 调用 | 结果 |
|---|---|---|
| 1 | `workspace_run_js` 里 `fetch` README | `DNS returned a non-public address`（用户代理开 fake-ip，域名解析到 `fdfe:dcba:9876::4`，被 `public_network.dart:126` 拒绝） |
| 2 | `workspace_shell` curl README | 成功 |
| 3 | 查 Release、Pages | 成功 |
| 4 | 查 Release 详情 | 成功 |
| 5 | 下载 `index.html` | `invalid_tool_arguments: $.workspace Required property missing` |
| — | 轮数上限 5 到了，循环停止 | 把第 1 轮的「我看看……」当最终回复交付，界面像做完了 |

同一请求里模型收到 **68 个工具、约 2.8 万字符的 schema**（55 个 `aicove_*` + 12 个 `workspace_*` + `read_tool_result`），系统提示 1.2 万字符。Pi 只声明 `read`／`bash`／`edit`／`write`（＋`codemode`）。工具太多、参数太多、每个工具都要带 `workspace`，是小模型反复调错的根源。

## 2. 已经做完、未提交（Codex 先接手收尾）

在本 worktree（`claude/performance-issue-diagnosis-ccfda2`）里，**轮数上限已按 Pi 全部删除**，未提交：

- 内核 `packages/aicove_agent_kernel`：`AgentLoop`、`TurnContext` 去掉 `maxRounds`／`isLastRound`，循环跑到模型不再调用工具为止（Pi `agent-loop.ts` 的 `while (hasMoreToolCalls …)`）。内核测试 67 项已通过。
- 应用层：`ApiRunner` 接口、`KernelApiRunner`（含删掉 `needsLegacyRunner`）、旧执行器 `ChatSendApiRunner`、聊天服务链、后台 Agent、`AgentDefinition`、`BackgroundAgentDefinition`、`TaskAgentPreset`、各单次调用方，全部去掉 `maxRounds`。`ApiRunStatus.budgetExhausted` 及杂活「轮数用完了，要接着做吗」分支删除。快速生图「补一轮」的业务停止保留（日志键改名 `fastFollowupRounds`）。
- 测试：依赖上限的用例改为「没有上限、多步一次跑完」：内核 `agent_loop_test`、`agent_execution_reliability_test`、`agent_reliability_regression_test`、`agent_reliability_real_model_test`、`kernel_api_runner_differential_test`；其余只删参数。`flutterw analyze lib test` 无 error。
- **还没做**：改动过的测试没跑完（被中断）。先跑：

```bash
cd apps/aicove_flutter
git diff --name-only -- test | grep -v real_model | sed 's#apps/aicove_flutter/##' | xargs tool/flutterw test
```

  失败的按「没有轮数上限」的语义修，不要把上限加回来。注意原来 `maxRounds: 1` 的单次调用方（主动回复、语音回复、摘要、上下文分析）现在如果模型调了工具会继续跑到出最终文字，这是有意的。
- 改 ADR0101 第 18–21 行里「`budgetExhausted`／needsInput」的描述（标注被本次取代）。

## 3. 目标

1. 模型面对的工具像 Pi 一样少而稳：**直接声明的只有 `read`、`write`、`edit`、`bash`、`codemode`**（手机端没有 `bash`），其他工具都通过 `codemode` 脚本调用。
2. `codemode` 照抄 Pi：一个参数 `code`，脚本里 `await tools.xxx({...})`，模型在工具说明里直接看到 TypeScript 声明，不用先查清单。
3. 文件／命令工具不再有 `workspace` 参数，像 Pi 的 cwd 一样由运行决定。
4. 嵌套调用出错时 reject 一个带原因的 Error，脚本自己 `try/catch` 或 `Promise.allSettled` 处理，不再把一次参数错误变成一整轮浪费。
5. 去掉「只能访问公网」的限制（用户决定：本地软件，不做这层防护）。
6. 执行层不再「做错了也当成功」：截断的调用不执行、不从正文猜调用、超时真停、等待用户真等、非正常结束让用户看得到（第 4 节）。
7. 没有轮数上限，也不留可选预算；任务跑到模型自然结束，或被用户取消。

## 4. 先修执行层（Codex 报告，先于 code mode）

code mode 让一次调用做更多事，执行层不稳时出错代价更大，所以这一节先做。每条先把 Codex 对应探针改成「期望修好后的行为」的复现测试，再改代码。行号以主目录 HEAD 为准，本 worktree 删上限后有偏移。

### E1 输出被截断时不执行工具（报告第 3 条）

- 照 Pi `agent-loop.ts:273–279`：模型回复的结束原因是 `length`、又带了工具调用时，**这条回复里的工具一个都不执行**。每个调用回一条错误结果：「输出达到长度上限被截断，这次调用没有执行，参数可能不完整。请重新完整调用。」然后继续下一轮，让模型重发。
- 结束原因是 `stop` 但带了工具调用：照常执行（Pi 同），保留现在的诊断事件。
- `length` 且没有工具调用：结果状态记为截断（见 E5），不当成正常完成。
- 位置：`packages/aicove_agent_kernel/lib/src/agent_loop.dart`（FinishReasonMismatch 那段）；`test/agent_loop_test.dart` 里 `reason: 'calls still run'` 的旧预期改掉。

### E2 不再从正文里猜工具调用（报告第 4 条）

- 照 Pi：只执行模型原生返回的结构化工具调用。删除默认的正文 `<execute_tool>` 等格式解析（`chat_tool_fallback_parser.dart` 及 `chat_send_api_runner_kernel.dart` 里的 fallback 分支、旧执行器同类分支）。
- 先查有没有模型／预设真的依赖这个文本协议（比如某些渠道配置或酒馆预设）。**没有就整段删除**；有的话改成该渠道显式开启的兼容开关，默认关，并在汇报里列出依赖方。
- 删掉按「工具名＋参数」整次运行去重的逻辑。同参数重试、重复读取、轮询都是合法的；防重放只按调用 id 和执行状态判断。
- 差分测试 `kernel_api_runner_differential_test.dart` 里「文本工具兜底解析与重复跳过」场景随之删除或改写。

### E3 超时要真的停下工具（报告第 6 条）

- 通用包装（`chat_send_api_runner_tool_support.dart` 里 `operation.timeout(toolTimeout)`）改为：超时时通过 `ToolCallContext.cancellation` 取消这次调用，再**等工具收尾**（给一个短的收尾期限，比如 5 秒）后才返回。
- 收尾期限内确认停下 → 普通超时错误。确认不了（外部调用、不响应取消的 handler）→ 结果标为「结果未知」：「工具超时，已请求停止，但无法确认它是否已经生效。重试前先检查当前状态，避免重复操作。」不当普通失败，避免模型盲目重做。
- 自管期限的工具（`bash`、`codemode`、HTTP）维持各自语义；第 5 节 code mode 要求它们默认不设超时。
- 通用默认 30 秒是否保留：保留，但要真停；Pi 没有统一的工具超时，后续如果都有自管期限可以去掉。

### E4 `ask_user` 真正进入等待（报告第 5 条）

- `ask_user` 执行后，**同一批里排在它后面的调用不再启动**，各回一条「未执行：任务已在等待用户回答」。
- 这一轮的工具后判断直接停止，停止原因 `waitingForUser`，不再靠提示词「不要再调用工具」。工具结果只回「问题已记下」。
- 停下前，助手消息、已执行的结果、未执行的占位都按 E7 入账；任务服务据此转 needsInput。
- 位置：`task_agent_runner.dart`（askTool）、内核批执行 `_runBatch`、`TurnVerdict`。内核需要一个通用的「工具要求本轮结束且跳过同批剩余调用」的结果标记，不要在内核里写死 `ask_user` 这个名字（Pi 的 `terminate` 是批后语义，这里按报告要求更严一档）。

### E5 运行状态一路传到界面（报告第 2 条，去掉预算部分）

- 没有轮数上限后 `budgetExhausted` 已删。剩下要贯通的非正常结束：截断（E1 无工具的 `length`）、等待用户（E4）、取消、失败、快速生图主动结束这类业务停止。
- `ApiRunStatus` 改为 `completed / truncated / waitingForUser / cancelled / failed`；业务停止仍算 `completed`，但 `stopReason` 保留。
- 聊天前台：非 `completed` 时在回复下方显示一行状态（如「回复被长度上限截断」「已停止」），原始消息里保存 `status`／`stopReason`，重载后还在。复用现有消息附注组件，不新建公共组件。
- 位置：`chat_send_service.dart`、`chat_message_projection_codec.dart`、`chat_actions.dart`（报告第 2 条列的行）。

### E6 通用执行器不按工具名改写结果（报告「次要」条）

- 删掉 `chat_send_api_runner_tool_support.dart` 里把名为 `speak` 的工具结果无条件改写成「语音已播放」的分支；工具自己返回什么就是什么。

### E7 完整执行记录（报告第 7 条，code mode 之后做）

- 照 Pi：每轮的助手消息、工具调用和结果**先入账**，再判断继续还是结束。`runningMessages` 在任何结束方式下都是完整记录（含最终回答、最后一批工具结果、E4 的未执行占位）。
- 把「渲染下一轮请求」和「入账」拆开：encoder 只负责把记录转成请求格式；入账不依赖是否继续。
- 任务 checkpoint 改为直接存这份记录，不再自己拼自然语言步骤；旧 checkpoint 读取保持兼容。

### E8 收成一套执行器（报告第 8 条，最后做）

- 把 `_KernelRun` 里的产品逻辑移出循环控制：生图快慢路由、媒体审核、展示投影、预设脚本各自成为阶段插件或适配器；工具串行／并行改成通用策略（按工具声明的 effect 与是否需要确认决定），不再和「是不是快速生图」绑定。
- 停止原因用枚举，不跨层比字符串。
- 先补关键调用方（聊天、杂活、主动回复、语音、摘要、记忆）的契约测试，确认内核执行器全覆盖后，**退役旧执行器 `ChatSendApiRunner` 的循环**，`kAgentKernelChat`／`kAgentKernelBackground` 开关一并移除。不另建第三套执行器。

## 5. code mode 决定（逐条对照 Pi）

### 5.1 工具名与工具数量

| Pi | 我们（新） | 现在 |
|---|---|---|
| `read` | `read` | `workspace_read` |
| `write` | `write` | `workspace_write` |
| `edit` | `edit` | `workspace_edit` |
| `bash` | `bash`（仅桌面端） | `workspace_shell` |
| `codemode` | `codemode` | `workspace_run_js` |

- 改名理由：模型对 `read/write/edit/bash` 有很强的先验，参数也照 Pi（`path`、`offset`、`limit`、`content`、`edits[{oldText,newText}]`、`command`、`timeout`），减少拼错。
- `workspace_list`／`glob`／`grep`／`move`／`delete`／`open`／`create`、`read_tool_result` 和全部 `aicove_*` 工具改为 **codemode 曝光**：不在请求的 `tools` 数组里声明，只能在脚本里 `tools.xxx()` 调用。
- 照 Pi 的曝光分级 `ToolExposure = direct | codemode | deferred`（Pi 还有 `model-only`、`hidden`，我们只需要这三种）：
  - `direct`：声明给模型，也能在脚本里调。`read/write/edit/bash/codemode`；`codemode` 自己是 `model-only`，脚本里不能再调 `codemode`。
  - `codemode`：不声明给模型，`codemode` 的说明里按预算列出 TypeScript 声明。
  - `deferred`：不列声明，只能用 `searchTools()`／`describeTool()`／`ALL_TOOLS` 找到再调。MCP 工具默认 deferred（Pi 同）。
- 曝光放在 `AITool` 上（新字段 `exposure`，默认 `direct` 保持其他角色行为不变），**AIcove酱 和工具模式角色**切到上表；纯聊天模式角色不受影响。
- 照 Pi 的 `codemode.mode`：默认 `on`（direct 工具照常声明，说明里写怎么从脚本调）。只做 `on`，不做 `only` 开关（YAGNI）。

### 5.2 工作区 = cwd

- 每次运行有一个**当前工作区**：AIcove酱 是 `aicove`；工具模式角色是它的默认工作区；杂活 Agent 是派活时选定的工作区。
- `read/write/edit/bash` 和脚本里的文件工具都不带 `workspace` 参数，路径相对当前工作区。
- 有多个授权工作区时，保留一个 codemode 曝光的 `workspace_open({ id })` 切换当前工作区（之后的调用都相对新目录，像 `cd`）；`workspace_create` 建完自动切过去。系统提示里列出可用工作区和当前是哪个。
- `WorkspaceToolset` 内部保持按 id 访问 store，只是参数从「模型传」改成「运行状态给」；撤销、条件提交、符号链接规则都不变。

### 5.3 `codemode` 工具本身

照抄 Pi `tool.ts`、`docs/codemode.md`：

- **参数只有 `code`**（`{"type":"object","properties":{"code":{"type":"string","description":"Raw JavaScript source."}},"required":["code"]}`）。去掉 `workspace`、`path`、`args`、`timeout_seconds`。
- 可选首行 `// @options: {"max_output_tokens": 10000, "timeout_ms": 60000}`，规则照 `source.ts`：只能在第一行，字段只认这两个，非法就在运行前失败；替换成空行保持行号。
- **默认没有超时**（Pi 同）：`timeout_ms` 不写就一直等，靠用户取消。删掉现在的 30 秒默认和 120 秒上限，`executionTimeout` 改为不限。
- 运行在 QuickJS 异步会话（沿用 ADR0098 已实现的 `aicove_quickjs` 异步会话），顶层 `await`／`return` 可用；没有 Node、文件系统、定时器。
- **说明文字**照 Pi `DESCRIPTION_INTRO` ＋ `describeGlobals` ＋「Nested tools:」段，翻成中文或保留英文都行（建议保留英文原文，模型对英文工具说明更稳；与现有中文工具说明风格冲突时以本条为准）。
- **嵌套工具清单**：照 `createCodemodeDescription`：每个 codemode 曝光的工具渲染成

  ```
  ### `aicove_set_role_voice`
  /** 工具说明 */
  aicove_set_role_voice(args: { roleId: string; voiceId: string }): Promise<string>;
  ```

  JSON Schema → TypeScript 类型照 `packages/codemode/src/declarations.ts` 移植（`renderToolSignature`、`docComment`、标签 `@minimum` 等），输入类型超过 16000 字符渲染为 `unknown`。按 namespace 分组（`aicove`、`workspace`、每个 MCP 服务器一个），预算 3000 估算 token（字符/4），超出预算用 Pi 的 `selectCatalog` 轮转挑选，标注「(some tools not listed)」。
- direct 工具的说明末尾追加一行（Pi `describeScriptCall`）：`` Codemode: `tools.read(args)` resolves to a string. ``

### 5.4 脚本里的全局（照 Pi 全量，`models` 除外）

| 全局 | 说明 |
|---|---|
| `tools.<name>(args)` | 名字里非标识符字符换成 `_`（Pi `toCodemodeIdentifier`）。声明了 `outputSchema` 的工具 resolve 为结构化值，其他 resolve 为文字。失败、被拒、参数不合法 → **reject `Error`，message 是工具的错误文字**。 |
| `text(v)`、`image(v)`、`console.*`、`return`、`exit()` | 输出规则照 Pi：多段文字每段前加 `==> text N/M <==`，console 统一放在 `<console_output>` 块里；`image()` 存一份到 `.aicove/outputs/` 并在结果里写路径。 |
| `store(key, value)`／`load(key)` | 跨 `codemode` 调用保存小 JSON，脚本成功才落盘；按会话（聊天 conversationId／杂活 taskId）存，单值 ≤ 262144 字符、合计 ≤ 1048576。 |
| `ALL_TOOLS`、`searchTools(q,{limit,namespace})`、`describeTool(name)`、`describeNamespace(name)` | 照 Pi；`searchTools` 用 BM25，默认 8 条。取代现在的 `tools.list()`／`tools.describe()`。 |
| `fetch(url, opts)` | **偏离 Pi**（Pi 沙盒没有网络）：手机端没有 `bash`，脚本是唯一能联网的地方，所以保留。**去掉公网限制**：`PublicNetwork` 改为直接 `HttpClient`，走系统代理，不再检查解析地址（修 fake-ip 代理下 `DNS returned a non-public address`）。保留 8 MiB 和重定向次数限制，超时改为跟随脚本。表情导入的抓取同步放开。 |
| `ws.readBytes`／`ws.writeBytes` | 保留（二进制读写，Pi 靠 bash 做；手机端需要）。路径相对当前工作区，去掉 workspace 参数。 |
| `models` | **不做**：我们没有分类器、生图模型目录。 |

### 5.5 嵌套调用走同一条管线

照 Pi「Nested calls run through the agent loop's tool pipeline」：

- 嵌套调用经过和直接调用完全相同的参数校验、闸门、脱敏、取消。
- **审批按 ADR0107**：默认直接执行、不走审核模型；用户开启「修改前每次问我」后逐次确认。嵌套调用与直接调用走同一工具闸门，bash／安装不声明 requiresHumanApproval，手动批准仍核对真人标记。闸门允许就执行，需要确认就等待；「修改前每次问我」的拒绝路径已离线验证。删掉现在「需审核的工具请改为直接调用」和「脚本不能调 `workspace_shell`」的限制。脚本不能调 `codemode` 自己（`model-only`）。
- 每个嵌套调用记录为 `<codemode 调用 id>/<n>`，状态 running/ok/error/cancelled、耗时、截断后的参数和错误，界面在 `codemode` 工具卡片里展开显示（照 Pi `renderer.ts` 的 nested calls 列表，用现有工具卡片组件）。
- 脚本结束时还在跑的嵌套调用取消，没 await 的 promise 丢弃。

### 5.6 结果格式

照 Pi `execute.ts`：

```
Script completed            ← 或 Script failed
Wall time 3.2 seconds
Output:
<按顺序的 text / image>
<console_output>
...
</console_output>
Script error:               ← 只在失败时
<stack 或 Script timed out / Script aborted>

<嵌套调用摘要：每个调用一行，名字、状态、耗时、错误>
```

- 失败时保留已经产生的输出；已经执行的嵌套调用不撤销（写在说明里）。
- 输出超过 `max_output_tokens`（默认 10000）保留开头和结尾，全文写 `.aicove/outputs/`，路径写进结果。

### 5.7 `bash` 照 Pi

- 参数 `command`、`timeout`（秒，可选，**默认不限**，Pi 同）；去掉 `workspace`。
- 有 `outputSchema`：脚本里 resolve 为 `{ output, truncated, full_output_path?, exit_code, wall_time_seconds }`，非零退出码也 resolve（Pi 同）；模型直接调用时仍是最后 2000 行或 50 KiB。
- 审批交给本分支既有工具闸门；撤销规则、`.aicove/` 快照、进程树终止，保持 ADR0098 第 4 条。

### 5.8 系统提示

- 工作区段改为：当前工作区名、可用工作区列表、一句「路径都相对当前工作区」。
- 加 Pi 的 codemode 指引：`Use codemode to batch independent tool calls (Promise.allSettled), chain them, or filter large output, instead of many separate calls.`（中文：独立的多个工具调用、要串起来的调用、要过滤的大结果，用 codemode 一次做完，不要一个个分开调。）
- AIcove酱 插件提示词里「工具按范围分：角色卡（aicove_update_role…）…」那一大段工具名清单删掉，改为「AIcove 的设置、角色、预设、渠道等操作都在 codemode 的 `aicove` 分组里，用 `searchTools` 找」。具体位置：`lib/src/features/assistant/application/assistant_plugin.dart` 及其提示词资源。

## 6. 改哪里（给 Codex 的范围）

可以改：

- `apps/aicove_flutter/packages/aicove_agent_kernel/`（E1 截断、E4 批内终止标记、E7 入账、停止原因枚举）及其测试
- `apps/aicove_flutter/lib/src/features/chat/services/`（新旧执行器、`chat_tool_fallback_parser.dart`、`chat_send_api_runner_tool_support.dart`、`chat_types.dart`、`chat_send_service.dart`、`chat_message_projection_codec.dart`）、`chat_actions.dart`、聊天消息附注的界面
- `apps/aicove_flutter/lib/src/features/task_agent/application/`（`ask_user`、checkpoint）
- `apps/aicove_flutter/lib/src/features/workspace/application/`（`workspace_toolset.dart`、`workspace_script.dart`、`workspace_shell.dart`）及其测试
- `apps/aicove_flutter/lib/src/features/plugins/domain/handlers/ai_tool.dart`（加 `exposure`、`outputSchema`）、工具 schema 组装与校验处
- `apps/aicove_flutter/lib/src/features/chat/services/chat_send_api_runner_kernel.dart`、`chat_send_backend_service.dart`（声明时按曝光过滤 tools 数组、当前工作区）
- `apps/aicove_flutter/lib/src/features/task_agent/`（杂活 Agent 同样的装配）
- `apps/aicove_flutter/lib/src/features/assistant/`（AIcove酱 提示词、工具曝光）
- `apps/aicove_flutter/lib/src/core/network/public_network.dart` 及调用方
- 新增：`lib/src/features/workspace/application/codemode_declarations.dart`（移植 Pi `declarations.ts`）、`codemode_source.dart`（移植 `source.ts`）、`codemode_search.dart`（BM25）
- 对应 `test/`，文档 `工作区harness工具层实施方案.md`、ADR

不要改：`packages/aicove_quickjs` 的同步模式（酒馆预设在用）、云同步、聊天模式角色的工具装配（第 4 节执行层修复对所有角色生效，这是有意的）。不要加任何轮数、费用或时间预算。

## 7. 分步

每步先写复现测试，`tool/flutterw analyze` 无 error、相关测试通过后单独提交。

1. **收尾删轮数上限**（第 2 节）：跑完改过的测试，失败按「没有上限」修，提交。同步改 ADR0101 里预算相关描述。
2. **执行层第一批**（第 4 节 E1–E4、E6）：截断不执行 → 去掉正文猜调用和参数去重 → 超时真停 → `ask_user` 真等待 → 删 `speak` 改写。Codex 的 `probe_test.dart` 9 项探针改成修好后的断言，搬进 `test/`。
3. **状态贯通界面**（E5）：`ApiRunStatus` 新枚举、前台状态行、原始消息保存状态。附源码渲染预览图。
4. **去掉公网限制**（5.4 `fetch`）。
5. **工具曝光**：`AITool.exposure`／`outputSchema`；请求只声明 direct 工具；嵌套清单与 TypeScript 声明渲染（5.1、5.3）。
6. **工作区＝cwd、工具改名**：去掉 `workspace` 参数，改名 `read/write/edit/bash`（5.2、5.7）。
7. **codemode 本体**：只留 `code`、`@options`、无默认超时、结果格式、全局、`store/load`、嵌套调用走闸门（5.3–5.6）。
8. **提示词收敛**（5.8）。
9. **完整执行记录**（E7）。
10. **收成一套执行器**（E8）：先补契约测试，再退役旧执行器循环和两个开关。
11. **验收**（第 8 节），写 ADR0108，更新 `docs/项目记忆/README.md`「Agent 运行时」「对照 Pi 改进」「Agent 工作区」三行；有「表面原因≠真实原因」的点记进 `经验教训.md`（本次：「5 轮太少」的表面问题，真实原因是旧聊天执行器规则被当成通用 Agent 规则）。

## 8. 验收

离线（必须）：

执行层：

- Codex 的 9 项探针全部翻转为「已修好」并通过：`length`＋工具调用 → handler 未执行、模型收到重发提示；`length` 无工具 → 状态 `truncated`；代码块里的 `<execute_tool>` 示例不触发工具；同参数失败重试会真的再执行；`ask_user` 同批后面的工具未执行、运行以 `waitingForUser` 停止；超时后原 handler 不再产生后续动作，不能确认停下的标为结果未知；名为 `speak` 的工具失败结果原样返回；最终回答和最后一批工具结果在 `runningMessages` 里。
- 30 轮以上的工具循环一次跑完（内核和应用层各一条）。
- 聊天里一条被截断的回复，重载后仍显示截断状态（源码渲染预览图）。

code mode：

- 声明给模型的 tools 数组：AIcove酱 在 Mac 上恰好 `read/write/edit/bash/codemode`；手机上没有 `bash`。
- `codemode` 说明里出现 `aicove` 分组的 TypeScript 声明，总长不超过预算；超预算的工具能用 `searchTools` 找到并调用。
- 脚本里调用缺必填参数的工具 → `catch` 到的 `Error.message` 含字段名；`Promise.allSettled` 里一个失败不影响其他。
- 脚本里调用 `bash` → 默认直接 resolve 为 `{ output, exit_code, … }`；开启「修改前每次问我」时弹确认，拒绝 → reject。
- 不写 `timeout_ms` 的脚本等一个 5 秒的嵌套调用不会超时；写了 `timeout_ms: 1000` 的会以 `Script timed out` 失败并保留部分输出。
- `store` 写的值在下一次 `codemode` 调用 `load` 得到；脚本失败时不落盘。
- `fetch` 一个解析到 `198.18.x.x`／ULA 地址的域名能成功（用本地假 DNS 或注入解析器测）。
- 没有任何工具参数叫 `workspace`。

真实模型（DeepSeek `deepseek-flash`，Key 在 `~/.zshenv` 的 `DEEPSEEK_API_KEY`）：

- 复现原场景：AIcove酱 收到「https://github.com/0xSynt4x/MyRaidRealmWEB/ 我想玩这个」，按默认设置（不审批），期望：不出现参数缺失错误；把 Release 的 `index.html` 或仓库产物下到工作区；最后给出一段完整中文答复（说明下好了、在哪、怎么玩，或明确说明还差「空间网页运行」才能在应用里直接打开）。记录总轮数和工具调用次数。
- 一个需要 10 步以上的任务一次做完（验证没有轮数上限）。
- 和改动前对比：同一场景的工具调用失败次数。

无法实测的项（手机端、Windows）在汇报里标为未验收。


## 9. 实施结果与偏差（2026-10-22）

- 后端按第 7 节逐步独立提交；每步静态检查无 error，相关测试通过。完整命令、计数、提交与契约位置见交付报告 `codex-backend-report.md`；本地证据在 `scratch/codemode-backend/`。
- 原九项审计探针已由 `agent_execution_audit_test.dart`、`chat_run_status_persistence_test.dart`、内核 `transcript_test.dart` 覆盖；内核与应用层各完成 32 次工具调用，均无轮数预算。
- 状态和 codemodeCalls 按最终任务书 A／B 字段落库并经数据库重载回归。前端由 Claude 负责，本后端提交不含 UI 或公共组件文档修改。
- DeepSeek Flash 三项：原下载场景 10 轮／9 次直接调用，0 次工具失败，保存 v1.0.1 的 `MyRaidRealm/index.html`（2,023,102 字节）；顺序读 12 份依赖文件用 13 轮／12 次调用完成，0 失败；同场景对比复跑 22 轮／21 次调用，0 失败，对照现场 trace 的 2 次失败。三个测试均通过。
- 对比复跑的模型把接口结果误读成「没有 Release」，因此拿到的是源码包并生成构建说明，不作为“已取得可运行成品”的证据；下载成品的证据只取第一项。失败计数对比使用方案第 1 节已有的改动前现场记录，没有重跑历史版本。
- 真实模型验收使用临时 `aicove` 空间和当前已支持的 allowAll 闸门，不安装开发依赖、不启动服务、不打开浏览器。该次验收只验证无需审批路径；本次合入 main 后生产策略已按 ADR0107 改为默认免审批，手动模式逐次确认。
- 验收发现并补回归：workspace_list 只删 properties 却残留 required.workspace；fetch 响应头缺 headers.get；助手对“想玩网页项目”只给链接、不保存成品。已分别修复 schema、Fetch 响应适配和下载指引。
- 脚本外层保留 external 效果以覆盖内置 fetch／ws 字节操作，嵌套工具再独立走同一闸门；外层拒绝也规范化成 Script failed／空 codemodeCalls。旧注入 executor 未提供 transcript 时继续使用旧 checkpoint 格式，生产内核使用完整执行记录。
- 保留已发布扩展宿主的资源及 tools.list／describe 契约；新 codemode 不提供旧目录接口。扩展安装工具的来源选择键为 workspaceId，文件工具仍完全由 cwd 决定。
- 初次浅克隆到 Pi be14d97 后，另取固定 476a303 的 declarations／source／tool／execute／agent-loop 五份文件；五份内容相同。MIT 许可随代码保留。
- 原后端验收未覆盖手机实机、Windows、生产默认审批设置、空间网页运行和第三方游戏界面。本次合入 main 后，空间网页运行已按 ADR0105 实现并有 Mac 浏览器实测；审批策略有离线回归，应用内未验；手机与 Windows 仍未验。
