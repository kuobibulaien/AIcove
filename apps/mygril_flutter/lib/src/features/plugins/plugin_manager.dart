// ignore_for_file: avoid_print
import 'domain/index.dart';
import '../../core/app_logger.dart';

/// 插件管理器
/// 负责注册、管理和协调所有插件
/// 支持生命周期管理、功能收集和命令处理
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

  /// 获取所有启用插件的系统提示词
  /// 返回合并后的提示词字符串
  /// 
  /// [supportsToolCalling] 为 true 时，支持 Tool Calling 的插件会跳过提示词注入
  /// 
  /// 注意：单个插件失败不会影响其他插件和整体对话流程
  Future<String> getSystemPrompts({String? userMessage, bool supportsToolCalling = false}) async {
    final enabledPlugins = getEnabledPlugins();
    if (enabledPlugins.isEmpty) {
      return '';
    }

    final prompts = <String>[];
    for (final plugin in enabledPlugins) {
      try {
        final prompt = await plugin.getSystemPrompt(
          userMessage: userMessage,
          supportsToolCalling: supportsToolCalling,
        );
        if (prompt != null && prompt.isNotEmpty) {
          prompts.add(prompt);
        }
      } catch (e) {
        // 单个插件失败不影响其他插件和整体对话流程
        AppLogger.warning('PluginManager', '插件 getSystemPrompt 失败', metadata: {
          'pluginId': plugin.id,
          'error': e.toString(),
        });
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
        AppLogger.warning('PluginManager', '插件 processResponse 失败', metadata: {
          'pluginId': plugin.id,
          'error': e.toString(),
        });
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

  // ========== 新增：功能收集 ==========

  /// 获取所有启用插件的命令
  List<CommandHandler> getAllCommands() {
    final commands = <CommandHandler>[];
    
    for (final plugin in getEnabledPlugins()) {
      try {
        commands.addAll(plugin.getCommands());
      } catch (e) {
        print('[PluginManager] 插件 ${plugin.id} 获取命令失败: $e');
      }
    }
    
    return commands;
  }

  /// 获取所有启用插件的 AI 工具
  List<AITool> getAllTools() {
    final tools = <AITool>[];
    
    for (final plugin in getEnabledPlugins()) {
      try {
        tools.addAll(plugin.getTools());
      } catch (e) {
        print('[PluginManager] 插件 ${plugin.id} 获取工具失败: $e');
      }
    }
    
    return tools;
  }

  /// 根据名称查找工具
  AITool? findToolByName(String name) {
    for (final tool in getAllTools()) {
      if (tool.name == name) return tool;
    }
    return null;
  }

  /// 获取指定类型的所有 LLM 钩子
  List<LLMHook> getHooksByType(LLMHookType type) {
    final hooks = <LLMHook>[];
    
    for (final plugin in getEnabledPlugins()) {
      try {
        final allHooks = plugin.getHooks();
        hooks.addAll(allHooks.where((h) => h.type == type));
      } catch (e) {
        print('[PluginManager] 插件 ${plugin.id} 获取钩子失败: $e');
      }
    }
    
    return hooks;
  }

  // ========== 新增：命令处理 ==========

  /// 处理用户输入的命令
  /// [input] 用户输入的命令字符串
  /// [context] 插件上下文，包含环境信息和操作能力
  /// 返回 null 表示不是命令或没有匹配的命令
  Future<String?> handleCommand(String input, PluginContext context) async {
    final trimmed = input.trim();
    
    // 检查是否以 / 开头
    if (!trimmed.startsWith('/')) {
      return null;
    }
    
    // 获取所有命令
    final commands = getAllCommands();
    
    // 查找匹配的命令
    for (final cmd in commands) {
      if (cmd.matches(trimmed)) {
        try {
          final args = cmd.parseArgs(trimmed);
          return await cmd.handler(context, args);
        } catch (e) {
          return '命令执行失败: $e';
        }
      }
    }
    
    return '未找到命令: ${trimmed.split(' ').first}';
  }
}
