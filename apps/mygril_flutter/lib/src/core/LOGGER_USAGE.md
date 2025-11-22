# 增强日志系统使用指南

## 概述

我们的日志系统现在支持**事件追踪**功能，可以清晰地看到整个事件流的执行过程、层级关系和耗时统计。

## 基础用法（原有功能保持不变）

如果你只需要记录简单的日志，可以继续使用原有的方式：

```dart
import 'package:mygril_flutter/src/core/app_logger.dart';

// 记录不同级别的日志
AppLogger.debug('ChatPage', '开始加载消息');
AppLogger.info('ChatPage', '成功加载了10条消息');
AppLogger.warning('TTS', 'TTS服务响应较慢');
AppLogger.error('API', '网络请求失败', metadata: {'code': 500});
AppLogger.critical('System', '应用即将崩溃');
```

## 追踪日志（新功能）⭐

### 基本追踪

当你需要追踪一个完整的事件流时（比如一次AI对话、一次文件上传），使用追踪日志：

```dart
// 开始一个追踪
final trace = AppLogger.startTrace('发送AI消息', source: 'ChatPage');

trace.info('准备发送消息到API');
trace.info('消息内容已序列化');

// 执行你的操作...
await sendMessageToApi();

// 结束追踪（自动计算并显示耗时）
trace.end();
```

**输出示例：**
```
[14:23:45] [INFO] [ChatPage] [Trace:a7b3c9d2] ▶ 开始: 发送AI消息
[14:23:45] [INFO] [ChatPage] [Trace:a7b3c9d2] 准备发送消息到API
[14:23:45] [INFO] [ChatPage] [Trace:a7b3c9d2] 消息内容已序列化
[14:23:47] [INFO] [ChatPage] [Trace:a7b3c9d2] ◀ 完成: 发送AI消息 (耗时: 2.34s)
```

### 嵌套追踪（层级显示）

对于复杂的操作，可以创建子追踪来显示层级关系：

```dart
final trace = AppLogger.startTrace('处理AI响应', source: 'ChatService');

trace.info('开始处理响应数据');

// 创建子追踪
final parseTrace = trace.startChild('解析JSON');
parseTrace.info('开始解析响应体');
// ... 执行解析操作
parseTrace.end();

// 创建另一个子追踪
final toolTrace = trace.startChild('处理工具调用');
toolTrace.info('检测到TTS工具调用');

// 甚至可以创建更深层的嵌套
final ttsTrace = toolTrace.startChild('执行TTS');
ttsTrace.info('正在生成语音');
// ... 执行TTS
ttsTrace.end();

toolTrace.end();
trace.end();
```

**输出示例：**
```
[14:30:12] [INFO] [ChatService] [Trace:b4e8f1a3] ▶ 开始: 处理AI响应
[14:30:12] [INFO] [ChatService] [Trace:b4e8f1a3] 开始处理响应数据
[14:30:12] [INFO] [ChatService] [Trace:b4e8f1a3]   ▶ 开始: 解析JSON
[14:30:12] [INFO] [ChatService] [Trace:b4e8f1a3]   开始解析响应体
[14:30:12] [INFO] [ChatService] [Trace:b4e8f1a3]   ◀ 完成: 解析JSON (耗时: 45ms)
[14:30:12] [INFO] [ChatService] [Trace:b4e8f1a3]   ▶ 开始: 处理工具调用
[14:30:12] [INFO] [ChatService] [Trace:b4e8f1a3]   检测到TTS工具调用
[14:30:12] [INFO] [ChatService] [Trace:b4e8f1a3]     ▶ 开始: 执行TTS
[14:30:13] [INFO] [ChatService] [Trace:b4e8f1a3]     正在生成语音
[14:30:14] [INFO] [ChatService] [Trace:b4e8f1a3]     ◀ 完成: 执行TTS (耗时: 1.82s)
[14:30:14] [INFO] [ChatService] [Trace:b4e8f1a3]   ◀ 完成: 处理工具调用 (耗时: 2.10s)
[14:30:14] [INFO] [ChatService] [Trace:b4e8f1a3] ◀ 完成: 处理AI响应 (耗时: 2.56s)
```

注意缩进！每一层都会自动缩进，非常清晰地显示调用关系。

### 完整示例：在 API 客户端中使用

```dart
class AgentApiClient {
  Future<SendMessageRichResult> sendMessage(String message) async {
    // 开始追踪整个发送消息流程
    final trace = AppLogger.startTrace('发送消息到AI', source: 'AgentApiClient');
    
    try {
      trace.info('准备请求数据');
      final requestBody = {'message': message};
      
      // 创建子追踪：HTTP请求
      final httpTrace = trace.startChild('HTTP POST请求');
      httpTrace.info('目标URL: ${_uri('/v1/chat')}');
      
      final response = await _postJson('/v1/chat', requestBody);
      httpTrace.end(additionalMessage: '响应状态: 200 OK');
      
      // 创建子追踪：解析响应
      final parseTrace = trace.startChild('解析响应数据');
      final result = SendMessageRichResult(
        text: response['text'] as String,
        toolResults: response['tools'] as List<Map<String, dynamic>>,
      );
      parseTrace.end(additionalMessage: '成功解析');
      
      // 如果有工具调用，追踪工具处理
      if (result.toolResults.isNotEmpty) {
        final toolTrace = trace.startChild('处理工具结果');
        toolTrace.info('检测到 ${result.toolResults.length} 个工具调用');
        
        for (final tool in result.toolResults) {
          final toolName = tool['name'] as String;
          toolTrace.info('工具: $toolName');
        }
        
        toolTrace.end();
      }
      
      trace.end(additionalMessage: '消息发送成功');
      return result;
      
    } catch (e, stackTrace) {
      trace.error('发送失败: $e', metadata: {'stackTrace': stackTrace.toString()});
      trace.end(additionalMessage: '失败');
      rethrow;
    }
  }
}
```

## 高级特性

### 1. 不同的日志级别

追踪器支持所有日志级别：

```dart
final trace = AppLogger.startTrace('数据同步', source: 'SyncService');

trace.debug('开始检查本地数据');
trace.info('正在上传数据');
trace.warning('检测到冲突，使用服务器版本');
trace.error('部分数据上传失败');

trace.end();
```

### 2. 附加元数据

```dart
final trace = AppLogger.startTrace('图片处理', source: 'ImageService');

trace.info('开始压缩图片', metadata: {
  'originalSize': '5.2MB',
  'format': 'PNG',
});

// ... 处理图片

trace.info('压缩完成', metadata: {
  'newSize': '850KB',
  'compressionRatio': '83.7%',
});

trace.end();
```

### 3. 结束时添加额外信息

```dart
final trace = AppLogger.startTrace('数据库查询', source: 'Database');

final results = await db.query('SELECT * FROM messages');

trace.end(additionalMessage: '查询到 ${results.length} 条记录');
// 输出: ◀ 完成: 数据库查询 (耗时: 120ms) - 查询到 42 条记录
```

## 最佳实践

### ✅ 推荐做法

1. **对重要的业务流程使用追踪**
   - AI 消息发送/接收
   - 数据同步
   - 文件上传/下载
   - 复杂的数据处理流程

2. **使用有意义的追踪名称**
   ```dart
   // ✅ 好的命名
   AppLogger.startTrace('发送语音消息', source: 'ChatService');
   AppLogger.startTrace('同步用户数据', source: 'SyncService');
   
   // ❌ 不好的命名
   AppLogger.startTrace('操作1', source: 'Service');
   AppLogger.startTrace('处理', source: 'Handler');
   ```

3. **合理使用嵌套层级**
   - 一般不超过 3-4 层
   - 每一层都应该有明确的职责

4. **始终调用 end()**
   - 使用 try-finally 确保追踪被正确结束
   ```dart
   final trace = AppLogger.startTrace('重要操作', source: 'Service');
   try {
     // ... 执行操作
   } finally {
     trace.end();
   }
   ```

### ❌ 避免做法

1. **不要滥用追踪**
   - 简单的单行日志不需要追踪，直接用 `AppLogger.info()` 即可
   
2. **不要在循环中创建追踪**
   ```dart
   // ❌ 不好
   for (final item in items) {
     final trace = AppLogger.startTrace('处理item', source: 'Service');
     // ...
     trace.end();
   }
   
   // ✅ 好
   final trace = AppLogger.startTrace('批量处理items', source: 'Service');
   for (final item in items) {
     trace.info('处理item: ${item.id}');
     // ...
   }
   trace.end();
   ```

## 追踪ID的作用

每个追踪都有一个唯一的 8 位追踪ID（如 `a7b3c9d2`），它的作用是：

1. **关联相关日志**：同一个追踪和它的所有子追踪共享同一个 traceId
2. **方便搜索**：在日志查看器中可以通过 traceId 过滤，只看某一次操作的完整日志
3. **问题排查**：用户报告问题时，可以提供 traceId，快速定位问题

## 耗时显示规则

- **小于 1 秒**：显示毫秒，如 `120ms`
- **1秒 到 1分钟**：显示秒（保留2位小数），如 `2.34s`
- **大于 1 分钟**：显示分钟和秒，如 `2m15s`

## 总结

新的追踪日志系统让你可以：
- ✅ **看清事件流**：从开始到结束的完整过程
- ✅ **定位性能问题**：每一步的耗时一目了然
- ✅ **理解调用层级**：通过缩进看清楚函数嵌套关系
- ✅ **关联相关日志**：通过 traceId 把一次操作的所有日志串起来
- ✅ **向下兼容**：原有的 `AppLogger.info()` 等方法依然可用

现在就开始用追踪日志，让你的代码运行过程清晰可见吧！🚀
