import 'package:flutter/material.dart';
import '../domain/base_plugin.dart';
import '../domain/plugin.dart';
import '../domain/plugin_metadata.dart';
import '../domain/config/config_field.dart';
import '../domain/config/config_field_type.dart';
import 'time_awareness_config.dart';

/// 时间增强插件
///
/// 让 AI 感知现实世界的时间：
/// 1. 在系统提示词中注入当前时间
/// 2. 为历史消息添加时间戳前缀（通过配置控制 toHistoryJson 行为）
/// 3. 告知 AI 距离上次对话过了多久
class TimeAwarenessPlugin extends BasePlugin {
  static final _metadata = PluginMetadata(
    id: 'time_awareness',
    name: '时间感知',
    description: '让AI感知现实世界的时间，理解消息的时序关系',
    version: '1.0.0',
    author: 'AIcove Team',
    icon: Icons.access_time,
    configSchema: {
      'enabled': ConfigField(
        type: ConfigFieldType.boolean,
        label: '启用插件',
        defaultValue: false,
      ),
      'includeMessageTimestamp': ConfigField(
        type: ConfigFieldType.boolean,
        label: '消息时间戳',
        description: '在每条消息前添加发送时间',
        defaultValue: true,
      ),
      'includeCurrentTime': ConfigField(
        type: ConfigFieldType.boolean,
        label: '当前时间提示',
        description: '在系统提示词中告知AI当前时间',
        defaultValue: true,
      ),
    },
  );

  TimeAwarenessConfig _config;

  /// 上一条消息的时间，由外部在构建请求前设置
  DateTime? _lastMessageTime;

  TimeAwarenessPlugin(this._config) : super(metadata: _metadata);

  /// 设置最后一条消息的时间，用于计算对话间隔
  void setLastMessageTime(DateTime? time) {
    _lastMessageTime = time;
  }

  @override
  bool get enabled => _config.enabled;

  /// 是否需要为消息添加时间戳
  bool get shouldIncludeTimestamp => enabled && _config.includeMessageTimestamp;

  @override
  Future<String?> getSystemPrompt({String? userMessage, bool supportsToolCalling = false}) async {
    if (!enabled || !_config.includeCurrentTime) {
      return null;
    }

    final now = DateTime.now();
    final weekday = _getWeekdayName(now.weekday);
    final y = now.year.toString();
    final m = now.month.toString().padLeft(2, '0');
    final d = now.day.toString().padLeft(2, '0');
    final h = now.hour.toString().padLeft(2, '0');
    final min = now.minute.toString().padLeft(2, '0');
    
    final datetime = '$y-$m-$d $h:$min ($weekday)';

    final parts = <String>[];
    parts.add(_config.currentTimePromptTemplate.replaceAll('{datetime}', datetime));

    // 计算距离上次对话的时间间隔
    if (_lastMessageTime != null) {
      final elapsed = now.difference(_lastMessageTime!);
      final elapsedText = _formatElapsed(elapsed);
      if (elapsedText != null) {
        parts.add('距离上次对话已过去$elapsedText。');
      }
    }

    return parts.join('\n');
  }

  /// 将时间差格式化为可读文本
  /// 不足1分钟返回null（刚刚聊过，无需提示）
  String? _formatElapsed(Duration elapsed) {
    final totalMinutes = elapsed.inMinutes;
    if (totalMinutes < 1) return null;

    final days = elapsed.inDays;
    final hours = elapsed.inHours;

    if (days >= 1) {
      final remainHours = hours - days * 24;
      if (remainHours > 0) {
        return '$days天${remainHours}小时';
      }
      return '$days天';
    }

    if (hours >= 1) {
      final remainMinutes = totalMinutes - hours * 60;
      if (remainMinutes > 0) {
        return '$hours小时${remainMinutes}分钟';
      }
      return '$hours小时';
    }

    return '$totalMinutes分钟';
  }

  String _getWeekdayName(int weekday) {
    const names = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    return names[weekday - 1];
  }

  @override
  Future<PluginProcessResult> processResponse(String text) async {
    return PluginProcessResult(processedText: text, events: []);
  }

  @override
  void updateConfig(Map<String, dynamic> config) {
    _config = TimeAwarenessConfig.fromJson(config);
  }

  @override
  Map<String, dynamic> getConfig() => _config.toJson();
}
