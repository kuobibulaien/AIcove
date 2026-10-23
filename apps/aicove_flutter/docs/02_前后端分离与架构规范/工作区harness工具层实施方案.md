# 工作区 harness 工具层实施方案

> 状态：2026-10-21 第二版（并入 Codex 第一轮审查）。决策见 [ADR0098](../../../../docs/项目记忆/决策记录/0098-工作区按Pi对齐为完整harness工具层.md)。分支 `feat/workspace-harness`。
> **2026-10-22**：H1～H3 已实现，10-22 合入 main（b825f3e0c），离线全量与 DeepSeek 真实读图通过，手机实机未验。

> **2026-10-22 后续修订**：旧 workspace_run_js／workspace_shell 的名称、参数、期限和脚本审批限制由 [ADR0108](../../../../docs/项目记忆/决策记录/0108-Agent执行层与工具层按Pi收敛.md) 与《code-mode照抄Pi实施方案》取代。下文保留 H1～H3 实施时的历史描述；当前入口为 read／write／edit／bash／codemode，文件路径相对 cwd。

缩写：`L/`＝`apps/aicove_flutter/lib/src/`，`K/`＝`apps/aicove_flutter/packages/aicove_agent_kernel/`，`Q/`＝`apps/aicove_flutter/packages/aicove_quickjs/`。

## 1. 现状：能复用的部件与缺口

| 部件 | 位置 | 现状 |
|---|---|---|
| 工具定义 | `L/features/plugins/domain/handlers/ai_tool.dart` | `handler` 返回 `Future<String?>` |
| 工具包装 | `L/features/task_agent/application/task_agent_runner.dart:193–203` 等 | 重新构造 `AITool`，只转发旧 handler |
| 统一执行 | `L/features/chat/services/chat_send_api_runner_tool_support.dart:87–92` | 所有 handler 外面统一 `.timeout(toolTimeout)`（默认 30 秒，`settings_models.dart:540–550`），超时不取消原操作 |
| 内核工具结果 | `K/lib/src/types.dart` `KernelToolResult` | `content` 字符串＋透传的 `payload` |
| 前台执行与编码 | `L/features/chat/services/chat_send_api_runner_kernel.dart` | `executeOne`（约 919 行）包结果，`_outcomeOf` 凭文字相等恢复 payload；`encode`（约 1116 行）调适配器，非视觉模型 `_sanitizeMessagesForNonVisionModel`；`_buildStableDrawImageReviewMessages` 已在 tool 消息后补带图的 user 消息；预设 `presetRuntime.prepare`（约 460 行） |
| 旧执行器 | `L/features/chat/services/chat_send_api_runner.dart:671–710` | 直接执行 handler，不经内核闸门 |
| 适配器 | `L/core/api/providers/{claude,openai,gemini}_adapter.dart`、`provider_adapter.dart` `ToolResult` | 只放 `result` 字符串；Claude 适配器会合并相邻 user 消息（`claude_adapter.dart:75、110–135`） |
| 视觉判断 | `settings.hasChatModelCapability(...)` | 已有 |
| 杂活 Agent | `task_agent_providers.dart:54–75` → `background_agent_service.dart:44–45` → `api_runner.dart:55–56` | 走同一个内核执行器（Codex 已核实） |
| 上下文压缩 | `L/features/context/application/runtime_context_service.dart:40–49、177–199` | 以最后一个 `role=user` 为当前输入；工具组只含 assistant 调用＋随后的 tool 消息 |
| 持久化 | `chat_message_projection_codec.dart:84–90`、`chat_send_service.dart:462–468`、`task_agent_runner.dart:207–219` | 只存结果字符串 |
| 请求日志 | `L/core/api/agent_api_direct_chat_support.dart:135–137、171–176`、`agent_api_stream_support.dart:144–146、178–183` | 完整请求体进 trace 与 API 日志 |
| 预设运行时 | `L/features/agent_context/infrastructure/quickjs_preset_runtime.dart:85–103`、`Q/lib/aicove_quickjs.dart:31–35`、`Q/src/bridge.c:12、44` | 整份消息 JSON 进 QuickJS，8 MiB 输入上限 |
| 工作区工具 | `L/features/workspace/application/workspace_toolset.dart` | 文本解码、字符分页、JSON 结果、revision 必填、单处编辑；前台装配未传 `isCancelled`（`chat_send_backend_service.dart:1119–1129`） |
| 工作区存储 | `L/features/workspace/data/workspace_store.dart` | 条件提交（`write` 248–268、`_commit`/`_intent` 314–509）、按 run 撤销（719–859）、只检查最终路径类型（223–231、972–984） |
| MCP | `L/features/plugins/mcp/mcp_http_client.dart:26–31、98–135` | 结果压成文字，图片写成「未转给模型」，`structuredContent` 只在没文字时序列化 |
| QuickJS | `Q/src/bridge.c`、`Q/lib/aicove_quickjs.dart` | 同步求值、1 秒；`Q/src/quickjs/quickjs.h:914、926、976–977` 有 Promise／Job／中断 API |
| 公网检查 | `L/features/stickers/sticker_web_import.dart:85–104、239–251` | 只看字面值，不解析 DNS |
| 闸门 | `K/lib/src/tool_gate.dart:213–217`、`L/features/agent_plugins/tool_policy.dart`、AIcove酱 `chat_send_backend_service.dart:1098–1108`、`assistant_review.dart:212–239` | 无 approvals 时 `ask` 一律拒绝；AIcove酱的 approvals 是审核模型＋必要时问人，只有 major 必问人 |
| 表情库 | `L/features/stickers/sticker_library.dart` | 文件在 `stickers/files/` |

## 2. 数值

| 项 | 值 | 说明 |
|---|---|---|
| `workspace_read` 单次 | 2000 行或 50 KiB | 只返回完整的行 |
| grep 每行 | 500 字符 | |
| list／glob／grep 结果 | 200 条、64 KiB | 不变 |
| 单次写入文本／编辑后文件 | 1 MiB | 不变 |
| 单个文件 | 32 MiB | 不变 |
| 单张图片 | 长边 ≤ 1568 像素、编码后 ≤ 2 MiB | 先缩小再降 JPEG 质量；仍超过则只给文字说明 |
| 单个请求的图片 | ≤ 20 张、合计 ≤ 12 MiB | 超出从最早的换成占位 |
| `workspace_run_js` 期限 | 默认 30 秒，最长 120 秒 | 含等待宿主；工具自带期限，不受全局工具超时截断 |
| JS 堆 | 64 MiB | |
| 宿主并发调用 | 每个脚本 4 个 | 超出排队 |
| `ws.readBytes`／`writeBytes` | 单次 4 MiB | 分段 |
| `fetch` | 单次 30 秒、响应 8 MiB、最多 5 次重定向 | 公网 |
| 输出给模型 | 最后 2000 行或 50 KiB | 截断时全文落盘 `.aicove/outputs/<runId>-<序号>.txt`，最多 8 MiB，超过只留最后 8 MiB 并标注 |
| `workspace_shell` 期限 | 默认 120 秒，最长 600 秒 | |
| 超时后等待收敛 | 最多 5 秒 | 仍未收敛就强制关闭会话／杀进程树，并在结果里说明 |

所有上限都要有「上限前、等于上限、超过上限」三种测试。

## 3. 分批

按 H1 → H2 → H3 顺序，每批独立验收、独立提交。H1、H2、H3 都只是离线完成，第 4 节的集成验收在三批之后统一做。

### H1 富输出、文件工具、表情只读视图

**范围**
1. **富输出契约**：新增 `ToolOutput`（`text`、`images`（mimeType、bytes、来源说明）、`isError`、`structured`）。`AITool` 增加可选的富处理器和可选期限，旧 handler 零改动；所有包装 `AITool` 的地方透传。
2. **内核**：`KernelToolResult` 增加 `images`、`isError`；内核透传。`_outcomeOf` 以闸门／脱敏处理后的完整字段为准，不再凭文字相等恢复 payload；脱敏或闸门改写文字时丢弃图片。
3. **适配器与附图步骤**：`ToolResult` 增加 `images`；三家按 ADR0098 第 1 条编码；补发的 user 消息与 `_buildStableDrawImageReviewMessages` 共用同一个构造函数（绘图复核行为不变），并带运行期归属标记（发送前去掉）。
4. **压缩**：`runtime_context_service` 把带归属标记的附图消息并入工具组，不把它当作当前用户输入。
5. **非视觉模型**：执行时即知是否支持视觉；不支持时不附图片，文字加固定说明（第 5 节）。`_sanitizeMessagesForNonVisionModel` 继续兜底。
6. **三份投影**：在统一边界生成本次运行、持久记录、日志三种形态（ADR0098 第 1 条）。覆盖普通请求、流式请求、失败日志、聊天投影、ToolBlock、杂活过程记录。实时对象不原地删图。
7. **预算**：单请求图片张数与总字节预算，在实际发送前统一执行。
8. **预设通道**：进 `presetRuntime` 前图片换成引用标记，处理后换回；带两张 2 MiB 图片也不超 8 MiB。
9. **图片预处理**：纯 Dart，后台 isolate，用项目已有的 `image` 包。
10. **文件工具**：按 ADR0098 第 2 条改 `WorkspaceToolset`，结果改为纯文本；`workspace_edit` 返回 unified diff（最多 200 行）和首个改动行号；revision 可选（工具层读当前 revision 后条件提交，冲突报错不重试）；read 的超长单行和二进制说明里不提还不存在的工具。前台装配传入 `isCancelled`。
11. **store 路径规则**：任何一级祖先目录是符号链接即拒绝。
12. **MCP**：返回富输出（图片、`isError`、`structuredContent`）；音频仍只写说明。
13. **旧执行器**：只取文字投影，图片写成占位。
14. **表情只读视图**：`aicove` 空间下 `stickers/<套组 id>/<表情 id>.<扩展名>` 与生成的 `stickers/index.md`；做成按「空间 ID＋路径前缀」注册的只读挂载；读、列、glob 可见，grep 跳过二进制，写入／移动／删除返回固定说明（第 5 节）。
15. **提示词与资料**：`workspace_toolset.dart` 的提示词与工具说明按新语义改写；`assets/aicove_docs/sticker_packs.md` 把「做不到看图打标」改为「用 workspace_read 读 aicove 空间的 stickers/ 看图，再用 aicove_sticker_set_tags 打标签」。

**必须的测试**：多工具混合图文与错误；纯图片结果；脱敏丢图；图片第 20／21 张与总字节预算；同一次运行多轮仍见图、下一次运行重放为占位；日志里无 base64；预设通道大图；旧执行器；杂活 Agent 路径；压缩时附图不与工具拆散；三家编码快照；非视觉说明；文件工具（按行续读、截断说明、多处编辑唯一／重叠／CRLF／BOM、不带 revision 覆盖、并发抢写失败）；祖先符号链接；表情视图读与写拒绝。

**回滚**：富输出是增量字段，回退提交即可。

### H2 代码模式 `workspace_run_js`

**范围**
1. `aicove_quickjs` 新增异步会话（新类，`QuickJsSession` 行为不变）：Job 调度、宿主调用挂起／恢复、原生中断回调（期限＋取消标志，紧循环可停）、内存上限、关闭后丢弃晚到回复。
2. **调用级期限与取消**：工具自带期限，执行层不再用全局超时截断它；超时或取消时先中断 JS、取消未完成的宿主操作并等待收敛（最多 5 秒），再返回。每次宿主提交前检查调用仍有效。
3. 宿主桥：`tools.<name>`、`tools.list()`、`tools.describe()`（来自 `AITool` 的参数与 schema；撞名两个都不提供）、`fetch`、`ws.readBytes`／`ws.writeBytes`（分段，经 store、记在本次 run 下；表情视图拒绝写）、`console.*`、`text()`、`image()`。子调用走与直接调用相同的闸门、脱敏、取消；`ask` 判定直接失败并提示改为直接调用；排除 `workspace_run_js`、`workspace_shell`。
4. **公网网络入口**：新建宿主网络模块，解析 DNS、检查全部地址（含 IPv4 映射 IPv6）、用检查过的地址连接（TLS 仍按原主机名校验证书与 SNI），每跳重定向重复。表情导入改用它。
5. `workspace_run_js(workspace, code | path, args?, timeout_seconds?)`；输出按第 2 节截断与落盘；`image()` 走 H1 通道。
6. 闸门：`ToolEffect.external`；AIcove酱风险规则里归审核档，审核卡片文字见第 5 节。
7. `workspace_read` 的超长单行与二进制说明改为提示可用 `workspace_run_js` 处理。

**必须的测试**：`await fetch` 后写文件；紧循环被中断；等待 I/O 时超时；未 await 的写入在超时／取消后不落地；`Promise.all` 部分失败时其余写入的结果确定；异常后无晚到提交；`ask` 工具在脚本里失败；审核不能被脚本绕过；表情视图经字节接口不可写；域名解析到内网、混合地址、IPv4 映射 IPv6 被拒；脚本写入可撤销；输出截断与落盘；现有酒馆预设与 QuickJS 测试全部通过；安卓 `apk --debug`、macOS 构建通过（iOS、Windows 能做则做，做不了如实记录）。

**回滚**：新会话类、网络模块与新工具独立存在，删除注册即可。

### H3 桌面端命令行 `workspace_shell`

**范围**
1. 只在 macOS／Windows／Linux、内核执行器、且有**真人确认通道**的运行里装配。本轮只有 AIcove酱 满足；后台杂活 Agent、旧执行器、普通工具模式角色都不装配。
2. 闸门：每次调用都必须真人确认，审核模型不能放行（AIcove酱风险 major；实现上用一个「必须问人」的标记，不依赖风险规则的默认分档）。卡片文字见第 5 节。
3. 执行：工作区目录为 cwd；macOS／Linux `/bin/sh -c`，Windows `powershell -NoProfile -Command`；合并输出、截断与落盘；退出码、耗时；取消或超时杀进程树并等待退出。
4. **工作区协调**（需要扩展 store 的宿主接口，提交协议本身不变）：执行前写意图记录并锁住该工作区的其他写入；给 `.aicove/` 做快照；执行后还原 `.aicove/`，按「大小＋修改时间＋必要时哈希」扫描变化，登记进索引，标为「命令改动」；按 run 撤销时跳过这些条目并说明「命令造成的改动不能撤销」。启动恢复：有未完成的命令意图时重新扫描该工作区并还原 `.aicove/`。
5. 工具说明写明 macOS 沙盒限制。在真实应用进程里实测并记录：可用的 shell、PATH、`python3`／`node`／`git` 是否可用。

**必须的测试**：每条命令都确认；拒绝不执行；审核模型批准也不执行；超时杀子孙进程；非零退出标错；`.aicove/` 被改后还原；命令改动登记且撤销跳过；同大小同时间的修改也能被哈希兜住；执行期间其他写入被挡住；命令中途崩溃后的恢复；杂活 Agent 与普通角色没有这个工具。

**回滚**：删除工具注册即可；store 新增的宿主接口不影响原有路径。

## 4. 集成验收（三批之后）

1. 真实模型：Claude、OpenAI 格式、Gemini 各一次视觉读图；DeepSeek 真实回复里说看不了并建议换模型。本机目前只有 DeepSeek 的 Key，视觉模型没有 Key 时如实记录为未验。
2. AIcove酱 完整跑通：导入表情 → 读 `stickers/` 看图 → 打标签（视觉模型可用时）。
3. 全量 `tool/flutterw test` 与 `analyze`；请求组装 golden 的变化逐项核对。

## 5. 文案（照抄，不要改写）

用户可见：

| 位置 | 文案 |
|---|---|
| shell 确认卡片标题 | `运行命令` |
| shell 确认卡片说明 | `在空间「{空间名}」里执行：\n{命令}\n命令可能改动空间以外的文件，命令造成的改动无法撤销` |
| run_js 审核卡片标题 | `运行脚本` |
| run_js 审核卡片说明 | `在空间「{空间名}」里运行脚本，可能访问网络；空间内的改动可以撤销` |

给模型看：

| 场景 | 文字 |
|---|---|
| 模型不支持看图 | `当前模型不支持看图，看不到这张图片。回复用户时必须说明两点：你看不了这张图；请用户换一个支持图片的模型后再试。` |
| 只有图片的工具结果（OpenAI 格式 tool 消息） | `（图片见下一条消息）` |
| 补发图片的 user 消息开头 | `以下是工具返回的图片：` |
| 持久记录与超预算的图片 | `［图片已省略：{来源}］` |
| 表情视图写入 | `这里是表情库的只读视图，不能修改。改标签请用 aicove_sticker_set_tags。` |
| 撤销时跳过命令改动 | `命令造成的改动不能撤销：{路径}` |

## 6. 施工约束

- 只用 `apps/aicove_flutter/tool/flutterw`。改完跑相关测试与 `analyze`；请求组装 golden 用 `AICOVE_UPDATE_GOLDENS=1` 刷新，并检查 diff 只包含预期变化。分支基线上已有 5 个与本任务无关的失败（`chat_send_service_test.dart` 的「two role requests keep independent drawing snapshots across preset edits」和 4 个请求组装 golden：all_plugins_stable、bound_preset、image_failure_reminder、image_only，原因是绘图工具说明已改而测试未同步），可以顺手按当前输出修正。
- 风格跟随现有代码，不加不必要的抽象；修 bug 先写复现测试。
- 不写界面组件，不写第 5 节以外的用户可见文案（给模型看的工具说明、提示词可以写）。
- 不改 `WorkspaceStore` 的提交协议与已有索引表的列；需要新表或新宿主接口时在报告里说明。
- 每批完成后提交一次（提交信息英文，结尾加 `Co-Authored-By: Codex <noreply@openai.com>`），不推送、不切分支。报告列出改动文件、测试命令与结果、没覆盖到的地方。
