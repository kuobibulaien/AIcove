# API 架构说明

> 更新日期：2026-02-27
> 适用范围：`apps/mygril_flutter/lib/src/features/chat/`、`apps/mygril_flutter/lib/src/core/api/`

## 当前实现

### 关键文件与功能

| 文件 | 功能 |
|------|------|
| `chat_actions.dart` | 聊天入口（门面），UI 调用 `send / sendWithImage`，内含模型故障切换（failover） |
| `services/chat_send_service.dart` | 发送门面（编排层）：组织配置、调用、回复交付，不承载底层细节 |
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
| `core/api/agent_api.dart` | 网络请求客户端（`sendMessageRich` 走直连模型提供商） |
| `core/api/providers/provider_adapter.dart` | Provider 适配器抽象层（`ProviderAdapter` 接口 + `ToolCall`/`ToolResult` 类型） |
| `core/api/providers/provider_adapter_factory.dart` | 适配器工厂（根据 provider id 创建对应适配器） |
| `core/api/providers/openai_adapter.dart` | OpenAI 兼容 API 适配器 |
| `core/api/providers/claude_adapter.dart` | Claude API 适配器 |
| `core/api/providers/gemini_adapter.dart` | Gemini API 适配器 |
| `core/api/providers/provider_capabilities.dart` | 模型能力注册表（哪些模型支持 vision/tool 等） |
| `plugins/plugin_manager.dart` | 插件系统（生成 system prompt、处理回复得到事件/多媒体内容） |
| `core/models/message_block.dart` | 多模态 Block 定义（`TextBlock`/`ImageBlock`/`AudioBlock`/`FileBlock` 等） |
| `domain/message.dart` | 消息模型与 `toHistoryJson()`（用于拼请求历史） |
| `ui/features/debug/pages/call_flow_management_page.dart` | 调试页：切换稳定/快速模式，配置模型/工具默认超时 |

### 一次发送的完整流程

1. UI 调用 `ChatActions.send(...)`（或 `sendWithImage`）
2. `ChatSendService.createUserMessage(...)` 创建用户消息（文本 / `ImageBlock` / `FileBlock`）
3. `ChatSendService.addUserMessage(...)` 把用户消息写入 `conversationsProvider`
4. `ChatSendService.prepareHistory(...)` 根据 `historyMessageLimit` 截取历史
5. `ChatSendService.prepareApiConfig(...)` 组装请求配置：
   - `ChatRequestConfigBuilder.buildRequestConfig(...)` 解析模型/Provider/API Key
   - 拉取 MCP 配置（带缓存 TTL）并构建 `toolPrefs`
   - `ChatRequestMessageBuilder.buildRequestMessages(...)` 把历史消息转换成 API 所需 `messages`（支持图片/文件）
   - `ChatPluginContextBuilder` 负责筛选有效插件、拼接插件 prompt、收集工具定义
   - 超出上下文限制时触发 memory 插件预刷新（保存即将丢弃的历史）
6. `ChatSendService.executeApiCall(...)` 发起请求并处理插件：
   - `ChatSendService` 只负责组织参数，底层执行委托给 `ChatSendApiRunner.executeApiCall(...)`
   - 根据 `call_flow_settings` 决定流程模式：
     - `stable`：多轮循环（模型请求 -> 工具执行 -> 再次请求模型）
     - `fast`：仅首轮模型请求，工具并发执行，不再进入下一轮模型请求
   - 模型请求超时与工具超时都来自 `call_flow_settings`
   - `AgentApiClient.sendMessageRich(...)` 发起请求（通过 `ProviderAdapterFactory` 适配不同 provider）
   - 若模型不支持原生 tool call，`ChatToolFallbackParser` 从回复文本中提取工具调用
   - `pluginManager.processResponse(...)` 处理插件（产出 `pluginEvents/pluginContents`）
7. `ChatSendService.buildAssistantMessages(...)` 把回复转换成可展示消息列表（可能包含语音/表情等）
8. `ChatTtsHandler.prepareAssistantDelivery(...)`（启用 TTS 时）生成占位语音消息并等待 TTS 结果，失败则回退到文本
9. `ChatSendService.deliverAssistantMessages(...)` 写入会话、更新 lastMessage/时间戳
10. 异常时 `ChatSendService.markUserMessageFailed(...)` 并更新 `errorProvider`

### 模型故障切换（Failover）

`ChatActions.send()` 内置模型故障切换机制：按 `defaultChatModels` 列表顺序尝试，某个模型请求失败时自动切换到下一个，直到成功或全部失败。

### retry 与流式一致性（2026-02-26）

`ChatActions.retry()` 现在和 `send()` 使用同一套流式参数透传（`enableStreaming`、`onStreamTextDelta` 等回调），避免“正常发送能流式显示、重试时行为不一致”。

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
│   │   ├── agent_api.dart                    # API 客户端
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
│   │       ├── chat_send_service.dart        # 发送主流程
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
