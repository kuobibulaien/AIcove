import 'package:flutter/material.dart';
import '../../../core/services/system_reminder_service.dart';
import '../domain/base_plugin.dart';
import '../domain/plugin.dart';
import '../domain/plugin_metadata.dart';
import '../domain/config/config_field.dart';
import '../domain/config/config_field_type.dart';
import 'time_awareness_config.dart';

/// 时间增强插件
///
/// 让 AI 感知现实世界的时间：
/// 1. 通过系统提醒向模型注入当前时间和上一条用户消息时间
/// 2. 为历史消息添加时间戳前缀（通过配置控制 toHistoryJson 行为）
/// 3. 只负责提供时间数据，具体提醒注入交给公共 SystemReminderService
class TimeAwarenessPlugin extends BasePlugin {
  static const String currentDateTimeFieldName = 'current_datetime';
  static const String previousUserMessageDateTimeFieldName =
      'previous_user_message_datetime';
  static const _metadata = PluginMetadata(
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
        defaultValue: true,
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

  TimeAwarenessPlugin(this._config) : super(metadata: _metadata);

  @override
  bool get enabled => _config.enabled;

  /// 是否需要为消息添加时间戳
  bool get shouldIncludeTimestamp => enabled && _config.includeMessageTimestamp;

  SystemReminderPayload? buildSystemReminderPayload({
    required DateTime currentTime,
    required DateTime? previousUserMessageTime,
  }) {
    if (!enabled) {
      return null;
    }

    final parts = <String>[
      if (_config.includeCurrentTime)
        '当前时间为${_formatDateTime(currentTime)}',
      if (previousUserMessageTime != null)
        '用户上一次发消息的时间为${_formatDateTime(previousUserMessageTime)}',
    ];
    if (parts.isEmpty) return null;
    parts.add('自行判断当前与历史对话的关系。');

    return SystemReminderPayload(
      rawContent: '${parts.join('。')}',
    );
  }

  String buildSystemReminderFieldGuide() {
    return '';
  }

  @override
  Future<String?> getSystemPrompt({
    String? userMessage,
    bool supportsToolCalling = false,
  }) async {
    return null;
  }

  String _formatDateTime(DateTime dateTime) {
    final y = dateTime.year.toString();
    final m = dateTime.month.toString().padLeft(2, '0');
    final d = dateTime.day.toString().padLeft(2, '0');
    final h = dateTime.hour.toString().padLeft(2, '0');
    final min = dateTime.minute.toString().padLeft(2, '0');
    final sec = dateTime.second.toString().padLeft(2, '0');
    final weekday = _getWeekdayName(dateTime.weekday);
    final offset = _formatTimezoneOffset(dateTime.timeZoneOffset);
    return '$y-$m-$d $h:$min:$sec $offset ($weekday)';
  }

  String _formatTimezoneOffset(Duration offset) {
    final totalMinutes = offset.inMinutes;
    final sign = totalMinutes >= 0 ? '+' : '-';
    final absoluteMinutes = totalMinutes.abs();
    final hours = (absoluteMinutes ~/ 60).toString().padLeft(2, '0');
    final minutes = (absoluteMinutes % 60).toString().padLeft(2, '0');
    return '$sign$hours:$minutes';
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

  String _getWeekdayName(int weekday) {
    const names = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    return names[weekday - 1];
  }
}
