# API 架构说明

> 更新日期：2026-01-21
> 适用范围：`apps/aicove_flutter/lib/src/features/chat/`、`apps/aicove_flutter/lib/src/core/api/agent_api.dart`

## 当前实现

### 关键文件与功能

| 文件 | 功能 |
|------|------|
| `chat_actions.dart` | 聊天入口（门面），UI 调用 `send / sendWithImage / sendWithFile` |
| `services/chat_send_service.dart` | 发送主流程（准备配置 → 调用 API → 插件处理 → 构建消息 → 写入会话） |
| `core/api/agent_api.dart` | 网络请求客户端（`sendMessageRich` 默认走直连模型提供商的 `/v1/chat/completions`） |
| `plugins/plugin_manager.dart` | 插件系统（生成 system prompt、处理回复得到事件/多媒体内容） |
| `services/chat_message_processor.dart` | 把文本/插件内容切成可展示的 `Message`（含图片/语音等 Block） |
| `services/chat_tts_handler.dart` | TTS 事件监听、占位语音消息、失败回退到文本 |
| `core/models/message_block.dart` | 多模态 Block 定义（`TextBlock`/`ImageBlock`/`AudioBlock`/`FileBlock` 等） |
| `domain/message.dart` | 消息模型与 `toHistoryJson()`（用于拼请求历史） |

### 一次发送的完整流程

1. UI 调用 `ChatActions.send(...)`（或 `sendWithImage/sendWithFile`）
2. `ChatSendService.createUserMessage(...)` 创建用户消息（文本 / `ImageBlock` / `FileBlock`）
3. `ChatSendService.addUserMessage(...)` 把用户消息写入 `conversationsProvider`
4. `ChatSendService.prepareHistory(...)` 根据 `historyMessageLimit` 截取历史
5. `ChatSendService.prepareApiConfig(...)` 组装请求配置：
   - 读取 `AppSettings`（模型、provider、温度、API Key 等）
   - 拉取 MCP 配置（可选）并构建 `toolPrefs`
   - 拼 system prompt（persona + 称呼 + 插件 prompts）
   - 把历史消息转换成 API 所需的 `messages`（支持图片/文件等）
6. `ChatSendService.executeApiCall(...)` 发起请求并处理插件：
   - `AgentApiClient.sendMessageRich(...)` 发起请求（当前实现是直连 provider）
   - `pluginManager.processResponse(...)` 处理插件（产出 `pluginEvents/pluginContents`）
7. `ChatSendService.buildAssistantMessages(...)` 把回复转换成可展示消息列表（可能包含语音/表情等）
8. `ChatTtsHandler.prepareAssistantDelivery(...)`（启用 TTS 时）生成占位语音消息并等待 TTS 结果，失败则回退到文本
9. `ChatSendService.deliverAssistantMessages(...)` 写入会话、更新 lastMessage/时间戳
10. 异常时 `ChatSendService.markUserMessageFailed(...)` 并更新 `errorProvider`

### 关于后端与 AI 请求

- `cloud_backend/` 主要负责登录/同步/云数据能力；**不提供** `/api/chat` 这类 AI 对话端点
- AI 对话默认走"直连模型提供商"，所以需要在设置里配置对应 provider 的 API Key

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

- **TTS 插件**：文字转语音
- **Memory 插件**：记忆管理
- **Trigger 插件**：自动回复触发
- **Sticker 插件**：表情包

插件通过 `PluginManager` 统一管理，在发送消息时：
1. 生成 system prompt（各插件的提示词）
2. 处理 AI 回复（解析插件事件和内容）

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
│   │   └── agent_api.dart          # API 客户端
│   └── models/
│       └── message_block.dart      # 多模态 Block 定义
├── features/
│   ├── chat/
│   │   ├── chat_actions.dart       # 聊天入口
│   │   ├── domain/
│   │   │   ├── message.dart        # 消息模型
│   │   │   └── conversation.dart   # 会话模型
│   │   └── services/
│   │       ├── chat_send_service.dart        # 发送主流程
│   │       ├── chat_message_processor.dart   # 消息处理
│   │       └── chat_tts_handler.dart         # TTS 处理
│   └── plugins/
│       ├── plugin_manager.dart     # 插件管理器
│       ├── tts/                    # TTS 插件
│       ├── memory/                 # 记忆插件
│       ├── trigger/                # 触发器插件
│       └── sticker/                # 表情包插件
```

## 常见问题

**Q: 如何添加新的消息类型？**
A: 在 `message_block.dart` 中定义新的 Block 类型，然后在 `MessageBubble` 中添加渲染逻辑。

**Q: 如何添加新的插件？**
A: 实现 `Plugin` 接口，然后在 `PluginManager` 中注册。

**Q: 如何切换 AI 提供商？**
A: 在设置页面配置不同的 Provider（OpenAI、Gemini 等）和对应的 API Key。

**Q: 为什么没有实现 AiProvider 抽象层？**
A: 当前采用直连模型提供商的方式，通过 `AgentApiClient` 统一处理。如果未来需要支持更多提供商，可以考虑引入抽象层。
