// 追踪日志使用示例
// 
// 这个文件展示了如何在实际代码中使用新的追踪日志功能
// 可以直接复制这些模式到你的代码中

import 'package:mygril_flutter/src/core/app_logger.dart';

/// 示例 1: 简单的追踪
/// 适用场景：单个操作，需要记录开始、过程、结束和耗时
class SimpleTraceExample {
  Future<void> loadMessages() async {
    final trace = AppLogger.startTrace('加载消息列表', source: 'ChatPage');
    
    try {
      trace.info('开始从数据库读取');
      
      // 模拟数据库操作
      await Future.delayed(const Duration(milliseconds: 200));
      
      trace.info('成功读取到 50 条消息');
      trace.end(additionalMessage: '加载完成');
      
    } catch (e) {
      trace.error('加载失败: $e');
      trace.end(additionalMessage: '失败');
      rethrow;
    }
  }
}

/// 示例 2: 嵌套追踪
/// 适用场景：复杂的多步骤操作，需要看清楚每一步的耗时
class NestedTraceExample {
  Future<Map<String, dynamic>> sendMessageWithTools(String message) async {
    final trace = AppLogger.startTrace('发送AI消息', source: 'ChatService');
    
    try {
      trace.info('准备消息数据');
      
      // 第一步：调用 API
      final apiTrace = trace.startChild('调用AI API');
      apiTrace.info('发送请求到服务器');
      
      // 模拟 API 调用
      await Future.delayed(const Duration(milliseconds: 500));
      const response = {
        'text': 'Hello!',
        'tools': [
          {'name': 'tts', 'payload': {'audio_url': 'https://example.com/audio.mp3'}}
        ]
      };
      
      apiTrace.end(additionalMessage: 'API响应成功');
      
      // 第二步：处理工具调用
      final toolsTrace = trace.startChild('处理工具调用');
      final tools = response['tools'] as List;
      toolsTrace.info('检测到 ${tools.length} 个工具调用');
      
      for (final tool in tools) {
        final toolName = tool['name'] as String;
        
        // 为每个工具创建子追踪
        final toolTrace = toolsTrace.startChild('执行工具: $toolName');
        toolTrace.info('工具参数: ${tool['payload']}');
        
        if (toolName == 'tts') {
          // 模拟 TTS 处理
          await Future.delayed(const Duration(milliseconds: 300));
          toolTrace.info('语音文件已生成');
        }
        
        toolTrace.end();
      }
      
      toolsTrace.end();
      
      // 第三步：保存到数据库
      final dbTrace = trace.startChild('保存消息');
      dbTrace.info('写入数据库');
      await Future.delayed(const Duration(milliseconds: 100));
      dbTrace.end(additionalMessage: '保存成功');
      
      trace.end(additionalMessage: '所有步骤完成');
      return response;
      
    } catch (e, stackTrace) {
      trace.error('发送消息失败: $e', metadata: {
        'stackTrace': stackTrace.toString(),
      });
      trace.end(additionalMessage: '失败');
      rethrow;
    }
  }
}

/// 示例 3: 带元数据的追踪
/// 适用场景：需要记录详细的上下文信息
class MetadataTraceExample {
  Future<void> processImage(String imagePath) async {
    final trace = AppLogger.startTrace('处理图片', source: 'ImageService');
    
    try {
      // 记录初始信息
      trace.info('读取图片文件', metadata: {
        'path': imagePath,
        'timestamp': DateTime.now().toIso8601String(),
      });
      
      // 模拟读取文件
      await Future.delayed(const Duration(milliseconds: 100));
      const originalSize = 5242880; // 5MB
      
      trace.info('图片信息', metadata: {
        'originalSize': '${(originalSize / 1024 / 1024).toStringAsFixed(2)}MB',
        'format': 'PNG',
        'dimensions': '1920x1080',
      });
      
      // 压缩处理
      final compressTrace = trace.startChild('压缩图片');
      compressTrace.info('开始压缩', metadata: {
        'quality': '85%',
        'method': 'JPEG',
      });
      
      await Future.delayed(const Duration(milliseconds: 800));
      const newSize = 872448; // 850KB
      
      compressTrace.end(additionalMessage: '压缩完成');
      
      trace.info('处理结果', metadata: {
        'newSize': '${(newSize / 1024).toStringAsFixed(0)}KB',
        'compressionRatio': '${((1 - newSize / originalSize) * 100).toStringAsFixed(1)}%',
      });
      
      trace.end();
      
    } catch (e) {
      trace.error('处理失败', metadata: {'error': e.toString()});
      trace.end(additionalMessage: '失败');
      rethrow;
    }
  }
}

/// 示例 4: 多个并发操作的追踪
/// 适用场景：需要同时追踪多个独立的操作
class ConcurrentTraceExample {
  Future<void> syncMultipleResources() async {
    final mainTrace = AppLogger.startTrace('同步所有资源', source: 'SyncService');
    
    try {
      mainTrace.info('开始并发同步');
      
      // 创建多个独立的追踪（它们会有不同的 traceId）
      final futures = [
        _syncMessages(),
        _syncSettings(),
        _syncContacts(),
      ];
      
      await Future.wait(futures);
      
      mainTrace.end(additionalMessage: '所有资源同步完成');
      
    } catch (e) {
      mainTrace.error('同步过程中出现错误: $e');
      mainTrace.end(additionalMessage: '部分失败');
    }
  }
  
  Future<void> _syncMessages() async {
    final trace = AppLogger.startTrace('同步消息', source: 'SyncService');
    trace.info('正在上传本地消息');
    await Future.delayed(const Duration(milliseconds: 300));
    trace.info('正在下载服务器消息');
    await Future.delayed(const Duration(milliseconds: 400));
    trace.end(additionalMessage: '消息同步完成');
  }
  
  Future<void> _syncSettings() async {
    final trace = AppLogger.startTrace('同步设置', source: 'SyncService');
    trace.info('正在同步用户设置');
    await Future.delayed(const Duration(milliseconds: 200));
    trace.end(additionalMessage: '设置同步完成');
  }
  
  Future<void> _syncContacts() async {
    final trace = AppLogger.startTrace('同步联系人', source: 'SyncService');
    trace.info('正在同步联系人列表');
    await Future.delayed(const Duration(milliseconds: 500));
    trace.end(additionalMessage: '联系人同步完成');
  }
}

/// 示例 5: 错误处理和异常追踪
/// 适用场景：需要详细记录错误发生的上下文
class ErrorTraceExample {
  Future<void> riskyOperation() async {
    final trace = AppLogger.startTrace('执行风险操作', source: 'RiskyService');
    
    try {
      trace.info('第一步：验证权限');
      await _checkPermission();
      
      trace.info('第二步：加载数据');
      final data = await _loadData();
      
      trace.info('第三步：处理数据', metadata: {
        'dataSize': data.length,
      });
      
      // 假设这里可能会抛出异常
      if (data.isEmpty) {
        throw Exception('数据为空');
      }
      
      await _processData(data);
      
      trace.end(additionalMessage: '操作成功');
      
    } on Exception catch (e, stackTrace) {
      // 详细记录异常信息
      trace.error('操作失败: ${e.toString()}', metadata: {
        'exceptionType': e.runtimeType.toString(),
        'stackTrace': stackTrace.toString().split('\n').take(5).join('\n'),
      });
      trace.end(additionalMessage: '异常终止');
      
      // 可以选择重新抛出或处理
      rethrow;
    } finally {
      // 无论成功失败，都会执行清理
      trace.info('清理临时资源');
    }
  }
  
  Future<void> _checkPermission() async {
    await Future.delayed(const Duration(milliseconds: 50));
  }
  
  Future<List<String>> _loadData() async {
    await Future.delayed(const Duration(milliseconds: 200));
    return ['data1', 'data2'];
  }
  
  Future<void> _processData(List<String> data) async {
    await Future.delayed(const Duration(milliseconds: 300));
  }
}

/// 示例 6: 性能监控
/// 适用场景：需要精确测量每个步骤的性能
class PerformanceTraceExample {
  Future<void> heavyComputation() async {
    final trace = AppLogger.startTrace('执行复杂计算', source: 'ComputeService');
    
    // 步骤1
    final step1 = trace.startChild('步骤1: 数据准备');
    await Future.delayed(const Duration(milliseconds: 150));
    step1.end(); // 会显示: ◀ 完成: 步骤1: 数据准备 (耗时: 150ms)
    
    // 步骤2
    final step2 = trace.startChild('步骤2: 计算处理');
    await Future.delayed(const Duration(milliseconds: 500));
    step2.end(); // 会显示: ◀ 完成: 步骤2: 计算处理 (耗时: 500ms)
    
    // 步骤3
    final step3 = trace.startChild('步骤3: 结果输出');
    await Future.delayed(const Duration(milliseconds: 80));
    step3.end(); // 会显示: ◀ 完成: 步骤3: 结果输出 (耗时: 80ms)
    
    trace.end(); // 会显示总耗时: ◀ 完成: 执行复杂计算 (耗时: 730ms)
  }
}

/// 使用建议：
/// 
/// 1. 在关键业务流程的入口处开始追踪
/// 2. 为每个重要的子步骤创建子追踪
/// 3. 使用有意义的追踪名称和来源标识
/// 4. 在操作完成后务必调用 end()
/// 5. 发生错误时记录详细的错误信息和上下文
/// 6. 使用 metadata 记录额外的诊断信息
/// 
/// 输出格式说明：
/// - ▶ 表示开始
/// - ◀ 表示完成
/// - 缩进表示层级关系
/// - [Trace:xxxxxxxx] 是追踪ID，同一个事件流共享相同ID
/// - (耗时: xxx) 自动计算并显示每个步骤的耗时
