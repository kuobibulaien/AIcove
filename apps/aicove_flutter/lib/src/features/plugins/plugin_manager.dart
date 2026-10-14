// ignore_for_file: avoid_print
import 'domain/index.dart';

/// 插件管理器
/// 负责注册、管理和协调所有插件
/// 支持生命周期管理；执行能力经 v2 注册器贡献（见 PluginRuntime）
class PluginManager {
  final Map<String, Plugin> _plugins = {};

  // ========== 现有方法（保留） ==========

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

  // ========== 新增：生命周期管理 ==========

  /// 初始化指定插件
  Future<void> initialize(String pluginId) async {
    final plugin = _plugins[pluginId];
    if (plugin == null) {
      throw Exception('插件不存在: $pluginId');
    }

    if (plugin.state != PluginState.uninitialized) {
      print('[PluginManager] 插件 $pluginId 已初始化，跳过');
      return;
    }

    try {
      print('[PluginManager] 初始化插件: $pluginId');
      await plugin.onInitialize();
      
      // 如果插件默认启用，自动启用
      if (plugin.enabled) {
        await enable(pluginId);
      }
    } catch (e) {
      print('[PluginManager] 插件 $pluginId 初始化失败: $e');
      rethrow;
    }
  }

  /// 启用指定插件
  Future<void> enable(String pluginId) async {
    final plugin = _plugins[pluginId];
    if (plugin == null) {
      throw Exception('插件不存在: $pluginId');
    }

    if (!plugin.state.canEnable) {
      print('[PluginManager] 插件 $pluginId 当前状态不允许启用: ${plugin.state}');
      return;
    }

    try {
      print('[PluginManager] 启用插件: $pluginId');
      await plugin.onEnable();
    } catch (e) {
      print('[PluginManager] 插件 $pluginId 启用失败: $e');
      rethrow;
    }
  }

  /// 禁用指定插件
  Future<void> disable(String pluginId) async {
    final plugin = _plugins[pluginId];
    if (plugin == null) {
      throw Exception('插件不存在: $pluginId');
    }

    if (!plugin.state.canDisable) {
      print('[PluginManager] 插件 $pluginId 当前状态不允许禁用: ${plugin.state}');
      return;
    }

    try {
      print('[PluginManager] 禁用插件: $pluginId');
      await plugin.onDisable();
    } catch (e) {
      print('[PluginManager] 插件 $pluginId 禁用失败: $e');
      rethrow;
    }
  }

  /// 销毁指定插件
  Future<void> destroy(String pluginId) async {
    final plugin = _plugins[pluginId];
    if (plugin == null) {
      throw Exception('插件不存在: $pluginId');
    }

    try {
      print('[PluginManager] 销毁插件: $pluginId');
      
      // 如果已启用，先禁用
      if (plugin.state == PluginState.enabled) {
        await disable(pluginId);
      }
      
      await plugin.onDestroy();
    } catch (e) {
      print('[PluginManager] 插件 $pluginId 销毁失败: $e');
      rethrow;
    }
  }

  /// 初始化所有插件（App 启动时调用）
  Future<void> initializeAll() async {
    print('[PluginManager] 开始初始化所有插件...');
    
    for (final plugin in _plugins.values) {
      if (plugin.state == PluginState.uninitialized) {
        try {
          await initialize(plugin.id);
        } catch (e) {
          print('[PluginManager] 插件 ${plugin.id} 初始化失败，跳过: $e');
          // 单个插件失败不影响其他插件
        }
      }
    }
    
    print('[PluginManager] 所有插件初始化完成');
  }

  /// 销毁所有插件（App 退出时调用）
  Future<void> destroyAll() async {
    print('[PluginManager] 开始销毁所有插件...');
    
    for (final plugin in _plugins.values) {
      if (plugin.state != PluginState.destroyed) {
        try {
          await destroy(plugin.id);
        } catch (e) {
          print('[PluginManager] 插件 ${plugin.id} 销毁失败，继续: $e');
          // 清理过程中的错误不应阻止其他插件
        }
      }
    }
    
    print('[PluginManager] 所有插件已销毁');
  }
}
