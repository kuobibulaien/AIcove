# MCP 接入现状与标准兼容改造

## 1. 当前接入方式（实际）

### 1.1 聊天主链路

1. `ChatActions.send*()` 调用 `ChatSendService.prepareApiConfig()`
2. `prepareApiConfig()` 会调用 `McpApi.fetchConfig()` 拉取 `/mcp/config`
3. 把返回配置转换成 `tool_prefs`（`auto_tools_enabled` / `mcp_enabled_tools` / `mcp_delegate`）
4. 发送阶段走 `AgentApiClient.sendMessageRich()`，直接请求 OpenAI/Claude/Gemini 官方接口
5. 工具定义来自本地插件 `AITool`，通过模型 function calling 触发并在本地执行

### 1.2 关键事实

- 现在的 “MCP” 本质是自定义 REST 配置接口 + LLM function calling，不是标准 MCP 会话
- 现有代码里没有标准 MCP 的 `initialize` / `tools/list` / `tools/call` 会话流
- `cloud_backend` 仓库内没有 `/mcp/*` 实现，说明该接口当前不是由本仓库后端直接提供

## 2. 当前数据格式

### 2.1 现有配置接口（legacy）

`GET /mcp/config`

```json
{
  "config": {
    "enabled": true,
    "enabled_tools": ["tool.a", "tool.b"],
    "delegate": {
      "enabled": false,
      "provider": "openai",
      "model": "gpt-4o-mini",
      "api_base": "https://...",
      "prompt": "..."
    }
  },
  "tools": [
    {"id": "tool.a", "description": "...", "enabled": true}
  ]
}
```

### 2.2 聊天侧转发格式（内部）

`tool_prefs`：

```json
{
  "tts_enabled": true,
  "auto_tools_enabled": true,
  "mcp_enabled_tools": ["tool.a", "tool.b"],
  "mcp_delegate": {"provider": "...", "model": "...", "api_base": "...", "prompt": "..."}
}
```

### 2.3 工具调用格式（模型）

- 工程内统一为 OpenAI 风格 message/tool_call（再由 adapter 转 Claude/Gemini）
- 这部分是 function calling 适配，不是 MCP protocol

## 3. 与标准 MCP 的差异

1. 协议层
- 当前：REST（`/mcp/config` 等）
- 标准 MCP：JSON-RPC 2.0 会话（`initialize` -> `notifications/initialized` -> `tools/list|call`）

2. 传输层
- 当前：普通 HTTP
- 标准 MCP：stdio / SSE / WebSocket（取决于 host 与 server）

3. 能力模型
- 当前：仅工具配置与测试
- 标准 MCP：`capabilities`、`tools`、`resources`、`prompts`、`sampling` 等

4. 运行时边界
- 当前：工具在 App 本地插件执行
- 标准 MCP：通常由 MCP Server 执行，客户端只发起 `tools/call`

## 4. 移动端约束（必须考虑）

1. iOS/Android 不适合直接承载 stdio MCP Server 进程
2. 后台存活与长连接受系统策略限制（电量、网络切换、Doze）
3. 弱网下应减少握手与重试，避免每条消息都触发配置探测
4. 工具结果需限制大小，避免 UI 卡顿与高内存

推荐原则：

- 移动端只连接 MCP Gateway（HTTP/SSE/WebSocket），不直连本地 stdio server
- 配置和工具目录做缓存（含失败负缓存）
- 会话短平快，必要时延迟初始化（lazy init）

## 5. 建议改造路径

### P0（已完成，前端兼容层）

本次已在客户端落地：

1. `mcp_api.dart` 增加标准 MCP fallback
- 先尝试 legacy `/mcp/config`
- 失败后尝试 JSON-RPC `/mcp/rpc`（`initialize` + `tools/list`）
- 再失败尝试 `/mcp/tools`

2. `McpConfigResponseDto` 兼容解析
- 可解析 `result.tools`（标准 JSON-RPC 风格）
- `McpToolInfoDto` 支持 `name` 作为工具标识

3. 移动端缓存优化
- MCP 配置缓存统一改为 `McpApi.mobileConfigCacheTtl`（2 分钟）
- 增加失败负缓存，弱网下避免反复请求

### P1（需要后端/Gateway）

提供稳定标准入口（建议）：

- `POST /mcp/rpc`
  - 请求体：标准 JSON-RPC 2.0
  - 由 Gateway 负责会话管理、server 连接、鉴权与超时

最低支持：

1. `initialize`
2. `tools/list`
3. `tools/call`

### P2（聊天执行模型切换）

将 “工具执行” 从本地插件为主，演进为：

1. MCP 工具优先（`tools/call`）
2. 本地插件工具作为 fallback
3. 两者统一回填到现有 `tool_calls` 回合流程

### P3（收敛与下线）

- 稳定后逐步下线 legacy `/mcp/config` 私有字段
- 保留一段灰度期的兼容解析

## 6. 结论

当前系统的 “MCP” 是命名上的 MCP，不是协议层标准 MCP。  
建议采用 “前端兼容层 + 后端 MCP Gateway” 的双层方案：前端保持轻量和移动端友好，协议兼容责任集中在网关，能最小成本实现标准 MCP 对接并降低移动端风险。
