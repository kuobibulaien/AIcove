import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_logger.dart';
import '../../chat/domain/conversation.dart';
import '../../chat/domain/message.dart';
import '../../chat/services/chat_history_store.dart';
import '../../plugins/domain/handlers/ai_tool.dart';
import '../../plugins/domain/handlers/tool_parameter.dart';
import 'auto_reply_trigger.dart';
import 'auto_reply_trigger_controller.dart';
import 'proactive_message_pregenerator.dart';

class ProactiveSchedulerToolbox {
  ProactiveSchedulerToolbox({
    required Ref ref,
    required Conversation conversation,
    required List<Message> contextMessages,
  })  : _ref = ref,
        _conversation = conversation,
        _contextMessages = List<Message>.unmodifiable(contextMessages);

  final Ref _ref;
  final Conversation _conversation;
  final List<Message> _contextMessages;
  final Map<String, _ProactivePreview> _previews =
      <String, _ProactivePreview>{};

  String? createdTriggerId;

  List<AITool> get tools => <AITool>[
        _previewTool,
        _createFromPreviewTool,
      ];

  AITool get _previewTool => AITool(
        name: 'preview_proactive_reply',
        description: '''
预览一条 AI 主动回复计划。此工具不会创建真实触发器，只会：
1. 接收你设计的预计触发时间和客观背景旁白；
2. 调用当前会话 chat 模型试生成最终主动回复；
3. 返回 preview_id、candidate_reply 和基础警告，供你审核时机和内容。

如果 candidate_reply 不合适，请调整 expected_fire_at 或 background_narration 后再次调用本工具。''',
        parameters: {
          'kind': const ToolParameter(
            type: 'string',
            description: '主动回复类型',
            required: true,
            enumValues: ['continue_chat', 'check_in', 'new_topic'],
          ),
          'expected_fire_at': const ToolParameter(
            type: 'string',
            description: '预计触发时间，ISO 8601 格式，必须基于设备本地时间和当前上下文判断',
            required: false,
          ),
          'delay_minutes': const ToolParameter(
            type: 'integer',
            description: '如果不传 expected_fire_at，可传从现在起延迟多少分钟触发',
            required: false,
          ),
          'title': const ToolParameter(
            type: 'string',
            description: '计划标题，简短、可读，用于后台列表展示',
            required: false,
          ),
          'background_narration': const ToolParameter(
            type: 'string',
            description: '客观旁白式背景信息，只描述预计触发时的上下文和时间情境，不要写角色台词或“你要...”指令',
            required: true,
          ),
          'allow_night': const ToolParameter(
            type: 'boolean',
            description: '是否允许夜间触发',
            required: false,
          ),
          'priority': const ToolParameter(
            type: 'string',
            description: '触发优先级',
            required: false,
            enumValues: ['low', 'medium', 'high'],
          ),
        },
        handler: _handlePreview,
      );

  AITool get _createFromPreviewTool => AITool(
        name: 'create_proactive_trigger_from_preview',
        description: '''
基于已经审核通过的 preview_id 创建真实 AI 自动主动回复触发器。
必须先调用 preview_proactive_reply 并确认 candidate_reply 的内容、语气和触发时机都合适，才能调用本工具。
本工具会把预览里的 expected_fire_at、background_narration、candidate_reply 原样写入真实触发器。''',
        parameters: {
          'preview_id': const ToolParameter(
            type: 'string',
            description: 'preview_proactive_reply 返回的 preview_id',
            required: true,
          ),
          'title': const ToolParameter(
            type: 'string',
            description: '最终触发器标题，简短可读',
            required: false,
          ),
          'approval_reason': const ToolParameter(
            type: 'string',
            description: '为什么这个预生成回复和触发时机适合发送',
            required: true,
          ),
        },
        handler: _handleCreateFromPreview,
      );

  Future<String?> _handlePreview(Map<String, dynamic> args) async {
    try {
      final kind = _parseKind(args['kind']);
      if (kind == null) {
        return _json({
          'ok': false,
          'error': 'invalid_kind',
        });
      }

      final backgroundNarration =
          (args['background_narration'] as String?)?.trim() ?? '';
      if (backgroundNarration.isEmpty) {
        return _json({
          'ok': false,
          'error': 'background_narration_required',
        });
      }

      final expectedFireAt = _resolveExpectedFireAt(args);
      if (expectedFireAt == null) {
        return _json({
          'ok': false,
          'error': 'expected_fire_at_or_delay_minutes_required',
        });
      }

      final now = DateTime.now();
      if (!expectedFireAt.isAfter(now)) {
        return _json({
          'ok': false,
          'error': 'expected_fire_at_must_be_future',
          'device_local_time': now.toIso8601String(),
        });
      }

      final allowNight = args['allow_night'] == true;
      final priority =
          _parsePriority(args['priority']) ?? _defaultPriorityForKind(kind);
      final title = ((args['title'] as String?)?.trim().isNotEmpty ?? false)
          ? (args['title'] as String).trim()
          : _defaultTitleForKind(kind);

      final candidateReply =
          await _ref.read(proactiveMessagePregeneratorProvider).generate(
                conversation: _conversation,
                contextMessages: _contextMessages,
                systemReminder: backgroundNarration,
              );

      final normalizedReply = candidateReply?.trim() ?? '';
      if (normalizedReply.isEmpty) {
        return _json({
          'ok': false,
          'error': 'candidate_reply_empty',
        });
      }

      final preview = _ProactivePreview(
        id: 'preview_${DateTime.now().microsecondsSinceEpoch}',
        kind: kind,
        title: title,
        expectedFireAt: expectedFireAt,
        backgroundNarration: backgroundNarration,
        candidateReply: normalizedReply,
        allowNight: allowNight,
        priority: priority,
      );
      _previews[preview.id] = preview;

      final warnings = _buildPreviewWarnings(preview);
      AppLogger.info('ProactiveSchedulerToolbox', '主动回复预览已生成', metadata: {
        'previewId': preview.id,
        'conversationId': _conversation.id,
        'kind': preview.kind,
        'expectedFireAt': preview.expectedFireAt.toIso8601String(),
        'replyLength': preview.candidateReply.length,
        'warnings': warnings,
      });

      return _json({
        'ok': true,
        'preview_id': preview.id,
        'kind': preview.kind,
        'title': preview.title,
        'expected_fire_at': preview.expectedFireAt.toIso8601String(),
        'delay_minutes':
            preview.expectedFireAt.difference(now).inMinutes.clamp(1, 100000),
        'allow_night': preview.allowNight,
        'priority': preview.priority.name,
        'background_narration': preview.backgroundNarration,
        'candidate_reply': preview.candidateReply,
        'warnings': warnings,
      });
    } catch (e) {
      AppLogger.error('ProactiveSchedulerToolbox', '主动回复预览失败', metadata: {
        'conversationId': _conversation.id,
        'error': e.toString(),
      });
      return _json({
        'ok': false,
        'error': e.toString(),
      });
    }
  }

  Future<String?> _handleCreateFromPreview(Map<String, dynamic> args) async {
    final previewId = (args['preview_id'] as String?)?.trim() ?? '';
    if (previewId.isEmpty) {
      return _json({
        'ok': false,
        'error': 'preview_id_required',
      });
    }

    final preview = _previews[previewId];
    if (preview == null) {
      return _json({
        'ok': false,
        'error': 'preview_not_found',
        'preview_id': previewId,
      });
    }

    final currentLastUserMessage = await _ref
        .read(chatHistoryStoreProvider)
        .getLastUserMessage(_conversation.id);
    final contextLastUserMessage = _lastUserMessageInContext();
    if (contextLastUserMessage?.id != null &&
        currentLastUserMessage?.id != contextLastUserMessage!.id) {
      return _json({
        'ok': false,
        'error': 'stale_context_user_message_changed',
        'expected_last_user_message_id': contextLastUserMessage.id,
        'current_last_user_message_id': currentLastUserMessage?.id,
      });
    }

    await _clearExistingAiTriggers();

    final now = DateTime.now();
    final delayMinutes =
        preview.expectedFireAt.difference(now).inMinutes.clamp(1, 100000);
    final trigger =
        await _ref.read(autoReplyTriggersProvider.notifier).createTrigger(
              title: ((args['title'] as String?)?.trim().isNotEmpty ?? false)
                  ? (args['title'] as String).trim()
                  : preview.title,
              type: AutoReplyTriggerType.delay,
              nextFireAt: preview.expectedFireAt,
              allowNight: preview.allowNight,
              requireExact: false,
              delayMinutes: delayMinutes,
              prompt: preview.backgroundNarration,
              priority: preview.priority,
              source: TriggerSource.aiScheduler,
              conversationId: _conversation.id,
              contextLastUserMessageId: currentLastUserMessage?.id,
              contextLastUserMessageAt: currentLastUserMessage?.createdAt,
              cachedContent: preview.candidateReply,
              preparedAt: now,
            );

    // 后台 WorkManager 任务由 createTrigger 内部统一注册，这里不再重复注册
    createdTriggerId = trigger.id;

    AppLogger.info('ProactiveSchedulerToolbox', '主动回复真实触发器已创建', metadata: {
      'previewId': preview.id,
      'triggerId': trigger.id,
      'conversationId': _conversation.id,
      'approvalReason': (args['approval_reason'] as String?)?.trim(),
    });

    return _json({
      'ok': true,
      'preview_id': preview.id,
      'trigger_id': trigger.id,
      'expected_fire_at': preview.expectedFireAt.toIso8601String(),
      'cached_content_length': preview.candidateReply.length,
    });
  }

  Future<void> _clearExistingAiTriggers() async {
    final currentTriggers =
        _ref.read(autoReplyTriggersProvider).valueOrNull ?? const [];
    final controller = _ref.read(autoReplyTriggersProvider.notifier);
    for (final trigger in currentTriggers) {
      if (trigger.conversationId != _conversation.id) continue;
      if (trigger.source != TriggerSource.aiScheduler) continue;
      if (!trigger.isActive &&
          trigger.status != AutoReplyTriggerStatus.paused) {
        continue;
      }
      await controller.deleteTrigger(
        trigger.id,
        reason: 'replaced_by_proactive_scheduler_tool',
      );
    }
  }

  Message? _lastUserMessageInContext() {
    for (final message in _contextMessages.reversed) {
      if (message.role.trim().toLowerCase() == 'user') {
        return message;
      }
    }
    return null;
  }

  DateTime? _resolveExpectedFireAt(Map<String, dynamic> args) {
    final rawExpected = (args['expected_fire_at'] as String?)?.trim();
    if (rawExpected != null && rawExpected.isNotEmpty) {
      return DateTime.tryParse(rawExpected)?.toLocal();
    }

    final delayMinutes = _parsePositiveInt(args['delay_minutes']);
    if (delayMinutes == null) return null;
    return DateTime.now().add(Duration(minutes: delayMinutes));
  }

  int? _parsePositiveInt(dynamic rawValue) {
    if (rawValue is num) {
      final value = rawValue.toInt();
      return value > 0 ? value : null;
    }
    if (rawValue is String) {
      final value = int.tryParse(rawValue.trim());
      if (value != null && value > 0) {
        return value;
      }
    }
    return null;
  }

  String? _parseKind(dynamic rawKind) {
    final value = rawKind?.toString().trim().toLowerCase();
    switch (value) {
      case 'continue_chat':
      case 'check_in':
      case 'new_topic':
        return value;
      default:
        return null;
    }
  }

  AutoReplyTriggerPriority? _parsePriority(dynamic rawPriority) {
    switch (rawPriority?.toString().trim().toLowerCase()) {
      case 'high':
        return AutoReplyTriggerPriority.high;
      case 'medium':
        return AutoReplyTriggerPriority.medium;
      case 'low':
        return AutoReplyTriggerPriority.low;
      default:
        return null;
    }
  }

  AutoReplyTriggerPriority _defaultPriorityForKind(String kind) {
    switch (kind) {
      case 'new_topic':
        return AutoReplyTriggerPriority.low;
      case 'continue_chat':
      case 'check_in':
      default:
        return AutoReplyTriggerPriority.medium;
    }
  }

  String _defaultTitleForKind(String kind) {
    switch (kind) {
      case 'continue_chat':
        return '继续当前话题';
      case 'check_in':
        return '稍后问候';
      case 'new_topic':
        return '晚些时候开启新话题';
      default:
        return '主动回复';
    }
  }

  List<String> _buildPreviewWarnings(_ProactivePreview preview) {
    final warnings = <String>[];
    final hour = preview.expectedFireAt.hour;
    if (!preview.allowNight && (hour >= 23 || hour < 7)) {
      warnings.add('expected_fire_at_in_quiet_night_without_allow_night');
    }
    final lowerReply = preview.candidateReply.toLowerCase();
    if (lowerReply.contains('为什么不回') ||
        lowerReply.contains('怎么不回') ||
        lowerReply.contains('不理我')) {
      warnings.add('candidate_reply_may_pressure_user');
    }
    if (preview.backgroundNarration.contains('你要') ||
        preview.backgroundNarration.contains('你应该')) {
      warnings.add('background_narration_contains_direct_instruction');
    }
    return warnings;
  }

  String _json(Map<String, dynamic> value) => jsonEncode(value);
}

class _ProactivePreview {
  const _ProactivePreview({
    required this.id,
    required this.kind,
    required this.title,
    required this.expectedFireAt,
    required this.backgroundNarration,
    required this.candidateReply,
    required this.allowNight,
    required this.priority,
  });

  final String id;
  final String kind;
  final String title;
  final DateTime expectedFireAt;
  final String backgroundNarration;
  final String candidateReply;
  final bool allowNight;
  final AutoReplyTriggerPriority priority;
}


