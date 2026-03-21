# API 架构说明

> 更新日期：2026-03-19
> 适用范围：`apps/mygril_flutter/lib/src/features/chat/`、`apps/mygril_flutter/lib/src/core/api/`

## 当前实现

### AgentApiClient 内部拆分（2026-03-19）

- `agent_api.dart` 现在只保留公共结果类型、`AgentApiClient` 门面和聊天/日志共用辅助方法，避免继续堆积“上帝类”
- 普通直连聊天链路迁入 `agent_api_direct_chat_support.dart`，把非流式请求、prompt 预览、trace/api log 落盘集中到单一职责文件
- 直连流式大块逻辑迁入 `agent_api_stream_support.dart`，把 SSE 事件解析、tool call 聚合、rawResponse 合成收敛到同一处
- 图片直连与 NovelAI 特判迁入 `agent_image_api_support.dart`，把图片链路从聊天链路中独立出来，便于后续继续细化

### 关键文件与功能

| 文件 | 功能 |
|------|------|
| `chat_actions.dart` | 聊天入口（门面），负责 UI 状态切换、流式占位与最终交付，不再直接编排主发送流程 |
| `application/chat_ports.dart` | 应用层端口定义：`ChatActions` 面向的发送/历史抽象接口 |
| `application/chat_send_use_case.dart` | 应用层发送用例：统一承接文本/图片/文件发送的设置加载、历史准备、模型故障切换与回复构建 |
| `chat_layer_providers.dart` | 分层组合入口：把 application 端口与现有 service/store 适配起来 |
| `infrastructure/chat_port_adapters.dart` | 基础设施适配器：桥接 `ChatSendService` / `ChatHistoryStore` 到 application 端口 |
| `services/chat_send_service.dart` | 发送门面（前台接口层）：保留创建消息、历史准备、回复构建等稳定接口，把重型发送细节委托出去 |
| `services/chat_send_backend_service.dart` | 后台发送执行服务：负责请求配置组装、插件上下文、工具 schema、trace 记录与 API 调用委托 |
| `services/chat_send_trace_payload_builder.dart` | trace payload 组装器：负责 runtimeContext / promptAssembly 等可观测 payload 拼装 |
| `services/chat_request_config.dart` | 请求配置构建器（MCP 缓存、直连模式回退、模型/Provider 解析） |
| `services/chat_request_message_builder.dart` | 请求消息构建器：历史消息转请求消息（图片/文件/非视觉回退） |
| `services/chat_plugin_context_builder.dart` | 插件上下文构建器：筛选插件、拼接插件 prompt、收集工具定义 |
| `services/chat_send_api_runner.dart` | API 执行器：模型请求 + 工具循环 + 流式回退 + 结果汇总 |
| `services/chat_types.dart` | 公共数据类型（`SendRequest`/`ApiCallResult`/`ApiConfig`/TTS 相关类型） |
| `services/chat_message_processor.dart` | 把文本/插件内容切成可展示的 `Message`（含图片/语音等 Block） |
| `services/chat_message_builder.dart` | 消息构建工具 |
| `services/chat_tts_handler.dart` | TTS 事件监听、占位语音消息、失败回退到文本 |
| `services/chat_tool_fallback_parser.dart` | 工具调用回退解析器（当模型不支持原生 tool call 时，从文本中提取工具调用） |
| `services/tts_fallback_notification.dart` | TTS 失败全局通知 |
| `core/api/agent_api.dart` | API 门面客户端：保留 `AgentApiClient` 对外入口，委托聊天/图片直连 support 实现 |
| `core/api/agent_api_direct_chat_support.dart` | 普通直连聊天 support：非流式请求、prompt 预览、trace/api log 落盘 |
| `core/api/agent_api_stream_support.dart` | 直连流式 support：SSE 解析、OpenAI/Gemini/Claude tool call 聚合、流式日志落盘 |
| `core/api/agent_image_api_support.dart` | 图片 support：图片生成、NovelAI 参数构建、二进制解包与图片请求日志 |
| `core/api/providers/provider_adapter.dart` | Provider 适配器抽象层（`ProviderAdapter` 接口 + `ToolCall`/`ToolResult` 类型） |
| `core/api/providers/provider_adapter_factory.dart` | 适配器工厂（根据 provider id 创建对应适配器） |
| `core/api/providers/openai_adapter.dart` | OpenAI 兼容 API 适配器 |
| `core/api/providers/claude_adapter.dart` | Claude API 适配器 |
| `core/api/providers/gemini_adapter.dart` | Gemini API 适配器 |
| `core/api/providers/provider_capabilities.dart` | 模型能力注册表（哪些模型支持 vision/tool 等） |
| `plugins/plugin_manager.dart` | 插件系统（生成 system prompt、处理回复得到事件/多媒体内容） |
| `core/models/message_block.dart` | 多模态 Block 定义（`TextBlock`/`ImageBlock`/`AudioBlock`/`FileBlock` 等） |
| `domain/message.dart` | 消息模型与 `toHistoryJson()`（用于拼请求历史） |
| `ui/features/debug/pages/call_flow_management_page.dart` | 调试页：配置模型/工具默认超时（生图路径切换已移到绘图设置） |

### 一次发送的完整流程

1. UI 调用 `ChatActions.send(...)`（或 `sendWithImage`）
   - `ChatActions` 现在通过 `ChatSendPort` / `ChatHistoryPort` 访问发送与历史能力，避免直接依赖具体 service/store
   - 文本流式发送、图片发送、文件发送，以及 `retry/regenerate` 这类重放链路，都会优先进入 `ChatSendUseCase`，由用例层承担公共编排
2. `ChatSendService.createUserMessage(...)` 创建用户消息（文本 / `ImageBlock` / `FileBlock`）
3. `ChatSendService.addUserMessage(...)` 把用户消息写入 `conversationsProvider`
4. `ChatSendUseCase` 加载 `AppSettings`、从数据库准备历史、决定模型故障切换顺序，并在流式场景下回调 `ChatActions` 建立占位气泡
5. `ChatSendService.prepareApiConfig(...)` 进入发送门面，再委托 `ChatSendBackendService.prepareApiConfig(...)` 组装请求配置：
   - `ChatRequestConfigBuilder.buildRequestConfig(...)` 解析模型/Provider/API Key
   - 拉取 MCP 配置（带缓存 TTL）并构建 `toolPrefs`
   - `ChatRequestMessageBuilder.buildRequestMessages(...)` 把历史消息转换成 API 所需 `messages`（支持图片/文件）
   - `ChatPluginContextBuilder` 负责筛选有效插件、拼接插件 prompt、收集工具定义
   - `ChatSendTracePayloadBuilder` 负责 runtimeContext / promptAssembly 的 trace payload 组装
   - 超出上下文限制时触发 memory 插件预刷新（保存即将丢弃的历史）
6. `ChatSendUseCase` 通过 `ChatSendPort.executeApiCall(...)` 发起请求并处理模型故障切换：
   - 当前基础设施实现由 `ChatSendBackendService` 组织参数，底层执行委托给 `ChatSendApiRunner.executeApiCall(...)`
   - 根据 `call_flow_settings` 决定生图路径：
     - `auto`：只有聊天模型同时具备 `vision + tools` 能力且未禁用工具调用时，才向模型暴露 `draw_image`，走“模型请求 -> 工具执行 -> 再请求模型”的稳定链路，并进入审图/返工闭环
     - `fast`：不向模型暴露 `draw_image`，改为注入 `<image>英文提示词</image>` 规则，让模型直接用标签触发生图；若仍有其他非生图工具，则继续按常规工具循环处理
   - 模型请求超时与工具超时都来自 `call_flow_settings`
   - `AgentApiClient.sendMessageRich(...)` 发起请求（通过 `ProviderAdapterFactory` 适配不同 provider）
   - 若模型不支持原生 tool call，`ChatToolFallbackParser` 从回复文本中提取工具调用
   - `pluginManager.processResponse(...)` 处理插件（产出 `pluginEvents/pluginContents`）
7. `ChatSendUseCase` 调用 `ChatSendPort.buildAssistantMessages(...)` 把回复转换成可展示消息列表（可能包含语音/表情等）
8. `ChatActions` + `ChatTtsHandler` 根据流式/非流式场景完成占位提交、TTS 分段交付与最终写入时间线
9. 异常时 `ChatSendPort.markUserMessageFailed(...)` 并更新 `errorProvider`

### 模型故障切换（Failover）

`ChatActions.send()` 内置模型故障切换机制：按 `defaultChatModels` 列表顺序尝试，某个模型请求失败时自动切换到下一个，直到成功或全部失败。

### retry 与流式一致性（2026-02-26）

`ChatActions.retry()` 现在和 `send()` 使用同一套流式参数透传（`enableStreaming`、`onStreamTextDelta` 等回调），避免“正常发送能流式显示、重试时行为不一致”。

### 发送重放链路分层（2026-03-19）

- `retry()` 与 `regenerate()/regenerateWithEnhancement()` 的公共发送编排已迁入 `application/chat_send_use_case.dart`
- `ChatActions` 仅保留各自特有的历史准备、状态回写和流式占位交付
- 增强重生成仍保留 `EnhancedDialogueService` 的上下文拼接与结果提取，但通过 `ChatPreparedTurn.transformApiResult` 挂接到同一套发送骨架

### 直连流式 Provider 支持（2026-03-05）

- `AgentApiClient.sendMessageRichStream(...)` 已支持 3 类直连流式：`openai`、`gemini`、`claude`。
- `gemini` 走 `:streamGenerateContent?alt=sse`，并解析 `candidates[].content.parts[].text/functionCall`。
- `claude` 走 `/v1/messages` + `stream=true`，并解析 `content_block_delta`（`text_delta` / `input_json_delta`）恢复工具调用参数。
- 仍保持原有回退机制：流式失败时 `ChatSendApiRunner` 自动切回非流式整段响应。

### 工具状态文案显示策略（2026-02-27）

- `ChatSendApiRunner` 在工具调用后会保留状态文案到日志（如 `Image generated and sent.` / `图片已生成并发送。`），用于排查。
- 这些“纯状态文案”不会再作为聊天正文返回给消息层，避免出现在用户聊天气泡中。
- 图片、音频等 `PluginContent` 仍按原流程正常展示与入库。

### Thinking 上下文续传策略（2026-02-28）

- 在 OpenAI 兼容流式工具调用链中，`AgentApiClient.sendMessageRichStream(...)` 会同时聚合：
  - `content`（用户可见回复文本）
  - `tool_calls`（工具调用）
  - `reasoning_content`（仅供模型续推理）
- 聚合后的 `reasoning_content` 会写回 `rawResponse.choices[0].message`，用于下一轮 tool-call 请求续传上下文，避免 DeepSeek Thinking 模式在第二轮报 `Missing reasoning_content`。
- `reasoning_content` 不进入聊天界面文案，不参与用户可见消息渲染。

### 关于后端与 AI 请求

- `cloud_backend/` 主要负责登录/同步/云数据能力；**不提供** `/api/chat` 这类 AI 对话端点
- AI 对话默认走"直连模型提供商"，所以需要在设置里配置对应 provider 的 API Key

## Provider 适配器层

`core/api/providers/` 目录实现了多 AI 提供商的统一接口：

```
core/api/providers/
├── provider_adapter.dart          # 抽象接口 + ToolCall/ToolResult 类型
├── provider_adapter_factory.dart  # 工厂：根据 provider id 创建适配器
├── openai_adapter.dart            # OpenAI 兼容格式（也用于第三方兼容 API）
├── claude_adapter.dart            # Anthropic Claude 格式
├── gemini_adapter.dart            # Google Gemini 格式
└── provider_capabilities.dart     # 模型能力注册表
```

每个适配器负责：
- 构建该 provider 的 API endpoint 和 headers
- 转换请求/响应格式（消息格式、工具调用格式各 provider 不同）
- 解析工具调用结果（`ToolCall`）

## 多模态消息块（MessageBlock）

每条消息由多个Block组成，支持不同类型的内容：

| Block类型 | 说明 | 用途 |
|----------|------|------|
| `TextBlock` | 文本内容 | AI的回复文字 |
| `ImageBlock` | 图片 | 用户上传/AI生成的图片 |
| `AudioBlock` | 音频 | TTS合成的语音 |
| `FileBlock` | 文件 | 用户上传的文件 |

示例：
```dart
final message = Message.fromBlocks(
  id: 'msg_123',
  role: 'assistant',
  blocks: [
    TextBlock(messageId: 'msg_123', content: '好的，我来帮你...'),
    AudioBlock(messageId: 'msg_123', url: '/static/tts/audio.mp3'),
  ],
);
```

## 插件系统

插件系统负责扩展 AI 的能力，包括：

- **TTS 插件**：文字转语音（支持阿里云/MiniMax/SiliconFlow 三个 provider）
- **Memory 插件**：记忆管理（embedding 向量召回）
- **Trigger 插件**：自动回复触发（主动关怀）
- **Sticker 插件**：表情包
- **Image 插件**：AI 绘图
- **Time Awareness 插件**：时间感知

插件通过 `PluginManager` 统一管理，在发送消息时：
1. 收集启用的插件及其工具定义
2. 生成 system prompt（各插件的提示词）
3. 处理 AI 回复（解析插件事件和内容）

## 架构设计原则

遵循以下设计原则：

- **KISS**：保持简单，避免过度设计
- **DRY**：不重复代码，提取公共逻辑
- **SOLID**：单一职责、开闭原则、依赖倒置
- **YAGNI**：只实现需要的功能

## 文件结构

```
lib/src/
├── core/
│   ├── api/
│   │   ├── agent_api.dart                    # API 门面客户端
│   │   ├── agent_api_direct_chat_support.dart # 普通直连聊天 support
│   │   ├── agent_api_stream_support.dart     # 直连流式 support（SSE / tool call 聚合）
│   │   ├── agent_image_api_support.dart      # 图片 support（含 NovelAI 特判）
│   │   └── providers/                        # Provider 适配器层
│   │       ├── provider_adapter.dart         # 抽象接口
│   │       ├── provider_adapter_factory.dart  # 适配器工厂
│   │       ├── openai_adapter.dart           # OpenAI 适配
│   │       ├── claude_adapter.dart           # Claude 适配
│   │       ├── gemini_adapter.dart           # Gemini 适配
│   │       └── provider_capabilities.dart    # 模型能力注册
│   ├── network/
│   │   └── json_http_client.dart             # JSON HTTP 客户端
│   ├── models/
│   │   └── message_block.dart                # 多模态 Block 定义
│   └── utils/
│       ├── content_normalizer.dart           # 内容规范化
│       ├── mime_utils.dart                   # MIME 类型检测
│       └── token_estimator.dart              # Token 计数估算
├── features/
│   ├── chat/
│   │   ├── chat_actions.dart                 # 聊天入口（门面 + failover）
│   │   ├── conversation_providers.dart       # 会话状态管理
│   │   ├── domain/
│   │   │   ├── message.dart                  # 消息模型
│   │   │   └── conversation.dart             # 会话模型
│   │   ├── data/
│   │   │   ├── session_manager.dart          # 会话生命周期管理
│   │   │   ├── chat_request_builder.dart     # 请求组装
│   │   │   ├── chat_response_handler.dart    # 响应处理
│   │   │   ├── context_analyzer.dart         # 对话上下文分析
│   │   │   └── analyzer_scheduler.dart       # AI 管家分析调度
│   │   └── services/
│   │       ├── chat_send_service.dart        # 发送门面（前台接口层）
│   │       ├── chat_send_backend_service.dart # 后台发送执行服务
│   │       ├── chat_send_trace_payload_builder.dart # trace payload 组装器
│   │       ├── chat_request_config.dart      # 请求配置构建器
│   │       ├── chat_request_message_builder.dart # 请求消息构建器
│   │       ├── chat_plugin_context_builder.dart # 插件上下文构建器
│   │       ├── chat_send_api_runner.dart     # API 执行器（工具循环/流式）
│   │       ├── chat_types.dart               # 公共类型定义
│   │       ├── chat_message_processor.dart   # 消息处理（多模态分段）
│   │       ├── chat_message_builder.dart     # 消息构建工具
│   │       ├── chat_tts_handler.dart         # TTS 处理
│   │       ├── chat_tool_fallback_parser.dart # 工具调用回退解析
│   │       └── tts_fallback_notification.dart # TTS 失败通知
│   └── plugins/
│       ├── plugin_manager.dart               # 插件管理器
│       ├── tts/                              # TTS 插件（含 3 个 provider）
│       ├── memory/                           # 记忆插件
│       ├── trigger/                          # 触发器插件
│       ├── sticker/                          # 表情包插件
│       ├── image/                            # 绘图插件
│       └── time_awareness/                   # 时间感知插件
```

## 常见问题

**Q: 如何添加新的消息类型？**
A: 在 `message_block.dart` 中定义新的 Block 类型，然后在 `MessageBubble` 中添加渲染逻辑。

**Q: 如何添加新的插件？**
A: 实现 `Plugin` 接口，然后在 `PluginManager` 中注册。

**Q: 如何切换 AI 提供商？**
A: 在设置页面配置不同的 Provider（OpenAI、Claude、Gemini 等）和对应的 API Key。`ProviderAdapterFactory` 会根据 provider id 自动选择对应的适配器。

**Q: 如何添加新的 AI 提供商？**
A: 在 `core/api/providers/` 下实现 `ProviderAdapter` 接口，然后在 `ProviderAdapterFactory` 中注册。
