import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'plugin.dart';
import 'plugin_metadata.dart';
import 'plugin_state.dart';
import 'handlers/command_handler.dart';
import 'handlers/ai_tool.dart';
import 'handlers/llm_hook.dart';

/// 插件基类的默认实现
/// 提供状态管理、配置管理的默认实现，简化插件开发
abstract class BasePlugin implements Plugin {
  @override
  final PluginMetadata metadata;

  PluginState _state = PluginState.uninitialized;
  Map<String, dynamic> _config = {};

  BasePlugin({required this.metadata});

  // ========== 从 metadata 获取基本信息 ==========

  @override
  String get id => metadata.id;

  @override
  String get name => metadata.name;

  @override
  String get description => metadata.description;

  @override
  IconData get icon => metadata.icon;

  // ========== 状态管理 ==========

  @override
  PluginState get state => _state;

  @override
  bool get enabled => _state == PluginState.enabled;

  /// 更新状态（供子类调用）
  @protected
  void setState(PluginState newState) {
    _state = newState;
  }

  @override
  void updateConfig(Map<String, dynamic> config) {
    _config = Map.from(config);
  }

  @override
  Map<String, dynamic> getConfig() {
    return Map.from(_config);
  }

  // ========== 生命周期方法提供默认空实现 ==========

  @override
  Future<void> onInitialize() async {
    setState(PluginState.ready);
  }

  @override
  Future<void> onEnable() async {
    setState(PluginState.enabled);
  }

  @override
  Future<void> onDisable() async {
    setState(PluginState.disabled);
  }

  @override
  Future<void> onDestroy() async {
    setState(PluginState.destroyed);
  }

  @override
  Future<void> onConfigChanged(Map<String, dynamic> newConfig) async {}

  // ========== 功能注册方法提供默认空实现 ==========

  @override
  List<CommandHandler> getCommands() => [];

  @override
  List<AITool> getTools() => [];

  @override
  List<LLMHook> getHooks() => [];
}
