import 'package:flutter/material.dart';

/// 插件基础接口
/// 定义所有插件必须实现的核心功能
abstract class Plugin {
  /// 插件唯一标识符
  String get id;

  /// 插件显示名称
  String get name;

  /// 插件描述
  String get description;

  /// 插件图标（使用 Material Icons 的 IconData）
  IconData get icon;

  /// 插件是否启用
  bool get enabled;

  /// 获取插件提供的系统提示词
  /// 当插件启用时，这些提示词会被注入到对话中
  /// [userMessage] 是用户当前发送的消息，用于 RAG 等上下文感知场景
  Future<String?> getSystemPrompt({String? userMessage});

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
  final String processedText;

  /// 插件生成的事件列表（如 TTS 转换事件）
  final List<PluginEvent> events;

  PluginProcessResult({
    required this.processedText,
    required this.events,
  });

  PluginProcessResult copyWith({
    String? processedText,
    List<PluginEvent>? events,
  }) {
    return PluginProcessResult(
      processedText: processedText ?? this.processedText,
      events: events ?? this.events,
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
