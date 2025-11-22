# 日志输出示例

这个文档展示了使用增强的追踪日志系统后，实际运行时的日志输出效果。

## 示例场景

用户发送消息："读一下你好"，AI回复语音"你好"

## 实际日志输出

### 完整的日志流程（带 AgentApiClient 详细日志）

```
[14:30:45] [INFO] [ChatActions] [Trace:a7b3c9d2] ▶ 开始: AI消息发送
[14:30:45] [INFO] [ChatActions] [Trace:a7b3c9d2] 用户输入消息: "读一下你好"
[14:30:45] [INFO] [ChatActions] [Trace:a7b3c9d2]   ▶ 开始: 加载配置
[14:30:45] [INFO] [ChatActions] [Trace:a7b3c9d2]   配置加载完成
[14:30:45] [INFO] [ChatActions] [Trace:a7b3c9d2]   ◀ 完成: 加载配置 (耗时: 45ms)
[14:30:45] [INFO] [ChatActions] [Trace:a7b3c9d2]   ▶ 开始: 准备历史消息
[14:30:45] [INFO] [ChatActions] [Trace:a7b3c9d2]   历史消息准备完成
[14:30:45] [INFO] [ChatActions] [Trace:a7b3c9d2]   ◀ 完成: 准备历史消息 (耗时: 12ms)
[14:30:45] [INFO] [ChatActions] [Trace:a7b3c9d2]   ▶ 开始: 准备API调用
[14:30:45] [INFO] [ChatActions] [Trace:a7b3c9d2]   API参数准备
[14:30:45] [INFO] [ChatActions] [Trace:a7b3c9d2]   ◀ 完成: 准备API调用 (耗时: 8ms)
[14:30:45] [INFO] [ChatActions] [Trace:a7b3c9d2]   ▶ 开始: 调用AI API
[14:30:45] [INFO] [ChatActions] [Trace:a7b3c9d2]   连接到目标地址
[14:30:45] [INFO] [ChatActions] [Trace:a7b3c9d2]   发送消息
[14:30:45] [DEBUG] [AgentApiClient] [Trace:a7b3c9d2]     直连模式出现异常，回退到后端模式
[14:30:45] [INFO] [AgentApiClient] [Trace:a7b3c9d2]     ▶ 开始: 调用后端 /api/chat
[14:30:45] [INFO] [AgentApiClient] [Trace:a7b3c9d2]     连接到后端网关（支持工具调用）
[14:30:45] [INFO] [AgentApiClient] [Trace:a7b3c9d2]     发送请求到后端
[14:30:47] [INFO] [AgentApiClient] [Trace:a7b3c9d2]     后端响应成功
[14:30:47] [INFO] [AgentApiClient] [Trace:a7b3c9d2]     检测到工具调用结果
[14:30:47] [INFO] [AgentApiClient] [Trace:a7b3c9d2]     ◀ 完成: 调用后端 /api/chat (耗时: 1.92s) - 成功
[14:30:47] [INFO] [ChatActions] [Trace:a7b3c9d2]   收到原始回复
[14:30:47] [INFO] [ChatActions] [Trace:a7b3c9d2]   ◀ 完成: 调用AI API (耗时: 2.12s) - API调用成功
[14:30:47] [INFO] [ChatActions] [Trace:a7b3c9d2]   ▶ 开始: 运行插件
[14:30:47] [INFO] [ChatActions] [Trace:a7b3c9d2]   开始处理响应文本
[14:30:47] [INFO] [ChatActions] [Trace:a7b3c9d2]   插件处理完成
[14:30:47] [INFO] [ChatActions] [Trace:a7b3c9d2]     ▶ 开始: 执行TTS插件
[14:30:47] [INFO] [ChatActions] [Trace:a7b3c9d2]     检测到TTS事件
[14:30:48] [INFO] [ChatActions] [Trace:a7b3c9d2]     TTS事件已添加到播放队列
[14:30:48] [INFO] [ChatActions] [Trace:a7b3c9d2]     ◀ 完成: 执行TTS插件 (耗时: 1.23s) - TTS插件执行成功
[14:30:48] [INFO] [ChatActions] [Trace:a7b3c9d2]   ◀ 完成: 运行插件 (耗时: 1.34s)
[14:30:48] [INFO] [ChatActions] [Trace:a7b3c9d2]   ▶ 开始: 向用户转发消息
[14:30:48] [INFO] [ChatActions] [Trace:a7b3c9d2]   消息分段完成
[14:30:48] [INFO] [ChatActions] [Trace:a7b3c9d2]   消息已转发到用户
[14:30:48] [INFO] [ChatActions] [Trace:a7b3c9d2]   ◀ 完成: 向用户转发消息 (耗时: 150ms) - 转发成功
[14:30:48] [INFO] [ChatActions] [Trace:a7b3c9d2] ◀ 完成: AI消息发送 (耗时: 3.72s) - 所有步骤完成
```

## 日志格式说明

### 日志前缀格式
```
[时间戳] [日志级别] [代码块] [追踪ID] 内容
```

- **时间戳**: `[HH:MM:SS]` 格式，精确到秒
- **日志级别**: `[DEBUG]`, `[INFO]`, `[WARNING]`, `[ERROR]`, `[CRITICAL]`
- **代码块**: 事件发生的代码所属模块，如 `[ChatActions]`, `[AgentApiClient]`, `[TTS]`
- **追踪ID**: `[Trace:xxxxxxxx]` 8位唯一ID，同一事件流的所有日志共享相同ID
- **内容**: 日志消息本身

### 层级缩进

- **无缩进**: 顶层追踪
- **2空格缩进**: 一级子追踪
- **4空格缩进**: 二级子追踪
- **6空格缩进**: 三级子追踪

### 特殊符号

- `▶` : 开始某个操作
- `◀` : 完成某个操作（会自动显示耗时）

## 关键信息展示

### 1. 连接目标地址
```
[14:30:45] [INFO] [ChatActions] [Trace:a7b3c9d2]   连接到目标地址
```
**包含的元数据**:
- endpoint: 后端网关 或 具体的 API 地址
- modelFull: openai:gpt-4o-mini
- sessionId: conv_1234567890

### 2. 发送消息
```
[14:30:45] [INFO] [ChatActions] [Trace:a7b3c9d2]   发送消息
```
**包含的元数据**:
- userText: 用户输入的消息内容（超过100字会截断）
- historyCount: 历史消息数量
- temperature: 温度参数

### 3. 收到原始回复
```
[14:30:47] [INFO] [ChatActions] [Trace:a7b3c9d2]   收到原始回复
```
**包含的元数据**:
- text: AI返回的原始文本（超过200字会截断）
- textLength: 完整文本长度
- toolResultsCount: 工具调用结果数量

### 4. 运行插件
```
[14:30:47] [INFO] [ChatActions] [Trace:a7b3c9d2]   ▶ 开始: 运行插件
[14:30:47] [INFO] [ChatActions] [Trace:a7b3c9d2]   开始处理响应文本
[14:30:47] [INFO] [ChatActions] [Trace:a7b3c9d2]   插件处理完成
```
**包含的元数据**:
- originalLength: 原始文本长度
- processedLength: 处理后文本长度
- eventsCount: 插件事件数量

### 5. TTS插件执行情况
```
[14:30:47] [INFO] [ChatActions] [Trace:a7b3c9d2]     ▶ 开始: 执行TTS插件
[14:30:47] [INFO] [ChatActions] [Trace:a7b3c9d2]     检测到TTS事件
[14:30:48] [INFO] [ChatActions] [Trace:a7b3c9d2]     TTS事件已添加到播放队列
[14:30:48] [INFO] [ChatActions] [Trace:a7b3c9d2]     ◀ 完成: 执行TTS插件 (耗时: 1.23s) - TTS插件执行成功
```
**包含的元数据**:
- eventCount: TTS事件数量

### 6. 向用户转发最终消息
```
[14:30:48] [INFO] [ChatActions] [Trace:a7b3c9d2]   ▶ 开始: 向用户转发消息
[14:30:48] [INFO] [ChatActions] [Trace:a7b3c9d2]   消息分段完成
[14:30:48] [INFO] [ChatActions] [Trace:a7b3c9d2]   消息已转发到用户
[14:30:48] [INFO] [ChatActions] [Trace:a7b3c9d2]   ◀ 完成: 向用户转发消息 (耗时: 150ms) - 转发成功
```
**包含的元数据**:
- chunksCount: 消息分段数量
- firstChunk: 第一段消息内容（截断显示）
- messagesCount: 消息数量
- hasAudio: 是否包含音频消息

## 性能分析

从日志中可以清晰看出各个步骤的耗时：

| 步骤 | 耗时 | 占比 |
|------|------|------|
| 加载配置 | 45ms | 1.2% |
| 准备历史消息 | 12ms | 0.3% |
| 准备API调用 | 8ms | 0.2% |
| **调用AI API** | **2.12s** | **57.0%** ⚠️ |
| 运行插件 | 1.34s | 36.0% |
| - 执行TTS插件 | 1.23s | 33.1% |
| 向用户转发消息 | 150ms | 4.0% |
| **总耗时** | **3.72s** | **100%** |

从上表可以看出：
- ⚠️ **AI API调用**是最耗时的步骤（2.12s，占57%）
- **TTS插件执行**也占用了较多时间（1.23s，占33.1%）
- 其他步骤耗时都很短，总共不到300ms

## 错误情况日志示例

如果发送失败，日志会是这样：

```
[14:35:20] [INFO] [ChatActions] [Trace:b4e8f1a3] ▶ 开始: AI消息发送
[14:35:20] [INFO] [ChatActions] [Trace:b4e8f1a3] 用户输入消息: "测试消息"
[14:35:20] [INFO] [ChatActions] [Trace:b4e8f1a3]   ▶ 开始: 加载配置
[14:35:20] [INFO] [ChatActions] [Trace:b4e8f1a3]   配置加载完成
[14:35:20] [INFO] [ChatActions] [Trace:b4e8f1a3]   ◀ 完成: 加载配置 (耗时: 42ms)
[14:35:20] [INFO] [ChatActions] [Trace:b4e8f1a3]   ▶ 开始: 准备历史消息
[14:35:20] [INFO] [ChatActions] [Trace:b4e8f1a3]   历史消息准备完成
[14:35:20] [INFO] [ChatActions] [Trace:b4e8f1a3]   ◀ 完成: 准备历史消息 (耗时: 10ms)
[14:35:20] [INFO] [ChatActions] [Trace:b4e8f1a3]   ▶ 开始: 准备API调用
[14:35:20] [INFO] [ChatActions] [Trace:b4e8f1a3]   API参数准备
[14:35:20] [INFO] [ChatActions] [Trace:b4e8f1a3]   ◀ 完成: 准备API调用 (耗时: 6ms)
[14:35:20] [INFO] [ChatActions] [Trace:b4e8f1a3]   ▶ 开始: 调用AI API
[14:35:20] [INFO] [ChatActions] [Trace:b4e8f1a3]   连接到目标地址
[14:35:20] [INFO] [ChatActions] [Trace:b4e8f1a3]   发送消息
[14:35:25] [ERROR] [ChatActions] [Trace:b4e8f1a3] 消息发送失败  ⚠️
[14:35:25] [INFO] [ChatActions] [Trace:b4e8f1a3] ◀ 完成: AI消息发送 (耗时: 5.08s) - 发送失败
```

**错误日志的元数据包含**:
- convId: 会话ID
- error: 具体错误信息（如 "HTTP 500: Internal Server Error"）

## 如何使用日志排查问题

### 1. 通过追踪ID过滤

如果用户报告某次对话有问题，可以通过追踪ID（如 `a7b3c9d2`）过滤出该次对话的完整日志：

```dart
// 在日志查看器中搜索
[Trace:a7b3c9d2]
```

### 2. 定位性能瓶颈

查看每个步骤的耗时，找出最慢的部分：
- 如果 **API调用** 很慢 → 检查网络连接、后端服务状态
- 如果 **TTS插件** 很慢 → 检查TTS服务、音频生成性能
- 如果 **消息转发** 很慢 → 检查本地数据库性能

### 3. 追踪错误发生位置

通过层级缩进和 ▶/◀ 符号，可以精确知道错误发生在哪一步：
```
▶ 开始: AI消息发送
  ▶ 开始: 调用AI API
    连接到目标地址
    发送消息
    ❌ 错误发生在这里  <-- 可以看出是在API调用阶段
```

### 4. 对比正常和异常日志

将正常运行和异常运行的日志并排对比，快速发现差异点。

## 总结

新的追踪日志系统让你可以：
- ✅ **完整追踪整个事件流** - 从用户发送消息到AI回复的每一步
- ✅ **清晰的层级关系** - 通过缩进和符号看清楚调用层级
- ✅ **精确的性能数据** - 每一步的耗时一目了然
- ✅ **详细的上下文信息** - 通过元数据记录关键参数
- ✅ **快速定位问题** - 通过追踪ID关联相关日志
- ✅ **可读性强** - 符合人类阅读习惯的格式

现在你可以清楚地看到代码执行卡在哪一步了！🎉

## 🎯 实现的改进

### 1. ChatActions 层级日志
- ✅ 用户输入消息
- ✅ 配置加载
- ✅ 历史消息准备
- ✅ API调用准备
- ✅ 插件处理
- ✅ TTS插件执行
- ✅ 消息转发

### 2. AgentApiClient 层级日志
- ✅ 直连模式尝试与回退
- ✅ 连接到后端网关
- ✅ 发送请求到后端
- ✅ 接收后端响应
- ✅ 检测工具调用结果
- ✅ 详细的错误信息

### 3. 日志格式特性
- ✅ 统一的追踪ID（TraceID）
- ✅ 清晰的层级缩进（最多4层）
- ✅ 自动计时和耗时显示
- ✅ 详细的元数据信息
- ✅ 开始/完成符号（▶/◀）

### 4. 实现的设计原则
- **DRY (不重复代码)**: 追踪日志器复用，避免重复的日志代码
- **SOLID (单一职责)**: 每个追踪器只负责自己的作用域
- **KISS (保持简单)**: API简洁易用，只需 `startTrace()` → `info()` → `end()`
- **向下兼容**: 保留了原有的 `AppLogger.info()` 等方法
