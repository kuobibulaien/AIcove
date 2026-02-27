# 🔌 AstrBot 插件兼容性与通用性进化分析

## 1. 背景与目标

为了避免重复造轮子，并提升 AIcove 插件系统的通用性，我们需要分析 AstrBot（Python）插件系统的架构，评估将其生态引入 AIcove 的可行性，并从中汲取设计灵感来优化我们自己的系统。

**核心目标：**
1. **迁移指南**：制定规范，让开发者能轻松将 AstrBot 优秀插件（如语音、游戏等）迁移到 AIcove。
2. **通用性提升**：学习 AstrBot 的优秀设计，降低插件开发门槛，增强系统扩展性。

---

## 2. 深度架构对比

| 维度 | AstrBot (Python) | AIcove (Dart/Flutter) | 差异分析 |
|---|---|---|---|
| **运行机制** | **动态解释执行**<br>通过装饰器注册，运行时动态加载/卸载 | **编译时集成** (目前)<br>Dart 是 AOT 编译，动态加载受限（除非用 eval 或 WASM） | AstrBot 更灵活，AIcove 性能更好但动态性差 |
| **功能入口** | **装饰器 (Decorators)**<br>`@register`, `@filter.command`, `@llm_tool` | **接口实现 (Interfaces)**<br>继承 `BasePlugin`，重写 `getCommands`, `getTools` | 装饰器写法更声明式、更简洁；接口写法更严谨、类型安全 |
| **事件总线** | `StarHandler` 监听多种事件类型 | `LLMHook` (轻量级) | AstrBot 的事件系统更全面，覆盖了消息生命全周期 |
| **依赖管理** | `requirements.txt` / pip | `pubspec.yaml` | 生态不同，Python AI 库更丰富 |

---

## 3. 🧩 迁移策略：从 AstrBot 到 AIcove

由于语言和运行时的本质差异，**直接运行** AstrBot 插件（加载 `.py` 文件）在移动端是不切实际的（需要嵌入 Python 解释器，体积过大）。

我们采取 **"逻辑迁移，接口对齐"** 的策略。

### 3.1 接口映射表 (Mapping)

将 AstrBot 的概念映射到 AIcove，帮助开发者快速对应代码：

| AstrBot 概念 | AIcove 对应 | 迁移说明 |
|---|---|---|
| `@register` | `PluginMetadata` | 元数据定义，包含 id, name, config schema |
| `@filter.command("cmd")` | `getCommands()` 返回 `CommandHandler` | 将被装饰的函数逻辑移入 `handler` 回调 |
| `@llm_tool("name")` | `getTools()` 返回 `AITool` | 参数定义需要转为 `ToolParameter` 格式 |
| `event.session` | `context` (待增强) | 需要在 Handler 中提供上下文访问能力 |
| `StarTools.send_message` | `ChatService.sendMessage` (建议新增) | 需要给插件暴露主动发送消息的能力 |

### 3.2 迁移示例：语音插件 (TTS)

**AstrBot (Python):**
```python
@register("voice_plugin", "author", "desc", "1.0")
class VoicePlugin(Star):
    @filter.command("speak")
    async def speak(self, event, text: str):
        # 调用 TTS API
        audio = await tts_api.generate(text)
        yield event.voice_result(audio)
```

**AIcove (Dart):**
```dart
class VoicePlugin extends BasePlugin {
  @override
  PluginMetadata get metadata => PluginMetadata(
    id: 'voice_plugin',
    name: 'Voice Plugin',
    version: '1.0.0',
    // ...
  );

  @override
  List<CommandHandler> getCommands() => [
    CommandHandler(
      command: '/speak',
      description: 'Text to speech',
      handler: (args) async {
        final text = args.join(' ');
        // 调用 Dart 版 TTS 服务
        final audio = await ttsService.generate(text);
        // 返回结果（目前 AIcove 插件只能返回文本，建议增强支持多媒体）
        return '[语音发送成功]'; 
      },
    ),
  ];
}
```

---

## 4. 🚀 通用性进化建议

为了让 AIcove 的插件系统像 AstrBot 一样易用且强大，建议进行以下改进：

### 4.1 增强上下文访问能力 (Context Injection)
AstrBot 的 Handler 第一个参数不仅是 `self`，还有 `event`，其中包含了丰富的上下文（发送者、群组信息、平台信息）。

**建议：**
改造 `PluginManager`，在调用 Command 或 Hook 时，传入一个功能丰富的 `PluginContext` 对象，而不仅仅是参数列表。

```dart
// 改进前
Future<String> handler(List<String> args);

// 改进后
Future<void> handler(PluginContext context, List<String> args);

class PluginContext {
  final String conversationId;
  final User sender;
  final Function(String) sendText; // 允许插件主动发消息
  final Function(String) sendImage; 
  // ...
}
```

### 4.2 引入轻量级元编程体验
虽然 Dart 没有 Python 那样的装饰器，但我们可以通过 **注解 (Annotations) + 代码生成 (build_runner)** 来模拟这种开发体验，大幅减少样板代码。

**设想的未来用法：**
```dart
@AIcovePlugin(id: 'sticker', name: '表情包')
class StickerPlugin {
  
  @Command('/sticker', desc: '发送表情包')
  Future<void> sendSticker(PluginContext ctx, String tag) async {
    // 业务逻辑
  }

  @OnLLMResponse()
  Future<String> processText(String text) async {
    // 处理逻辑
  }
}
```
*注：这将作为长期目标，初期仍保持接口实现方式。*

### 4.3 增强多媒体支持
AstrBot 可以方便地 `yield event.image_result()` 或 `voice_result()`。
目前的 AIcove 插件系统主要处理 **文本**。我们需要扩展 `PluginProcessResult`，使其支持返回 **UI 组件** 或 **多媒体指令**。

### 4.4 探索脚本化支持 (Wasm / Lua / JS)
为了真正实现 "下载即用" 的插件（无需重新编译 App），长期来看可以引入嵌入式脚本引擎。
- **QuickJS/Lua**: 适合简单逻辑插件。
- **WebAssembly (Wasm)**: 许多语言都可以编译为 Wasm，是未来的主流方向。Dart 对 Wasm 支持正在完善。

---

## 5. 总结

AstrBot 的设计哲学是 **"高度动态、事件驱动、上下文丰富"**。
AIcove 的设计哲学目前的 **"类型安全、结构清晰、本地优先"**。

我们不需要完全变成 AstrBot，但应当：
1. **吸纳其 Metadata 和 Schema 设计**（已完成）。
2. **提供详细的迁移手册**，降低 AstrBot 开发者迁移门槛。
3. **增强插件的主动性**（不仅是响应，还能主动操作上下文）。

这将使 AIcove 成为一个既稳健又具备高度扩展性的 Agent 平台。
