# 控制台功能使用说明

## 概述

新的控制台系统提供了详细的事件时间线和 API 请求日志，帮助开发者和用户追踪应用内的各种事件。

## 功能特性

### 1. 事件日志
- **5 个日志级别**：DEBUG、INFO、WARNING、ERROR、CRITICAL
- **时间戳**：精确到秒的时间记录
- **来源标记**：清晰标识事件来源模块
- **级别过滤**：可按日志级别筛选显示
- **彩色显示**：不同级别使用不同颜色区分
- **元数据支持**：可附加额外的结构化数据

### 2. API 日志
- **HTTP 请求追踪**：记录所有 API 请求
- **请求/响应详情**：展开查看完整的请求和响应内容
- **性能监控**：显示请求耗时
- **状态码显示**：清晰标识请求成功或失败

### 3. 界面特性
- **双标签页**：事件日志和 API 日志分开显示
- **自动滚动**：新日志自动滚动到底部（可关闭）
- **导出功能**：一键导出日志为 JSON 格式
- **清空功能**：快速清空日志记录
- **二级界面**：独立页面，与模型列表、MCP 设置同级

## 使用方法

### 访问控制台
1. 打开应用设置页面
2. 在"模型设置"分组下找到"控制台"选项
3. 点击进入控制台页面

### 记录日志
在代码中使用 `AppLogger` 记录事件：

```dart
import 'package:mygril_flutter/src/core/app_logger.dart';

// DEBUG 级别
AppLogger.debug('ModuleName', '调试信息');

// INFO 级别
AppLogger.info('ModuleName', '一般信息');

// WARNING 级别
AppLogger.warning('ModuleName', '警告信息');

// ERROR 级别
AppLogger.error('ModuleName', '错误信息');

// CRITICAL 级别
AppLogger.critical('ModuleName', '严重错误');

// 附加元数据
AppLogger.info('TTS', '开始生成语音', metadata: {
  'text': '你好',
  'voice': 'voice1',
  'duration': 371,
});
```

### 日志过滤
1. 在控制台页面顶部，点击相应的级别标签
2. 选中的级别会显示，未选中的会被隐藏
3. 可同时选择多个级别

### 自动滚动
- 开启：新日志会自动滚动到视图底部
- 关闭：日志保持当前滚动位置

### 导出日志
1. 点击顶部的"下载"图标
2. 日志会以 JSON 格式复制到剪贴板
3. 可粘贴到文件中保存

## 日志级别说明

| 级别 | 颜色 | 用途 |
|------|------|------|
| DEBUG | 灰色 | 调试信息，详细的运行时信息 |
| INFO | 蓝色 | 一般信息，正常的业务流程 |
| WARNING | 橙色 | 警告信息，可能的问题 |
| ERROR | 红色 | 错误信息，需要关注的问题 |
| CRITICAL | 紫色 | 严重错误，可能导致应用崩溃 |

## 最佳实践

1. **合理使用日志级别**
   - DEBUG：仅在开发调试时使用
   - INFO：记录重要的业务流程
   - WARNING：记录可恢复的异常情况
   - ERROR：记录需要关注的错误
   - CRITICAL：记录严重的系统错误

2. **清晰的来源标记**
   - 使用有意义的模块名，如 'Core', 'TTS', 'API', 'UI' 等
   - 保持命名一致性

3. **结构化的元数据**
   - 使用元数据记录额外的上下文信息
   - 避免在消息中硬编码大量数据

4. **定期清理日志**
   - 日志最多保存 1000 条
   - 定期清空以提高性能

## 技术细节

### 日志存储
- 使用 `ValueNotifier` 实现响应式更新
- 最大存储 1000 条日志（超出自动删除旧记录）
- 内存存储，应用重启后清空

### API 日志集成
- 复用现有的 `ApiLogger` 系统
- 最多保存 200 条 API 请求记录
- 自动屏蔽敏感信息（API key 等）

## 示例场景

### 场景 1：追踪应用启动流程
```dart
AppLogger.info('App', '应用启动中...');
AppLogger.debug('App', '使用 Hash URL 策略 (Web 平台)');
AppLogger.info('App', '应用启动完成');
```

### 场景 2：监控 TTS 语音生成
```dart
AppLogger.info('TTS', '开始生成语音', metadata: {
  'text': text,
  'voice_id': voiceId,
});

// ... 生成过程 ...

AppLogger.info('TTS', '语音生成成功', metadata: {
  'file': outputFile,
  'duration_ms': duration,
});
```

### 场景 3：追踪错误
```dart
try {
  // 执行操作
} catch (e) {
  AppLogger.error('ModuleName', '操作失败: $e', metadata: {
    'error': e.toString(),
    'stack_trace': StackTrace.current.toString(),
  });
}
```

## 未来扩展

- [ ] 日志持久化存储
- [ ] 日志搜索功能
- [ ] 日志导出为文件
- [ ] 实时日志流式显示
- [ ] 日志统计分析
