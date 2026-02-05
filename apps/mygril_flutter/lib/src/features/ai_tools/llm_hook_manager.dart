import '../plugins/domain/index.dart';
import '../plugins/plugin_manager.dart';

/// LLM 钩子管理器
/// 负责在 LLM 请求/响应的关键时刻触发插件钩子
class LLMHookManager {
  final PluginManager pluginManager;

  LLMHookManager(this.pluginManager);

  /// 触发"请求前"钩子
  /// 允许插件修改请求内容
  Future<T> triggerBeforeRequest<T>(T requestContext) async {
    final hooks = pluginManager.getHooksByType(LLMHookType.beforeRequest);

    for (final hook in hooks) {
      try {
        await hook.handler(requestContext);
      } catch (e) {
        print('[LLMHookManager] beforeRequest hook failed: $e');
        // 单个钩子失败不影响其他钩子
      }
    }

    return requestContext;
  }

  /// 触发"响应后"钩子
  /// 允许插件查看响应内容（只读）
  Future<T> triggerAfterResponse<T>(T responseContext) async {
    final hooks = pluginManager.getHooksByType(LLMHookType.afterResponse);

    for (final hook in hooks) {
      try {
        await hook.handler(responseContext);
      } catch (e) {
        print('[LLMHookManager] afterResponse hook failed: $e');
        // 单个钩子失败不影响其他钩子
      }
    }

    return responseContext;
  }
}

/// LLM 请求上下文
/// 包含请求的所有信息，可被钩子修改
class LLMRequestContext {
  String systemPrompt;
  List<Map<String, dynamic>> messages;
  Map<String, dynamic> metadata;
  List<Map<String, dynamic>>? tools;

  LLMRequestContext({
    required this.systemPrompt,
    required this.messages,
    this.metadata = const {},
    this.tools,
  });

  /// 添加系统提示词
  void appendSystemPrompt(String additional) {
    if (additional.isNotEmpty) {
      systemPrompt = '$systemPrompt\n\n$additional';
    }
  }

  /// 添加消息
  void addMessage(Map<String, dynamic> message) {
    messages.add(message);
  }

  /// 设置工具列表
  void setTools(List<Map<String, dynamic>> toolList) {
    tools = toolList;
  }
}

/// LLM 响应上下文
/// 包含响应的所有信息，供钩子查看
class LLMResponseContext {
  final String text;
  final Map<String, dynamic> metadata;
  final List<Map<String, dynamic>>? toolCalls;

  const LLMResponseContext({
    required this.text,
    this.metadata = const {},
    this.toolCalls,
  });
}
