import 'package:flutter/material.dart';
import 'plugin_metadata.dart';
import 'plugin_state.dart';
import 'plugin_content.dart';
import 'handlers/command_handler.dart';
import 'handlers/ai_tool.dart';
import 'handlers/llm_hook.dart';

/// 插件基础接口
/// 定义所有插件必须实现的核心功能
abstract class Plugin {
  // ========== 元数据 ==========

  /// 插件元数据
  PluginMetadata get metadata;

  /// 插件唯一标识符
  String get id;

  /// 插件显示名称
  String get name;

  /// 插件描述
  String get description;

  /// 插件图标
  IconData get icon;

  // ========== 状态管理 ==========

  /// 当前状态
  PluginState get state;

  /// 插件是否启用
  bool get enabled;

  // ========== 生命周期钩子（新增） ==========

  /// 插件初始化
  /// 调用时机：App 启动时或插件安装时
  /// 用途：加载配置、初始化客户端、检查依赖
  Future<void> onInitialize();

  /// 插件启用
  /// 调用时机：用户启用插件时
  /// 用途：开始监听事件、注册功能
  Future<void> onEnable();

  /// 插件禁用
  /// 调用时机：用户禁用插件时
  /// 用途：停止监听、暂停服务
  Future<void> onDisable();

  /// 插件销毁
  /// 调用时机：App 退出或插件卸载时
  /// 用途：释放资源、关闭连接、保存状态
  Future<void> onDestroy();

  /// 配置变更
  /// 调用时机：用户修改插件配置后
  /// 用途：应用新配置、重新初始化相关资源
  Future<void> onConfigChanged(Map<String, dynamic> newConfig);

  // ========== 功能注册（新增） ==========

  /// 获取插件提供的命令处理器
  /// 用于响应用户输入的命令（如 /tts）
  List<CommandHandler> getCommands();

  /// 获取插件提供的 AI 工具
  /// 用于 Function Calling（让 AI 调用插件功能）
  List<AITool> getTools();

  /// 获取插件提供的 LLM 钩子
  /// 用于在 LLM 请求/响应前后介入处理
  List<LLMHook> getHooks();

  // ========== 现有功能（保留） ==========

  /// 获取插件提供的系统提示词
  /// 当插件启用时，这些提示词会被注入到对话中
  /// [userMessage] 是用户当前发送的消息，用于 RAG 等上下文感知场景
  /// [supportsToolCalling] 为 true 时，插件可以跳过提示词注入（使用原生工具调用）
  Future<String?> getSystemPrompt({String? userMessage, bool supportsToolCalling = false});

  /// 处理 AI 响应文本
  /// 插件可以从响应中提取特定标记，生成事件，并返回处理后的文本
  Future<PluginProcessResult> processResponse(String text);

  /// 更新插件配置
  void updateConfig(Map<String, dynamic> config);

  /// 获取插件配置
  Map<String, dynamic> getConfig();
}

/// 插件处理结果
class PluginProcessResult {
  /// 处理后的文本（通常是移除了插件标记的纯文本）
  /// 保留此字段以保持向后兼容
  final String processedText;

  /// 插件生成的事件列表（如 TTS 转换事件）
  final List<PluginEvent> events;
  
  /// 结构化多媒体内容列表
  /// 可包含文本、图片、音频、自定义UI等
  final List<PluginContent> contents;

  PluginProcessResult({
    required this.processedText,
    required this.events,
    this.contents = const [],
  });

  PluginProcessResult copyWith({
    String? processedText,
    List<PluginEvent>? events,
    List<PluginContent>? contents,
  }) {
    return PluginProcessResult(
      processedText: processedText ?? this.processedText,
      events: events ?? this.events,
      contents: contents ?? this.contents,
    );
  }
}

/// 插件事件
/// 表示插件需要执行的操作（如 TTS 转换、图片生成等）
class PluginEvent {
  /// 事件所属的插件 ID
  final String pluginId;

  /// 事件类型（如 'tts_convert', 'image_generate'）
  final String type;

  /// 事件数据
  final Map<String, dynamic> data;

  /// 事件唯一标识符
  final String id;

  /// 事件创建时间
  final DateTime createdAt;

  PluginEvent({
    required this.pluginId,
    required this.type,
    required this.data,
    String? id,
    DateTime? createdAt,
  })  : id = id ?? _generateId(),
        createdAt = createdAt ?? DateTime.now();

  static String _generateId() {
    return DateTime.now().millisecondsSinceEpoch.toString();
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'pluginId': pluginId,
      'type': type,
      'data': data,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  factory PluginEvent.fromJson(Map<String, dynamic> json) {
    return PluginEvent(
      id: json['id'] as String,
      pluginId: json['pluginId'] as String,
      type: json['type'] as String,
      data: json['data'] as Map<String, dynamic>,
      createdAt: DateTime.parse(json['createdAt'] as String),
    );
  }
}
