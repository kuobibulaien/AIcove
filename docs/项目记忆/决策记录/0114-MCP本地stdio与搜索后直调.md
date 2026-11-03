# 0114 MCP 本地 stdio 与搜索后直调

- 状态：accepted，2026-10-24 用户批准并明确四项收敛约束；实施与验收记录见 `scratch/mcp-stdio/`。
- 关联：0072、0108、0111。取代 0072 的“仅 HTTP”，修订 0108 中 MCP 仅脚本发现与调用的行为。

## 决定

1. `McpClientPort` 隔离 HTTP 与本地 stdio。旧配置无 `type` 时按 HTTP 读取；已有 HTTP 的入口、令牌、工具命名、角色授权与结果语义保持不变。
2. stdio 仅桌面端可用，使用 Dart `Process.start(runInShell: false)`，直接传程序、参数、工作目录、独立子进程环境，经异步 stdin/stdout/stderr 通信。不修改 `aicove_quickjs` 的 C 原生代码、不增加依赖。
3. GUI PATH 合并配置 PATH、父进程 PATH、常见包管理器路径与最新语义版本的 nvm Node bin；先用合并后的 PATH 解析程序，不执行 login shell 或改全局环境。详情页只要求一条启动命令，保存时解析引号、空参数和路径；不执行管道、重定向及变量／命令替换。Windows `.cmd/.bat` 拒绝并提示改用可执行程序，避免隐式 shell 改变参数含义；Windows 实机另验。
4. 共享连接器身份、类型、启停及工具开关继续用 `aicove.plugins.mcp.connectors.v1`；stdio 程序、参数、工作目录、环境变量和本机工具快照单独用 `aicove.local.mcp.stdio.v1`，不进入云／局域网同步。另一台设备未配启动信息时不提供工具。
5. 工具模式 MCP 统一 `deferred`，`tool_search` 搜索并激活匹配项，下一步模型请求直接声明；codemode 仍可调用全部当前授权工具。非工具模式不改变原有曝光方式。不增加“自动／始终直接／仅脚本”配置。
6. 已激活名称只在本次 `AgentLoop` 运行内存保存。跨轮从近期未压缩的原始历史 `ToolBlock`／其转换后的真实工具调用提取 `mcp__*` 名称，与当前可用且授权的目录求交集。摘要文字、搜索结果正文不参与恢复；不改消息结构、checkpoint 或压缩器。
7. 每轮重建工具声明，流式／非流式共用，并通过运行内存回调刷新原有预算列表；不改变压缩算法。`tool_search` 是直接模型工具，不向脚本暴露；脚本内 `searchTools` 仍仅返回说明。
8. 同一连接器复用进程；连接配置变化、停用、删除和应用退出时关闭。先关 stdin 等待，超时后只清理自身子进程与后代；不假定 Dart 子进程拥有独立 Unix 进程组。取消单次请求不杀共享进程；发出过的工具调用不自动重放，结果未知如实返回。

## 验证与边界

离线覆盖真实子进程协议、PATH、命令解析、同步隔离、并发／取消／错误回收、搜索后下一步声明、历史续用／撤权、流式及不同协议适配。界面提供窄／宽源码渲染预览。

DeepSeek 真实模型验收返回 HTTP 402 Insufficient Balance，未通过；Windows／Linux 实机与实际应用内点击验证分别记录，不能用离线测试替代。HTTP OAuth、旧 HTTP+SSE、resources/prompts 不在本次范围。不执行 git commit。
