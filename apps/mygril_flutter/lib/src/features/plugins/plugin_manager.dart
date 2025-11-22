import 'domain/plugin.dart';

/// 插件管理器
/// 负责注册、管理和协调所有插件
class PluginManager {
  final Map<String, Plugin> _plugins = {};

  /// 注册插件
  void register(Plugin plugin) {
    _plugins[plugin.id] = plugin;
  }

  /// 更新已注册插件（若不存在则注册）
  void updatePlugin(Plugin plugin) {
    _plugins[plugin.id] = plugin;
  }

  /// 取消注册插件
  void unregister(String pluginId) {
    _plugins.remove(pluginId);
  }

  /// 获取所有已注册的插件
  List<Plugin> getAllPlugins() {
    return _plugins.values.toList();
  }

  /// 获取所有启用的插件
  List<Plugin> getEnabledPlugins() {
    return _plugins.values.where((p) => p.enabled).toList();
  }

  /// 根据 ID 获取插件
  Plugin? getPlugin(String pluginId) {
    return _plugins[pluginId];
  }

  /// 获取所有启用插件的系统提示词
  /// 返回合并后的提示词字符串
  Future<String> getSystemPrompts({String? userMessage}) async {
    final enabledPlugins = getEnabledPlugins();
    if (enabledPlugins.isEmpty) {
      return '';
    }

    final prompts = <String>[];
    for (final plugin in enabledPlugins) {
      final prompt = await plugin.getSystemPrompt(userMessage: userMessage);
      if (prompt != null && prompt.isNotEmpty) {
        prompts.add(prompt);
      }
    }

    if (prompts.isEmpty) {
      return '';
    }

    return prompts.join('\n\n');
  }

  /// 处理 AI 响应
  /// 按顺序通过所有启用的插件处理文本
  /// 返回最终处理结果和所有插件生成的事件
  Future<PluginProcessResult> processResponse(String text) async {
    final enabledPlugins = getEnabledPlugins();
    if (enabledPlugins.isEmpty) {
      return PluginProcessResult(
        processedText: text,
        events: [],
      );
    }

    String currentText = text;
    final allEvents = <PluginEvent>[];

    // 按顺序通过每个插件处理
    for (final plugin in enabledPlugins) {
      try {
        final result = await plugin.processResponse(currentText);
        currentText = result.processedText;
        allEvents.addAll(result.events);
      } catch (e) {
        // 插件处理失败不应影响其他插件
        print('[PluginManager] Plugin ${plugin.id} failed to process: $e');
      }
    }

    return PluginProcessResult(
      processedText: currentText,
      events: allEvents,
    );
  }

  /// 更新插件配置
  void updatePluginConfig(String pluginId, Map<String, dynamic> config) {
    final plugin = _plugins[pluginId];
    plugin?.updateConfig(config);
  }

  /// 获取插件配置
  Map<String, dynamic>? getPluginConfig(String pluginId) {
    final plugin = _plugins[pluginId];
    return plugin?.getConfig();
  }

  /// 清空所有插件
  void clear() {
    _plugins.clear();
  }
}
