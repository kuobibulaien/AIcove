# MCP 连接器

> 更新：2026-11-01；决策：ADR0072、ADR0114。
> 后端：`lib/src/features/plugins/mcp/`；界面：`lib/src/ui/features/plugins/pages/mcp_connectors_page.dart`、`mcp_connector_detail_page.dart`。

## 接入一个工具服务

在「MCP 连接器」中新增连接，选择连接方式：

- **HTTP**：填写 `http(s)` 地址；访问令牌和自定义请求头按服务要求填写。
- **本地命令**：桌面端粘贴完整启动命令，例如 `npx -y @modelcontextprotocol/server-filesystem "/path/to/home/My Documents"`。工作目录可选；环境变量每行 `KEY=VALUE`。

点「测试连接」，成功后显示工具列表。还需要在角色的「管理开启的插件」里显式开启这个连接器；「全部插件」不包含 MCP。工具列表里可以单独关闭不需要的工具。

启动命令会解析为程序和参数列表，以 Dart `Process.start(runInShell: false)` 执行，不经过 shell。支持引号、空参数及带空格的路径；管道、重定向、变量／命令替换不执行，需要填写实际值。GUI 启动时自动补充 Homebrew、`~/.local/bin`、`~/.cargo/bin`、最新 nvm Node 等常见 PATH，不安装运行时或工具包，不加载 login shell 配置。找不到程序时可填写完整可执行文件路径。

Windows 的 `.cmd/.bat` 启动脚本会被拒绝，避免 Dart 隐式 shell 执行改变参数含义；请改为实际 `.exe`，或 `node.exe CLI脚本路径 参数`。Windows 实机未验。

## 模型怎样调用

工具模式角色、AIcove酱，以及启用脚本的杂活 Agent：

```text
模型直接调用 tool_search 搜索能力
  → 匹配的 MCP 工具加载到本次运行内存
  → 下一步模型请求提供完整参数定义
  → 模型直接调用 MCP 工具
```

`tool_search` 默认返回最多 8 项，可传 `limit`（1～20）；只搜索当前可用且授权的延迟工具，不执行外部操作。无匹配则不加载。工具参数名、参数说明和连接器名称也参与匹配。

跨轮对话从近期未压缩历史的真实 MCP 工具调用恢复初始加载集合，再与当前工具目录求交集；不会解析摘要或搜索结果正文，也不会恢复已关闭的连接器。不新增加载状态存储、消息字段、checkpoint 或压缩逻辑。

`codemode` 中仍可用 `searchTools()`、`describeTool()`、`ALL_TOOLS` 和 `tools.mcp__...()` 调用。脚本搜索只返回声明，不改变模型工具清单；批量、串联和过滤大结果继续适合脚本。聊天模式角色不直接调用 MCP，交给后台杂活 Agent（派活）。模型不支持 Function Calling 时连接器不生效。

## 传输、错误与关闭

- HTTP 支持 Streamable HTTP，接受 JSON 或 SSE 响应；保留原有会话复用和会话过期重新握手行为。
- 本地 stdio 支持初始化、分页工具列表与工具调用，stdout 按 UTF-8 JSON 行解析，stderr 单独作为错误线索；并发请求按 ID 配对。
- 本地配置变化、停用、删除或应用退出会关闭连接。先关闭 stdin 等待退出，超时后清理自己的进程及后代；普通后台切换不关闭服务。
- 取消单次调用不会终止其他任务共用的 MCP 进程。已发出的本地工具调用不自动重放；未确认外部操作结果时返回“结果未知”。
- 直接和脚本调用均沿用参数校验、角色授权、确认、取消及结果保全。文本、图片、结构化结果沿用现有工具输出路径；不在 MCP 层提前截断完整结果。
- 不支持 OAuth、旧 HTTP+SSE、resources/prompts、sampling 等额外能力。

## 存储与同步

共享配置仍为 `aicove.plugins.mcp.connectors.v1`。旧配置缺少类型时按 HTTP 读取；已有 HTTP 地址、令牌、请求头和工具快照继续随云／局域网同步，含凭据的原有同步含义不变。

stdio 的连接器身份、名称、类型、启停及工具开关可同步；程序、参数、工作目录、环境变量、本机工具快照仅保存在 `aicove.local.mcp.stdio.v1`，不在云／局域网同步白名单内。另一台设备未配本机命令时不提供工具。手机端提示本地命令仅桌面可用。

工具名仍为 `mcp__<连接器id>__<服务端工具名>`，≤64 字符，沿用原有合法化和反查规则。

## 代码入口

| 文件 | 职责 |
|---|---|
| `mcp_connector.dart` | 连接器、共享／本机序列化、工具命名 |
| `mcp_client_port.dart` | HTTP／stdio 共用客户端契约及结果类型 |
| `mcp_http_client.dart` | 原 HTTP 客户端与连接池 |
| `mcp_stdio_client.dart` | Dart 子进程、JSON-RPC 分发、取消与关闭 |
| `mcp_stdio_launch.dart` | 整行命令解析、PATH 与程序定位 |
| `mcp_process_cleanup.dart` | 有界系统辅助进程、后代识别与 Windows 回收 |
| `mcp_connector_providers.dart` | 共享／本机配置合成、保存及连接测试 |
| `mcp_connector_plugin.dart` | 工具 schema 与执行转发 |
| `workspace/application/tool_search.dart` | 搜索工具声明、近期调用名提取 |
| `chat/services/chat_send_api_runner_kernel.dart` | 每次运行的加载集合与下一步动态声明 |

验收记录与源码渲染预览见仓库 `scratch/mcp-stdio/`。真实模型目前受 DeepSeek HTTP 402 余额不足阻塞，平台／应用内未验项以该记录为准。
