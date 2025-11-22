# API架构重构说明文档

## 概述

本次重构完全重新设计了API调用架构，参考Cherry Studio的实现，引入了以下核心改进：

1. **Provider抽象层**：支持多个AI提供商（OpenAI、Gemini、豆包）的统一抽象
2. **Block架构**：完整的多模态支持（文本、图片、音频、代码、思考过程等）
3. **ApiService编排层**：统一的API调用入口，自动集成工具调用
4. **SOLID原则**：遵循单一职责、开闭、依赖倒置等设计原则

---

## 架构分层

```
┌──────────────────────────────────┐
│   UI层 (Pages/Widgets)           │
│   - MessageBubble (多模态渲染)    │
└───────────────┬──────────────────┘
                │
┌───────────────▼──────────────────┐
│   业务层 (ChatApi)                │
│   - 简化的接口，只传业务参数      │
└───────────────┬──────────────────┘
                │
┌───────────────▼──────────────────┐
│   编排层 (ApiService)             │
│   - 协调AI交互                    │
│   - 集成工具（TTS/搜索等）        │
│   - 统一错误处理                  │
└───────────────┬──────────────────┘
                │
┌───────────────▼──────────────────┐
│   Provider层 (AiProvider)        │
│   - OpenAiProvider                │
│   - GeminiProvider                │
│   - DoubaoProvider                │
└───────────────┬──────────────────┘
                │
┌───────────────▼──────────────────┐
│   HTTP层 (http package)          │
└──────────────────────────────────┘
```

---

## 核心概念

### 1. MessageBlock（多模态内容块）

每条消息由多个Block组成，支持不同类型的内容：

| Block类型 | 说明 | 用途 |
|----------|------|------|
| `TextBlock` | 文本内容 | AI的回复文字 |
| `ImageBlock` | 图片 | 用户上传/AI生成的图片 |
| `AudioBlock` | 音频 | TTS合成的语音 |
| `CodeBlock` | 代码 | 代码片段 |
| `ThinkingBlock` | 思考过程 | Claude/o1的推理过程 |
| `ToolBlock` | 工具调用 | 搜索结果等工具输出 |
| `ErrorBlock` | 错误信息 | API调用失败等 |

**示例：**
```dart
final message = Message.fromBlocks(
  id: 'msg_123',
  role: 'assistant',
  blocks: [
    TextBlock(messageId: 'msg_123', content: '好的，我来帮你...'),
    AudioBlock(messageId: 'msg_123', url: 'https://example.com/audio.mp3'),
    ImageBlock(messageId: 'msg_123', url: 'https://example.com/image.jpg'),
  ],
);
```

### 2. Provider抽象层

每个AI提供商都实现`AiProvider`接口：

```dart
abstract class AiProvider {
  String get providerId;  // 'openai', 'gemini', 'doubao'
  ProviderCapabilities get capabilities;  // 能力声明

  Future<ChatResponse> sendChat(ChatRequest request);
  Future<List<String>> listModels();
  Future<bool> testConnection();
}
```

**能力声明示例：**
```dart
ProviderCapabilities.openai
  - supportsVision: true        // 支持图片输入
  - supportsThinking: true       // o1系列支持思考
  - supportsImageGeneration: true  // DALL-E
  - maxContextLength: 128000
```

### 3. ApiService编排层

统一的API调用入口，前端只需调用它：

```dart
final apiService = ApiService.fromConfig(
  providerId: 'openai',
  config: ProviderConfig(
    apiKey: 'sk-...',
    defaultModel: 'gpt-4o-mini',
  ),
);

final response = await apiService.sendChat(
  request: request,
  enableTts: true,  // 自动合成语音
);
```

---

## 使用指南

### 基础使用

**1. 创建ChatApi实例**

```dart
// 从环境变量创建（推荐）
final chatApi = ChatApi.fromEnv(
  providerId: 'openai',
  apiKey: 'sk-...',
  model: 'gpt-4o-mini',
);

// 或直接传入ApiService
final apiService = ApiService.fromConfig(...);
final chatApi = ChatApi(apiService);
```

**2. 发送聊天消息**

```dart
final message = await chatApi.sendChat(
  userId: 'user_123',
  sessionId: 'session_456',
  message: '你好',
  history: previousMessages,
  ttsEnabled: true,  // 启用TTS
  onChunk: (chunk) {
    // 流式响应回调
    print('Received: $chunk');
  },
);

// message.blocks 包含所有内容块
for (final block in message.blocks!) {
  if (block is TextBlock) {
    print('Text: ${block.content}');
  } else if (block is AudioBlock) {
    print('Audio: ${block.url}');
  }
}
```

**3. UI渲染（自动多模态）**

```dart
MessageBubble(
  isMe: false,
  message: message,  // 自动渲染所有blocks
  avatarUrl: 'https://...',
)
```

### 切换Provider

```dart
chatApi.switchProvider(
  providerId: 'gemini',
  apiKey: 'AIza...',
  model: 'gemini-2.0-flash-exp',
);
```

### 测试连接

```dart
final isConnected = await chatApi.testConnection();
```

### 获取模型列表

```dart
final models = await chatApi.listModels();
print('Available models: $models');
```

---

## 与前端设置系统集成

### ChatApiFactory：自动化配置

新架构提供了 `ChatApiFactory`，可以自动从 `AppSettings` 读取配置并创建 `ChatApi` 实例。

**核心优势：**
- ✅ 自动读取用户在设置页配置的Provider
- ✅ 自动管理API Key和模型选择
- ✅ 与Riverpod无缝集成
- ✅ 支持动态Provider切换

### 使用 ChatApiFactory

**方式1：直接使用工厂方法**

```dart
final chatApi = ChatApiFactory.fromSettings(
  settings,           // AppSettings实例
  'openai',          // Provider ID
);
```

**方式2：通过Riverpod Provider（推荐）**

```dart
class MyChatPage extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 自动获取当前配置的ChatApi
    final chatApi = ref.watch(chatApiProvider);
    
    if (chatApi == null) {
      return Text('请先在设置页配置Provider');
    }
    
    // 直接使用，无需传provider/apiKey参数
    final response = await chatApi.sendChat(
      userId: userId,
      sessionId: sessionId,
      message: userInput,
      history: messages,
      ttsEnabled: true,
    );
  }
}
```

### 可用的 Riverpod Providers

| Provider | 类型 | 说明 |
|---------|------|------|
| `chatApiProvider` | `Provider<ChatApi?>` | 当前配置的ChatApi实例，自动随设置更新 |
| `currentProviderIdProvider` | `StateProvider<String>` | 当前选中的Provider ID，可通过UI切换 |
| `availableProvidersProvider` | `Provider<List<ProviderAuth>>` | 所有可用的Provider列表 |

### Provider切换示例

```dart
// 在UI中切换Provider
DropdownButton<String>(
  value: ref.watch(currentProviderIdProvider),
  items: ref.watch(availableProvidersProvider).map((p) {
    return DropdownMenuItem(
      value: p.id,
      child: Text(p.displayName ?? p.id),
    );
  }).toList(),
  onChanged: (value) {
    if (value != null) {
      // 切换Provider，chatApiProvider会自动更新
      ref.read(currentProviderIdProvider.notifier).state = value;
    }
  },
);
```

### 完整集成流程

```
┌─────────────────────────────────────┐
│  1. 用户在设置页添加Provider        │
│     - model_list_page.dart          │
│     - upsertProviderAuth()          │
└────────────┬────────────────────────┘
             │
             ▼
┌─────────────────────────────────────┐
│  2. 前端同步到AppSettings           │
│     - app_settings.dart             │
│     - providers: List<ProviderAuth> │
└────────────┬────────────────────────┘
             │
             ▼
┌─────────────────────────────────────┐
│  3. AppSettings同步到后端           │
│     - UiModelsApi().updatePartial() │
│     - 存储到 data/ui_models.json    │
└────────────┬────────────────────────┘
             │
             ▼
┌─────────────────────────────────────┐
│  4. ChatApiFactory读取配置          │
│     - chatApiProvider监听设置变化   │
│     - 自动创建ApiService            │
└────────────┬────────────────────────┘
             │
             ▼
┌─────────────────────────────────────┐
│  5. 前端使用ChatApi发送消息         │
│     - 只传业务参数                  │
│     - 无需关心Provider/Key/Model    │
└────────────┬────────────────────────┘
             │
             ▼
┌─────────────────────────────────────┐
│  6. 多模态响应自动渲染              │
│     - MessageBubble自动处理blocks   │
│     - 显示文本/图片/音频/代码等     │
└─────────────────────────────────────┘
```

### 工具方法

**检查Provider可用性：**
```dart
final isAvailable = ChatApiFactory.isProviderAvailable(settings, 'openai');
```

**获取所有可用Provider：**
```dart
final providerIds = ChatApiFactory.getAvailableProviders(settings);
print('可用的Providers: $providerIds');  // ['openai', 'gemini', 'doubao']
```

### 完整示例

参考 `lib/src/features/chat/presentation/examples/chat_example.dart`，这是一个完整的聊天页面示例，展示了：
- 使用 `chatApiProvider` 获取ChatApi
- Provider切换下拉菜单
- 流式响应处理
- 多模态内容显示
- 错误处理

---

## 扩展新Provider

添加新的AI提供商非常简单：

**1. 创建Provider类**

```dart
class CustomProvider extends AiProvider {
  @override
  String get providerId => 'custom';

  @override
  ProviderCapabilities get capabilities => ProviderCapabilities(...);

  @override
  Future<ChatResponse> sendChat(ChatRequest request) async {
    // 实现API调用逻辑
  }

  // 实现其他方法...
}
```

**2. 注册Provider**

```dart
ProviderFactory.register('custom', (config) => CustomProvider(config: config));
```

**3. 使用**

```dart
final chatApi = ChatApi.fromEnv(
  providerId: 'custom',
  apiKey: '...',
);
```

---

## 迁移指南

### 从旧API迁移

**旧代码：**
```dart
final resp = await chatApi.sendChat(
  userId: userId,
  sessionId: sessionId,
  message: message,
  history: history,
  provider: 'openai',    // ❌ 底层参数
  model: 'gpt-4o-mini',   // ❌ 底层参数
  apiKey: apiKey,         // ❌ 底层参数
  apiBase: apiBase,       // ❌ 底层参数
);
print(resp.text);  // ❌ 只有文本
```

**新代码（方式1：使用 Riverpod，推荐）：**
```dart
// 1. 在页面中注入chatApiProvider（零配置）
class ChatPage extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chatApi = ref.watch(chatApiProvider);
    
    if (chatApi == null) {
      return Text('请先在设置页配置Provider');
    }
    
    // 2. 直接使用，完全无需provider/apiKey/model参数
    final message = await chatApi.sendChat(
      userId: userId,
      sessionId: sessionId,
      message: userInput,
      history: messages,
      ttsEnabled: true,  // ✅ 业务开关
    );
    
    // 3. 多模态访问
    print(message.displayText);     // 文本内容
    print(message.audios);          // 音频列表
    print(message.images);          // 图片列表
    print(message.hasMultiModal);   // 是否包含多模态
  }
}
```

**新代码（方式2：手动创建，适用于特殊场景）：**
```dart
// 1. 从AppSettings创建（推荐，自动读取用户配置）
final chatApi = ChatApiFactory.fromSettings(
  ref.read(appSettingsProvider).value!,
  'openai',  // Provider ID
);

// 或者手动创建（不推荐，需要手动管理配置）
final chatApi = ChatApi.fromEnv(
  providerId: 'openai',
  apiKey: apiKey,
  apiBase: apiBase,
  model: 'gpt-4o-mini',
);

// 2. 使用时只传业务参数
final message = await chatApi.sendChat(
  userId: userId,
  sessionId: sessionId,
  message: userInput,
  history: messages,
  ttsEnabled: true,  // ✅ 业务开关
);

// 3. 多模态访问
print(message.displayText);     // 文本内容
print(message.audios);          // 音频列表
print(message.images);          // 图片列表
print(message.hasMultiModal);   // 是否包含多模态
```

### 迁移步骤

**第1步：添加依赖注入（ConsumerWidget）**
```dart
// 旧代码
class ChatPage extends StatefulWidget { }

// 新代码
class ChatPage extends ConsumerStatefulWidget { }
class _ChatPageState extends ConsumerState<ChatPage> { }
```

**第2步：移除手动配置代码**
```dart
// 旧代码 - 删除这些
final apiKey = settings.apiKey;
final provider = settings.defaultProvider;
final model = settings.defaultModelName;

// 新代码 - 直接使用Provider
final chatApi = ref.watch(chatApiProvider);
```

**第3步：简化调用参数**
```dart
// 旧代码
await chatApi.sendChat(
  userId: userId,
  sessionId: sessionId,
  message: message,
  history: history,
  provider: provider,     // ❌ 删除
  model: model,           // ❌ 删除
  apiKey: apiKey,         // ❌ 删除
  apiBase: apiBase,       // ❌ 删除
);

// 新代码
await chatApi.sendChat(
  userId: userId,
  sessionId: sessionId,
  message: message,
  history: history,
  ttsEnabled: true,       // ✅ 新增业务开关
);
```

**第4步：更新UI渲染（支持多模态）**
```dart
// 旧代码
MessageBubble.text(
  isMe: false,
  text: response.text,  // ❌ 只支持文本
);

// 新代码
MessageBubble(
  isMe: false,
  message: message,     // ✅ 自动渲染所有blocks
);
```

---

## 设计原则应用

### SOLID原则

1. **单一职责 (S)**
   - `AiProvider`：只负责API调用
   - `ApiService`：只负责编排协调
   - `MessageBlock`：只负责数据表示

2. **开闭原则 (O)**
   - 添加新Provider无需修改现有代码
   - 添加新Block类型只需继承基类

3. **依赖倒置 (D)**
   - `ApiService`依赖`AiProvider`抽象，而非具体实现
   - 便于测试和替换

### DRY原则

- 消除了provider/apiKey/model等参数的重复传递
- 统一的错误处理逻辑
- 统一的工具集成（TTS等）

### KISS原则

- 前端调用极其简单，只关心业务逻辑
- 复杂性封装在Provider和ApiService中

---

## 文件结构

```
lib/src/
├── core/
│   ├── models/
│   │   ├── block_type.dart           # Block类型枚举
│   │   ├── block_status.dart         # Block状态枚举
│   │   ├── message_block.dart        # Block基类和各种Block
│   │   ├── api_error.dart            # 统一错误类型
│   │   ├── chat_request.dart         # 请求模型
│   │   └── chat_response.dart        # 响应模型
│   ├── api/
│   │   ├── providers/
│   │   │   ├── provider_capabilities.dart  # 能力声明
│   │   │   ├── ai_provider.dart            # Provider抽象基类
│   │   │   ├── openai_provider.dart        # OpenAI实现
│   │   │   ├── gemini_provider.dart        # Gemini实现
│   │   │   ├── doubao_provider.dart        # 豆包实现
│   │   │   └── provider_factory.dart       # Provider工厂
│   │   └── api_service.dart           # ApiService编排层
│   └── api_exports.dart               # 统一导出
└── features/
    └── chat/
        ├── domain/
        │   └── message.dart           # Message模型（支持blocks）
        ├── data/
        │   └── chat_api.dart          # 业务API封装
        └── presentation/
            └── widgets/
                └── message_bubble.dart  # 多模态UI渲染
```

---

## 常见问题

**Q: 旧代码会被破坏吗？**
A: 不会。Message保留了`content`字段向后兼容，MessageBubble也保留了`.text()`构造函数。

**Q: 如何禁用TTS？**
A: 调用时传入`ttsEnabled: false`即可。

**Q: 如何添加自定义Block类型？**
A: 继承`MessageBlock`并在`BlockType`枚举中添加新类型，在`message_bubble.dart`中添加渲染逻辑。

**Q: Provider之间如何共享配置？**
A: 使用`ApiService.switchProvider()`方法动态切换，配置独立管理。

**Q: chatApiProvider返回null怎么办？**
A: 说明没有配置可用的Provider。引导用户到设置页（`/settings/models`）添加Provider配置，或者显示提示信息。

**Q: 如何在不使用Riverpod的地方使用新API？**
A: 使用`ChatApiFactory.fromSettings(settings, providerId)`手动创建ChatApi实例。但推荐使用Riverpod以获得自动配置更新。

**Q: 切换Provider后需要重新发送消息吗？**
A: 不需要。通过`currentProviderIdProvider`切换后，`chatApiProvider`会自动更新为新的Provider配置，后续消息会自动使用新Provider。

**Q: 如何在设置页添加新的Provider？**
A: 在`model_list_page.dart`中调用`upsertProviderAuth()`方法，传入新的`ProviderAuth`对象。它会自动同步到AppSettings和后端。

**Q: 多模态Block的顺序重要吗？**
A: 重要。MessageBubble会按照blocks列表的顺序渲染。通常建议：文本 → 代码 → 图片 → 音频的顺序。

**Q: 如何处理流式响应？**
A: 使用`onChunk`回调接收流式内容，在回调中更新UI状态。参考`chat_example.dart`中的实现。

**Q: 如何测试特定Provider的连接？**
A: 使用`chatApi.testConnection()`方法，它会调用对应Provider的测试接口。

---

## 总结

本次重构实现了：
- ✅ 完整的多模态支持（9种Block类型）
- ✅ 清晰的架构分层（UI → ChatApi → ApiService → Provider）
- ✅ 易于扩展的Provider系统（OpenAI/Gemini/Doubao）
- ✅ 前端调用大幅简化（零配置使用）
- ✅ 与AppSettings无缝集成（ChatApiFactory）
- ✅ Riverpod状态管理（自动配置更新）
- ✅ 遵循SOLID设计原则（高内聚、低耦合）
- ✅ 向后兼容（保留旧API）

### 核心成果

**代码简化对比：**
```dart
// 旧代码：每次调用需要传递7个参数
await chatApi.sendChat(userId, sessionId, message, history, provider, model, apiKey);

// 新代码：只需3个业务参数，零配置
final chatApi = ref.watch(chatApiProvider);
await chatApi.sendChat(userId, sessionId, message);
```

**架构优势：**
1. **零配置使用**：通过Riverpod自动注入，无需手动创建
2. **自动同步**：设置页修改 → AppSettings → chatApiProvider自动更新
3. **多模态原生**：Text/Image/Audio/Code/Thinking 统一处理
4. **易于扩展**：新Provider只需实现AiProvider接口
5. **类型安全**：完整的类型定义和编译期检查

参考了Cherry Studio的优秀设计，使API架构更加健壮和可维护。
