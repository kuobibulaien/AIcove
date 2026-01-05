/// 聊天动作入口（门面类）
/// 
/// 作为各聊天服务的协调层，提供简洁的公开 API。
/// 实际逻辑已拆分到以下服务：
/// - ChatSendService: 消息发送
/// - ChatTtsHandler: TTS 处理与消息交付
/// - ChatMessageProcessor: 消息处理
/// 
/// 更新记录：
/// - 2025-12-31: 重构为门面模式，进一步提取 TTS 处理
library;

import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/context_analyzer.dart';
import 'data/auto_reply_trigger.dart';
import 'services/chat_send_service.dart';
import 'services/chat_tts_handler.dart';
import '../settings/app_settings.dart';
import 'conversation_providers.dart';
import 'chat_providers.dart';
import '../../core/app_logger.dart';

// 重新导出公共类型，保持向后兼容
export 'chat_providers.dart';
export 'services/chat_types.dart';
export 'services/chat_send_service.dart' show ChatSendService, ApiCallResult, ApiConfig, SendRequest;
export 'services/chat_tts_handler.dart' show ChatTtsHandler;

class ChatActions {
  ChatActions(this._ref)
      : _sendService = _ref.read(chatSendServiceProvider),
        _ttsHandler = _ref.read(chatTtsHandlerProvider);

  final Ref _ref;
  final ChatSendService _sendService;
  final ChatTtsHandler _ttsHandler;
  
  // 后台分析状态
  Timer? _analyzerDelayTimer;
  Timer? _bgAnalyzerTimer;
  int _bgSwitchCount = 0;
  DateTime? _bgSwitchWindowStart;
  DateTime? _bgProcessingPausedUntil;

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

    String? placeholderId;

    try {
      final settings = await _ref.read(appSettingsProvider.future);
      final history = _sendService.prepareHistory(conv: conv, userMsg: userMsg, limit: settings.historyMessageLimit);
      final config = await _sendService.prepareApiConfig(conv: conv, history: history, userText: text, trace: trace);
      final result = await _sendService.executeApiCall(config: config, sessionId: convId, userText: text, trace: trace);
      final messages = _sendService.buildAssistantMessages(apiResult: result, settings: settings);

      final delivery = await _ttsHandler.prepareAssistantDelivery(
        convId: convId,
        fallbackMessages: messages,
        replyText: result.replyText,
        pluginEvents: result.pluginEvents,
        ttsEnabled: settings.ttsEnabled,
      );
      placeholderId = delivery.placeholderId;

      await _sendService.deliverAssistantMessages(
        convId: convId,
        userMsgId: userMsg.id,
        messages: delivery.messages,
        lastMessagePreview: delivery.lastMessagePreview,
        trace: trace,
      );

      trace.end(additionalMessage: '完成');
      placeholderId = null;
    } catch (e) {
      if (placeholderId != null) await _ttsHandler.removePlaceholderMessage(convId, placeholderId);
      trace.error('失败', metadata: {'error': e.toString()});
      trace.end(additionalMessage: '失败');
      await _sendService.markUserMessageFailed(convId: convId, userMsgId: userMsg.id);
      _ref.read(errorProvider.notifier).state = e.toString();
    } finally {
      _ref.read(sendingProvider.notifier).state = false;
      _scheduleContextAnalysis();
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

    String? placeholderId;

    try {
      final settings = await _ref.read(appSettingsProvider.future);
      final history = _sendService.prepareHistory(conv: conv, userMsg: userMsg, limit: settings.historyMessageLimit);
      final config = await _sendService.prepareApiConfig(conv: conv, history: history, userText: '[image]');
      final result = await _sendService.executeApiCall(config: config, sessionId: convId, userText: '[image]');
      final messages = _sendService.buildAssistantMessages(apiResult: result, settings: settings);

      final delivery = await _ttsHandler.prepareAssistantDelivery(
        convId: convId,
        fallbackMessages: messages,
        replyText: result.replyText,
        pluginEvents: result.pluginEvents,
        ttsEnabled: settings.ttsEnabled,
      );
      placeholderId = delivery.placeholderId;

      await _sendService.deliverAssistantMessages(
        convId: convId,
        userMsgId: userMsg.id,
        messages: delivery.messages,
        lastMessagePreview: delivery.lastMessagePreview,
      );

      placeholderId = null;
    } catch (e) {
      if (placeholderId != null) await _ttsHandler.removePlaceholderMessage(convId, placeholderId);
      await _sendService.markUserMessageFailed(convId: convId, userMsgId: userMsg.id);
      _ref.read(errorProvider.notifier).state = e.toString();
    } finally {
      _ref.read(sendingProvider.notifier).state = false;
    }
  }

  /// 主动触发器发送
  Future<void> sendProactiveTrigger(AutoReplyTrigger trigger) async {
    final conv = _ref.read(activeConversationProvider);
    if (conv == null) return;
    final convId = conv.id;

    _ref.read(sendingProvider.notifier).state = true;
    _ref.read(errorProvider.notifier).state = null;

    String? placeholderId;

    try {
      final settings = await _ref.read(appSettingsProvider.future);
      final config = await _sendService.prepareApiConfig(conv: conv, history: conv.messages, userText: trigger.title);
      final result = await _sendService.executeApiCall(config: config, sessionId: convId, userText: trigger.title);
      final messages = _sendService.buildAssistantMessages(apiResult: result, settings: settings);

      final delivery = await _ttsHandler.prepareAssistantDelivery(
        convId: convId,
        fallbackMessages: messages,
        replyText: result.replyText,
        pluginEvents: result.pluginEvents,
        ttsEnabled: settings.ttsEnabled,
      );
      placeholderId = delivery.placeholderId;

      final now = DateTime.now();
      await _ref.read(conversationsProvider.notifier).updateOne(convId, (c) => c.copyWith(
        messages: [...c.messages, ...delivery.messages],
        updatedAt: now,
        lastMessage: delivery.lastMessagePreview,
        lastMessageTime: now,
      ));

      placeholderId = null;
    } catch (e) {
      if (placeholderId != null) await _ttsHandler.removePlaceholderMessage(convId, placeholderId);
      _ref.read(errorProvider.notifier).state = e.toString();
    } finally {
      _ref.read(sendingProvider.notifier).state = false;
    }
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

    String? placeholderId;

    try {
      final settings = await _ref.read(appSettingsProvider.future);
      final msgIndex = conv.messages.indexWhere((m) => m.id == messageId);
      final history = msgIndex > 0 ? conv.messages.sublist(0, msgIndex + 1) : conv.messages;

      final config = await _sendService.prepareApiConfig(conv: conv, history: history, userText: failedMsg.displayText);
      final result = await _sendService.executeApiCall(config: config, sessionId: convId, userText: failedMsg.displayText);
      final messages = _sendService.buildAssistantMessages(apiResult: result, settings: settings);

      final delivery = await _ttsHandler.prepareAssistantDelivery(
        convId: convId,
        fallbackMessages: messages,
        replyText: result.replyText,
        pluginEvents: result.pluginEvents,
        ttsEnabled: settings.ttsEnabled,
      );
      placeholderId = delivery.placeholderId;

      final now = DateTime.now();
      await _ref.read(conversationsProvider.notifier).updateOne(convId, (c) {
        final updated = c.messages.map((m) => m.id == messageId ? m.copyWith(status: 'sent') : m).toList();
        return c.copyWith(
          messages: [...updated, ...delivery.messages],
          updatedAt: now,
          lastMessage: delivery.lastMessagePreview,
          lastMessageTime: now,
        );
      });

      placeholderId = null;
    } catch (e) {
      if (placeholderId != null) await _ttsHandler.removePlaceholderMessage(convId, placeholderId);
      await _ref.read(conversationsProvider.notifier).updateOne(convId, (c) => c.copyWith(
        messages: c.messages.map((m) => m.id == messageId ? m.copyWith(status: 'failed') : m).toList(),
      ));
      _ref.read(errorProvider.notifier).state = e.toString();
    } finally {
      _ref.read(sendingProvider.notifier).state = false;
    }
  }

  /// 应用切后台时调用
  void onAppBackground() {
    final now = DateTime.now();
    if (_bgProcessingPausedUntil != null && now.isBefore(_bgProcessingPausedUntil!)) return;
    if (_bgSwitchWindowStart == null || now.difference(_bgSwitchWindowStart!).inMinutes >= 5) {
      _bgSwitchWindowStart = now;
      _bgSwitchCount = 1;
    } else {
      _bgSwitchCount++;
    }
    if (_bgSwitchCount > 3) {
      _bgProcessingPausedUntil = now.add(const Duration(minutes: 10));
      return;
    }
    _analyzerDelayTimer?.cancel();
    _bgAnalyzerTimer?.cancel();
    _bgAnalyzerTimer = Timer(const Duration(seconds: 10), () {
      try {
        final conv = _ref.read(activeConversationProvider);
        if (conv != null && conv.messages.isNotEmpty) {
          _ref.read(contextAnalyzerProvider).analyzeAndSchedule(conv);
        }
      } catch (_) {}
    });
  }

  void _scheduleContextAnalysis() {
    Future.delayed(const Duration(seconds: 2), () {
      try {
        final conv = _ref.read(activeConversationProvider);
        if (conv != null && conv.messages.isNotEmpty) {
          _ref.read(contextAnalyzerProvider).analyzeAndSchedule(conv);
        }
      } catch (_) {}
    });
  }
}

final chatActionsProvider = Provider((ref) => ChatActions(ref));
