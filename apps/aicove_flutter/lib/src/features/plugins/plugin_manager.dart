import 'domain/plugin.dart';

/// 插件注册表；请求期执行能力由 PluginRuntime 收集与管理。
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

  /// 清空所有插件
  void clear() {
    _plugins.clear();
  }
}
