# MCP 连接器

> 更新日期：2026-10-16（按当时代码重写。旧版写于 2026-07，描述的 `/mcp/config` 自定义 REST 接口与 `McpApi` 已删除）
> 决策：ADR0072（远程 HTTP、每个连接器一个插件、按角色显式开启）
> 代码：`lib/src/features/plugins/mcp/`；界面：`lib/src/ui/features/plugins/pages/mcp_connectors_page.dart`、`mcp_connector_detail_page.dart`

## 1. 做什么

用户自己接入远程 MCP 服务，把服务提供的工具交给聊天模型调用。AIcove 只实现标准 MCP 的工具能力（`initialize`、`tools/list`、`tools/call`），不做资源、提示词等其他能力。

## 2. 边界

- **传输**：只支持 Streamable HTTP，响应接受 `application/json` 和 `text/event-stream`。不做本地进程（stdio）和旧版 HTTP+SSE 传输，所以全平台都能用。
- **鉴权**：Bearer 令牌（`Authorization: Bearer <token>`）加可选的自定义请求头。不支持 OAuth 授权流程，需要 OAuth 的服务暂时接不了。
- **开启**：每个连接器是一个独立插件 `mcp:<连接器id>`，角色必须在「管理开启的插件」里逐个显式开启；「全部插件」不包含连接器。
- **只走 Function Calling**：模型不支持工具调用时连接器不生效。

## 3. 流程

```text
设置页添加连接器（地址＋令牌）
  → 测试连接／刷新：initialize ＋ tools/list，工具清单随配置保存
聊天请求
  → 角色开启了该连接器、连接器启用、地址有效且有工具清单 → 向模型提供工具（请求时不再联网列举）
  → 模型调用工具 → McpClientPool 复用会话发 tools/call → 结果压平成文本回给模型
```

- 会话 id 由服务端在 `initialize` 时下发；带会话 id 的请求返回 404（会话过期）时自动重新握手一次。
- 单次工具结果超过 20000 字符会截断，避免一次调用撑爆上下文。
- 服务端的 `inputSchema` 会收成各家模型都接受的顶层 object，并去掉部分供应商不认识的元信息字段。
- 用户可以在连接器里单独关掉某些工具。

## 4. 工具命名

模型看到的工具名是 `mcp__<连接器id>__<服务端工具名>`：连接器 id 只含小写字母和数字（1～16 位）；服务端工具名里的非法字符换成 `_`；总长超过 64 字符时截断并补一段哈希，保证不重名。`McpToolNaming.connectorIdOfTool` 可以从工具名反查连接器。

## 5. 存储与同步

连接器配置和其他插件配置一样存在 `aicove.plugins.mcp.connectors.v1`，随云同步和局域网同步走，所以角色在别的设备上也能找到绑定的连接器。令牌是配置的一部分，会随同步到用户自己的设备和自部署服务器。

## 6. 文件

| 文件 | 职责 |
|---|---|
| `mcp_connector.dart` | 连接器配置、工具信息、工具命名规则 |
| `mcp_http_client.dart` | Streamable HTTP 客户端、会话复用池 `McpClientPool`、错误类型 |
| `mcp_connector_plugin.dart` | 每个连接器对应的插件，工具 schema 整理与调用转发 |
| `mcp_connector_agent_plugin.dart` | 在内核 v2 上注册，只贡献工具，只对显式开启的角色生效 |
| `mcp_connector_providers.dart` | 连接器配置的状态管理与存储 |

## 7. 现状

第一批已实施：离线测试与公开 MCP 服务冒烟通过，真实模型对话与实机未验。
