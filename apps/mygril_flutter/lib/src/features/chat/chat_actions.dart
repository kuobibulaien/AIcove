/// 聊天动作入口（门面类）
///
/// 作为各聊天服务的协调层，提供简洁的公开 API。
/// 实际逻辑已拆分到以下服务：
/// - ChatSendService: 消息发送
/// - ChatTtsHandler: TTS 处理与消息交付
/// - ChatMessageProcessor: 消息处理
/// - AnalyzerScheduler: AI 管家分析调度
///
/// 更新记录：
/// - 2025-12-31: 重构为门面模式，进一步提取 TTS 处理
/// - 2026-01-27: 将 AI 管家分析触发逻辑委托给 AnalyzerScheduler
/// - 2026-01-28: 使用 deliverSegmentedMessages 统一消息交付，移除占位符机制
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/auto_reply_trigger.dart';
import 'data/analyzer_scheduler.dart';
import 'services/chat_send_service.dart';
import 'services/chat_tts_handler.dart';
import 'domain/message.dart';
import '../settings/app_settings.dart';
import 'conversation_providers.dart';
import 'chat_providers.dart';
import '../../core/app_logger.dart';

// 重新导出公共类型，保持向后兼容
export 'chat_providers.dart';
export 'services/chat_types.dart';
export 'services/chat_send_service.dart' show ChatSendService, ApiCallResult, ApiConfig, SendRequest;
export 'services/chat_tts_handler.dart' show ChatTtsHandler;

class ProactiveSendResult {
  final bool success;
  final bool retryable;
  final String reason;

  const ProactiveSendResult._({
    required this.success,
    required this.retryable,
    required this.reason,
  });

  const ProactiveSendResult.success()
      : this._(success: true, retryable: false, reason: 'sent');

  const ProactiveSendResult.skipped(String reason)
      : this._(success: false, retryable: false, reason: reason);

  const ProactiveSendResult.failed(String reason, {bool retryable = true})
      : this._(success: false, retryable: retryable, reason: reason);
}

class ChatActions {
  ChatActions(this._ref)
      : _sendService = _ref.read(chatSendServiceProvider),
        _ttsHandler = _ref.read(chatTtsHandlerProvider);

  final Ref _ref;
  final ChatSendService _sendService;
  final ChatTtsHandler _ttsHandler;

  // ===== 公开 API =====

  /// 发送文本消息
  Future<void> send(String text) async {
    final conv = _ref.read(activeConversationProvider);
    if (conv == null || text.trim().isEmpty) return;
    final convId = conv.id;

    final trace = AppLogger.startTrace('AI消息发送', source: 'ChatActions');
    _ref.read(sendingProvider.notifier).state = true;
    _ref.read(errorProvider.notifier).state = null;

    final userMsg = _sendService.createUserMessage(text: text, imagePath: null);
    await _sendService.addUserMessage(convId: convId, userMsg: userMsg, displayText: text);

    try {
      final settings = await _ref.read(appSettingsProvider.future);
      final history = _sendService.prepareHistory(conv: conv, userMsg: userMsg, limit: settings.historyMessageLimit);
      final config = await _sendService.prepareApiConfig(conv: conv, history: history, userText: text, trace: trace);
      final result = await _sendService.executeApiCall(config: config, sessionId: convId, userText: text, trace: trace);
      final buildResult = _sendService.buildAssistantMessages(apiResult: result, settings: settings);

      // 统一的消息交付入口：自动处理 TTS 分段发送
      await _ttsHandler.deliverSegmentedMessages(
        convId: convId,
        userMsgId: userMsg.id,
        buildResult: buildResult,
        replyText: result.replyText,
        pluginEvents: result.pluginEvents,
        ttsEnabled: settings.ttsEnabled,
        trace: trace,
      );

      trace.end(additionalMessage: '完成');
    } catch (e) {
      trace.error('失败', metadata: {'error': e.toString()});
      trace.end(additionalMessage: '失败');
      await _sendService.markUserMessageFailed(convId: convId, userMsgId: userMsg.id);
      _ref.read(errorProvider.notifier).state = e.toString();
    } finally {
      _ref.read(sendingProvider.notifier).state = false;
      // 委托给 AnalyzerScheduler：5分钟无新消息后触发 AI 管家分析
      _ref.read(analyzerSchedulerProvider).scheduleAnalysis();
    }
  }

  /// 发送图片消息
  Future<void> sendWithImage(String imagePath) async {
    final conv = _ref.read(activeConversationProvider);
    if (conv == null || imagePath.trim().isEmpty) return;
    final convId = conv.id;

    _ref.read(sendingProvider.notifier).state = true;
    _ref.read(errorProvider.notifier).state = null;

    final userMsg = _sendService.createUserMessage(text: null, imagePath: imagePath);
    await _sendService.addUserMessage(convId: convId, userMsg: userMsg, displayText: '[图片]');

    try {
      final settings = await _ref.read(appSettingsProvider.future);
      final history = _sendService.prepareHistory(conv: conv, userMsg: userMsg, limit: settings.historyMessageLimit);
      final config = await _sendService.prepareApiConfig(conv: conv, history: history, userText: '[image]');
      final result = await _sendService.executeApiCall(config: config, sessionId: convId, userText: '[image]');
      final buildResult = _sendService.buildAssistantMessages(apiResult: result, settings: settings);

      await _ttsHandler.deliverSegmentedMessages(
        convId: convId,
        userMsgId: userMsg.id,
        buildResult: buildResult,
        replyText: result.replyText,
        pluginEvents: result.pluginEvents,
        ttsEnabled: settings.ttsEnabled,
      );
    } catch (e) {
      await _sendService.markUserMessageFailed(convId: convId, userMsgId: userMsg.id);
      _ref.read(errorProvider.notifier).state = e.toString();
    } finally {
      _ref.read(sendingProvider.notifier).state = false;
      _ref.read(analyzerSchedulerProvider).scheduleAnalysis();
    }
  }

  /// 发送文件消息（目前按"文本文件附件"发送，供 AI 阅读）
  Future<void> sendWithFile(String filePath) async {
    final conv = _ref.read(activeConversationProvider);
    if (conv == null || filePath.trim().isEmpty) return;
    final convId = conv.id;

    _ref.read(sendingProvider.notifier).state = true;
    _ref.read(errorProvider.notifier).state = null;

    final userMsg = await _sendService.createUserFileMessage(filePath: filePath);
    await _sendService.addUserMessage(convId: convId, userMsg: userMsg, displayText: '[文件]');

    try {
      final settings = await _ref.read(appSettingsProvider.future);
      final history =
          _sendService.prepareHistory(conv: conv, userMsg: userMsg, limit: settings.historyMessageLimit);
      final config = await _sendService.prepareApiConfig(conv: conv, history: history, userText: '[file]');
      final result =
          await _sendService.executeApiCall(config: config, sessionId: convId, userText: '[file]');
      final buildResult = _sendService.buildAssistantMessages(apiResult: result, settings: settings);

      await _ttsHandler.deliverSegmentedMessages(
        convId: convId,
        userMsgId: userMsg.id,
        buildResult: buildResult,
        replyText: result.replyText,
        pluginEvents: result.pluginEvents,
        ttsEnabled: settings.ttsEnabled,
      );
    } catch (e) {
      await _sendService.markUserMessageFailed(convId: convId, userMsgId: userMsg.id);
      _ref.read(errorProvider.notifier).state = e.toString();
    } finally {
      _ref.read(sendingProvider.notifier).state = false;
      _ref.read(analyzerSchedulerProvider).scheduleAnalysis();
    }
  }

  /// 主动触发器发送
  /// 注意：作废检查已在 AutoReplyTriggerController._pollDueTriggers() 中完成
  /// 此方法被调用时，触发器已确认可以触发
  Future<ProactiveSendResult> sendProactiveTrigger(AutoReplyTrigger trigger) async {
    final settings = await _ref.read(appSettingsProvider.future);
    if (!settings.autoReplySettings.enabled) {
      AppLogger.info('ChatActions', 'Skip proactive trigger: auto-reply disabled', metadata: {
        'triggerId': trigger.id,
      });
      return const ProactiveSendResult.skipped('auto_reply_disabled');
    }

    // 确定目标会话：优先使用触发器绑定的会话，否则使用当前活跃会话
    final targetConvId = trigger.conversationId.isNotEmpty
        ? trigger.conversationId
        : _ref.read(activeConversationIdProvider);

    if (targetConvId == null || targetConvId.isEmpty) {
      AppLogger.warning('ChatActions', '触发器发送失败：无目标会话', metadata: {'triggerId': trigger.id});
      return const ProactiveSendResult.skipped('target_conversation_missing');
    }

    // 获取目标会话
    final conversations = _ref.read(conversationsProvider).valueOrNull ?? [];
    final conv = conversations.where((c) => c.id == targetConvId).firstOrNull;
    if (conv == null) {
      AppLogger.warning('ChatActions', '触发器发送失败：会话不存在', metadata: {'convId': targetConvId});
      return const ProactiveSendResult.skipped('target_conversation_not_found');
    }

    try {
      if (trigger.hasCachedContent) {
        final cachedReply = trigger.cachedContent!.trim();
        if (cachedReply.isNotEmpty) {
          final cachedResult = ApiCallResult(
            replyText: cachedReply,
            processedText: cachedReply,
            pluginEvents: const [],
            toolResults: const [],
          );
          final buildResult =
              _sendService.buildAssistantMessages(apiResult: cachedResult, settings: settings);
          await _ttsHandler.deliverSegmentedMessages(
            convId: targetConvId,
            userMsgId: '',
            buildResult: buildResult,
            replyText: cachedReply,
            pluginEvents: const [],
            ttsEnabled: settings.ttsEnabled,
          );
          AppLogger.info('ChatActions', '触发器发送成功（cached）', metadata: {
            'triggerId': trigger.id,
            'title': trigger.title,
          });
          return const ProactiveSendResult.success();
        }
      }

      final proactiveInput = (trigger.prompt?.trim().isNotEmpty ?? false)
          ? trigger.prompt!.trim()
          : trigger.title;
      final snapshotHistory = _buildSnapshotHistory(trigger.contextSnapshot);
      final history = snapshotHistory.isNotEmpty ? snapshotHistory : conv.messages;
      final config = await _sendService.prepareApiConfig(
        conv: conv,
        history: history,
        userText: proactiveInput,
      );
      final result = await _sendService.executeApiCall(
        config: config,
        sessionId: targetConvId,
        userText: proactiveInput,
      );
      final buildResult = _sendService.buildAssistantMessages(apiResult: result, settings: settings);

      // 触发器没有 userMsgId，使用空字符串
      await _ttsHandler.deliverSegmentedMessages(
        convId: targetConvId,
        userMsgId: '', // 触发器发送没有对应的用户消息
        buildResult: buildResult,
        replyText: result.replyText,
        pluginEvents: result.pluginEvents,
        ttsEnabled: settings.ttsEnabled,
      );

      AppLogger.info('ChatActions', '触发器发送成功', metadata: {
        'triggerId': trigger.id,
        'title': trigger.title,
      });
      return const ProactiveSendResult.success();
    } catch (e) {
      AppLogger.error('ChatActions', '触发器发送失败', metadata: {
        'triggerId': trigger.id,
        'error': e.toString(),
      });
      return ProactiveSendResult.failed(e.toString());
    }
  }

  List<Message> _buildSnapshotHistory(String? contextSnapshot) {
    if (contextSnapshot == null || contextSnapshot.trim().isEmpty) {
      return const <Message>[];
    }
    try {
      final decoded = jsonDecode(contextSnapshot);
      if (decoded is! List) return const <Message>[];

      final now = DateTime.now();
      final history = <Message>[];
      for (var i = 0; i < decoded.length; i++) {
        final raw = decoded[i];
        if (raw is! Map) continue;
        final map = Map<String, dynamic>.from(raw.cast<String, dynamic>());
        final role = (map['role'] as String?) ?? 'user';
        final content = _extractSnapshotText(map['content']);
        if (content.trim().isEmpty) continue;
        history.add(Message(
          id: 'snapshot_$i',
          role: role,
          content: content,
          createdAt: now,
          status: 'sent',
        ));
      }
      return history;
    } catch (_) {
      return const <Message>[];
    }
  }

  String _extractSnapshotText(dynamic rawContent) {
    if (rawContent is String) return rawContent;
    if (rawContent is! List) return '';

    final texts = <String>[];
    for (final part in rawContent) {
      if (part is! Map) continue;
      final map = Map<String, dynamic>.from(part.cast<String, dynamic>());
      if (map['type'] != 'text') continue;
      final text = (map['text'] as String?) ?? '';
      if (text.isNotEmpty) {
        texts.add(text);
      }
    }
    return texts.join('\n');
  }

  /// 重发失败的消息
  Future<void> retry(String messageId) async {
    final conv = _ref.read(activeConversationProvider);
    if (conv == null) return;
    final convId = conv.id;

    final failedMsg = conv.messages.firstWhere(
      (m) => m.id == messageId && m.status == 'failed',
      orElse: () => throw Exception('消息不存在或状态不正确'),
    );

    _ref.read(sendingProvider.notifier).state = true;
    _ref.read(errorProvider.notifier).state = null;

    await _ref.read(conversationsProvider.notifier).updateOne(convId, (c) => c.copyWith(
      messages: c.messages.map((m) => m.id == messageId ? m.copyWith(status: 'sending') : m).toList(),
    ));

    try {
      final settings = await _ref.read(appSettingsProvider.future);
      final msgIndex = conv.messages.indexWhere((m) => m.id == messageId);
      final history = msgIndex > 0 ? conv.messages.sublist(0, msgIndex + 1) : conv.messages;

      final config = await _sendService.prepareApiConfig(conv: conv, history: history, userText: failedMsg.displayText);
      final result = await _sendService.executeApiCall(config: config, sessionId: convId, userText: failedMsg.displayText);
      final buildResult = _sendService.buildAssistantMessages(apiResult: result, settings: settings);

      // 先标记原消息为成功
      await _ref.read(conversationsProvider.notifier).updateOne(convId, (c) => c.copyWith(
        messages: c.messages.map((m) => m.id == messageId ? m.copyWith(status: 'sent') : m).toList(),
      ));

      await _ttsHandler.deliverSegmentedMessages(
        convId: convId,
        userMsgId: messageId,
        buildResult: buildResult,
        replyText: result.replyText,
        pluginEvents: result.pluginEvents,
        ttsEnabled: settings.ttsEnabled,
      );
    } catch (e) {
      await _ref.read(conversationsProvider.notifier).updateOne(convId, (c) => c.copyWith(
        messages: c.messages.map((m) => m.id == messageId ? m.copyWith(status: 'failed') : m).toList(),
      ));
      _ref.read(errorProvider.notifier).state = e.toString();
    } finally {
      _ref.read(sendingProvider.notifier).state = false;
    }
  }

  /// 重新生成AI回复（删除指定AI消息及其后的所有消息，重新生成）
  Future<void> regenerate(String aiMessageId) async {
    final conv = _ref.read(activeConversationProvider);
    if (conv == null) return;
    final convId = conv.id;

    // 找到要重新生成的AI消息索引
    final msgIndex = conv.messages.indexWhere((m) => m.id == aiMessageId);
    if (msgIndex < 0) return;

    // 找到该AI消息对应的用户消息（通常是前一条）
    int userMsgIndex = msgIndex - 1;
    while (userMsgIndex >= 0 && conv.messages[userMsgIndex].role != 'user') {
      userMsgIndex--;
    }
    if (userMsgIndex < 0) return;

    final userMsg = conv.messages[userMsgIndex];
    final userText = userMsg.displayText;

    _ref.read(sendingProvider.notifier).state = true;
    _ref.read(errorProvider.notifier).state = null;

    // 删除AI消息及其后的所有消息，保留到用户消息
    await _ref.read(conversationsProvider.notifier).updateOne(convId, (c) => c.copyWith(
      messages: c.messages.sublist(0, userMsgIndex + 1),
    ));

    try {
      final settings = await _ref.read(appSettingsProvider.future);
      final updatedConv = _ref.read(activeConversationProvider)!;
      final history = _sendService.prepareHistory(conv: updatedConv, userMsg: userMsg, limit: settings.historyMessageLimit);
      final config = await _sendService.prepareApiConfig(conv: updatedConv, history: history, userText: userText);
      final result = await _sendService.executeApiCall(config: config, sessionId: convId, userText: userText);
      final buildResult = _sendService.buildAssistantMessages(apiResult: result, settings: settings);

      await _ttsHandler.deliverSegmentedMessages(
        convId: convId,
        userMsgId: userMsg.id,
        buildResult: buildResult,
        replyText: result.replyText,
        pluginEvents: result.pluginEvents,
        ttsEnabled: settings.ttsEnabled,
      );
    } catch (e) {
      _ref.read(errorProvider.notifier).state = e.toString();
    } finally {
      _ref.read(sendingProvider.notifier).state = false;
      // 委托给 AnalyzerScheduler：5分钟无新消息后触发 AI 管家分析
      _ref.read(analyzerSchedulerProvider).scheduleAnalysis();
    }
  }

  /// 编辑消息：删除指定消息及其后的所有消息，返回被删除消息的文本用于填充输入框
  Future<String?> editMessage(String messageId) async {
    final conv = _ref.read(activeConversationProvider);
    if (conv == null) return null;
    final convId = conv.id;

    final msgIndex = conv.messages.indexWhere((m) => m.id == messageId);
    if (msgIndex < 0) return null;

    final msg = conv.messages[msgIndex];
    final text = msg.displayText;

    // 删除该消息及其后的所有消息
    await _ref.read(conversationsProvider.notifier).updateOne(convId, (c) {
      final newMessages = c.messages.sublist(0, msgIndex);
      final lastMsg = newMessages.isNotEmpty ? newMessages.last : null;
      return c.copyWith(
        messages: newMessages,
        lastMessage: lastMsg?.displayText ?? '',
        lastMessageTime: lastMsg?.createdAt ?? c.createdAt,
      );
    });

    return text;
  }

  /// 应用切后台时调用
  /// 委托给 AnalyzerScheduler 处理后台分析逻辑
  void onAppBackground() {
    _ref.read(analyzerSchedulerProvider).onAppBackground();
  }
}

final chatActionsProvider = Provider((ref) => ChatActions(ref));

/// 编辑消息时需要填充到输入框的文本（用于 Composer 监听）
final editingTextProvider = StateProvider<String?>((ref) => null);

/// 引用消息数据
class QuotedMessage {
  final String id;
  final String content;
  final bool isUser;

  const QuotedMessage({
    required this.id,
    required this.content,
    required this.isUser,
  });
}

/// 当前被引用的消息（用于 Composer 显示预览）
final quotedMessageProvider = StateProvider<QuotedMessage?>((ref) => null);
