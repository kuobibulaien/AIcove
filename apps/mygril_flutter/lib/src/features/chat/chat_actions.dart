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
import '../../core/database/database_provider.dart';

// 重新导出公共类型，保持向后兼容
export 'chat_providers.dart';
export 'services/chat_types.dart';
export 'services/chat_send_service.dart'
    show ChatSendService, ApiCallResult, ApiConfig, SendRequest;
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

  /// 发送文本消息（支持自动轮询多个默认聊天模型）
  Future<void> send(String text) async {
    final conv = _ref.read(activeConversationProvider);
    if (conv == null || text.trim().isEmpty) return;
    final convId = conv.id;

    final trace = AppLogger.startTrace('AI消息发送', source: 'ChatActions');
    _ref.read(sendingProvider.notifier).state = true;
    _ref.read(errorProvider.notifier).state = null;

    final userMsg = _sendService.createUserMessage(text: text, imagePath: null);
    await _sendService.addUserMessage(
        convId: convId, userMsg: userMsg, displayText: text);

    try {
      final settings = await _ref.read(appSettingsProvider.future);
      final history = _sendService.prepareHistory(
          conv: conv, userMsg: userMsg, limit: settings.historyMessageLimit);

      // 构建轮询模型列表：defaultChatModels > defaultModelName
      final modelsToTry = settings.defaultChatModels.isNotEmpty
          ? settings.defaultChatModels
          : [settings.defaultModelName];

      final (result, usedSettings) = await _executeWithFailover(
        modelsToTry: modelsToTry,
        buildConfig: (model) => _sendService.prepareApiConfig(
          conv: conv,
          history: history,
          userText: text,
          trace: trace,
          overrideModel: model,
        ),
        execute: (config) => _sendService.executeApiCall(
          config: config,
          sessionId: convId,
          userText: text,
          turnId: userMsg.id,
          trace: trace,
        ),
        settings: settings,
      );

      final buildResult = _sendService.buildAssistantMessages(
          apiResult: result, settings: usedSettings);

      // 统一的消息交付入口：自动处理 TTS 分段发送
      await _ttsHandler.deliverSegmentedMessages(
        convId: convId,
        userMsgId: userMsg.id,
        buildResult: buildResult,
        replyText: result.replyText,
        pluginEvents: result.pluginEvents,
        ttsEnabled: usedSettings.ttsEnabled,
        trace: trace,
      );

      trace.end(additionalMessage: '完成');
    } catch (e) {
      trace.error('失败', metadata: {'error': e.toString()});
      trace.end(additionalMessage: '失败');
      await _sendService.markUserMessageFailed(
          convId: convId, userMsgId: userMsg.id);
      _ref.read(errorProvider.notifier).state = e.toString();
    } finally {
      _ref.read(sendingProvider.notifier).state = false;
      _ref.read(modelFailoverInfoProvider.notifier).state = null;
      // 委托给 AnalyzerScheduler：5分钟无新消息后触发 AI 管家分析
      _ref.read(analyzerSchedulerProvider).scheduleAnalysis();
    }
  }

  /// 发送图片消息（可附带文字说明，支持图片识别模型 + 轮询）
  Future<void> sendWithImage(String imagePath, {String? text}) async {
    final conv = _ref.read(activeConversationProvider);
    if (conv == null || imagePath.trim().isEmpty) return;
    final convId = conv.id;

    _ref.read(sendingProvider.notifier).state = true;
    _ref.read(errorProvider.notifier).state = null;

    final userText = text?.trim();
    final hasText = userText != null && userText.isNotEmpty;
    final userMsg = _sendService.createUserMessage(
      text: hasText ? userText : null,
      imagePath: imagePath,
    );
    final displayText = hasText ? userText : '[图片]';
    await _sendService.addUserMessage(
        convId: convId, userMsg: userMsg, displayText: displayText);

    try {
      final settings = await _ref.read(appSettingsProvider.future);
      final history = _sendService.prepareHistory(
          conv: conv, userMsg: userMsg, limit: settings.historyMessageLimit);
      final apiText = hasText ? userText : '[image]';

      // 图片识别模型优先，然后 fallback 到聊天模型列表
      final modelsToTry = <String>[];
      if (settings.defaultVisionModel != null &&
          settings.defaultVisionModel!.isNotEmpty) {
        modelsToTry.add(settings.defaultVisionModel!);
      }
      if (settings.defaultChatModels.isNotEmpty) {
        for (final m in settings.defaultChatModels) {
          if (!modelsToTry.contains(m)) modelsToTry.add(m);
        }
      }
      if (modelsToTry.isEmpty) {
        modelsToTry.add(settings.defaultModelName);
      }

      final (result, usedSettings) = await _executeWithFailover(
        modelsToTry: modelsToTry,
        buildConfig: (model) => _sendService.prepareApiConfig(
          conv: conv,
          history: history,
          userText: apiText,
          overrideModel: model,
        ),
        execute: (config) => _sendService.executeApiCall(
          config: config,
          sessionId: convId,
          userText: apiText,
          turnId: userMsg.id,
        ),
        settings: settings,
      );

      final buildResult = _sendService.buildAssistantMessages(
          apiResult: result, settings: usedSettings);

      await _ttsHandler.deliverSegmentedMessages(
        convId: convId,
        userMsgId: userMsg.id,
        buildResult: buildResult,
        replyText: result.replyText,
        pluginEvents: result.pluginEvents,
        ttsEnabled: usedSettings.ttsEnabled,
      );
    } catch (e) {
      await _sendService.markUserMessageFailed(
          convId: convId, userMsgId: userMsg.id);
      _ref.read(errorProvider.notifier).state = e.toString();
    } finally {
      _ref.read(sendingProvider.notifier).state = false;
      _ref.read(modelFailoverInfoProvider.notifier).state = null;
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

    final userMsg =
        await _sendService.createUserFileMessage(filePath: filePath);
    await _sendService.addUserMessage(
        convId: convId, userMsg: userMsg, displayText: '[文件]');

    try {
      final settings = await _ref.read(appSettingsProvider.future);
      final history = _sendService.prepareHistory(
          conv: conv, userMsg: userMsg, limit: settings.historyMessageLimit);
      final config = await _sendService.prepareApiConfig(
          conv: conv, history: history, userText: '[file]');
      final result = await _sendService.executeApiCall(
          config: config,
          sessionId: convId,
          userText: '[file]',
          turnId: userMsg.id);
      final buildResult = _sendService.buildAssistantMessages(
          apiResult: result, settings: settings);

      await _ttsHandler.deliverSegmentedMessages(
        convId: convId,
        userMsgId: userMsg.id,
        buildResult: buildResult,
        replyText: result.replyText,
        pluginEvents: result.pluginEvents,
        ttsEnabled: settings.ttsEnabled,
      );
    } catch (e) {
      await _sendService.markUserMessageFailed(
          convId: convId, userMsgId: userMsg.id);
      _ref.read(errorProvider.notifier).state = e.toString();
    } finally {
      _ref.read(sendingProvider.notifier).state = false;
      _ref.read(analyzerSchedulerProvider).scheduleAnalysis();
    }
  }

  /// 主动触发器发送
  /// 注意：作废检查已在 AutoReplyTriggerController._pollDueTriggers() 中完成
  /// 此方法被调用时，触发器已确认可以触发
  Future<ProactiveSendResult> sendProactiveTrigger(
      AutoReplyTrigger trigger) async {
    final settings = await _ref.read(appSettingsProvider.future);
    if (!settings.autoReplySettings.enabled) {
      AppLogger.info(
          'ChatActions', 'Skip proactive trigger: auto-reply disabled',
          metadata: {
            'triggerId': trigger.id,
          });
      return const ProactiveSendResult.skipped('auto_reply_disabled');
    }

    // 确定目标会话：优先使用触发器绑定的会话，否则使用当前活跃会话
    final targetConvId = trigger.conversationId.isNotEmpty
        ? trigger.conversationId
        : _ref.read(activeConversationIdProvider);

    if (targetConvId == null || targetConvId.isEmpty) {
      AppLogger.warning('ChatActions', '触发器发送失败：无目标会话',
          metadata: {'triggerId': trigger.id});
      return const ProactiveSendResult.skipped('target_conversation_missing');
    }

    // 获取目标会话
    final conversations = _ref.read(conversationsProvider).valueOrNull ?? [];
    final conv = conversations.where((c) => c.id == targetConvId).firstOrNull;
    if (conv == null) {
      AppLogger.warning('ChatActions', '触发器发送失败：会话不存在',
          metadata: {'convId': targetConvId});
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
          final buildResult = _sendService.buildAssistantMessages(
              apiResult: cachedResult, settings: settings);
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
      final history =
          snapshotHistory.isNotEmpty ? snapshotHistory : conv.messages;
      final config = await _sendService.prepareApiConfig(
        conv: conv,
        history: history,
        userText: proactiveInput,
      );
      final result = await _sendService.executeApiCall(
        config: config,
        sessionId: targetConvId,
        userText: proactiveInput,
        turnId: 'trigger_${trigger.id}',
      );
      final buildResult = _sendService.buildAssistantMessages(
          apiResult: result, settings: settings);

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

    await _ref.read(conversationsProvider.notifier).updateOne(
        convId,
        (c) => c.copyWith(
              messages: c.messages
                  .map((m) =>
                      m.id == messageId ? m.copyWith(status: 'sending') : m)
                  .toList(),
            ));

    try {
      final settings = await _ref.read(appSettingsProvider.future);
      final msgIndex = conv.messages.indexWhere((m) => m.id == messageId);
      // 取重试消息及之前的历史，并过滤掉其他失败消息
      final rawHistory =
          msgIndex > 0 ? conv.messages.sublist(0, msgIndex + 1) : conv.messages;
      final history = rawHistory
          .where((m) => m.status != 'failed' || m.id == messageId)
          .toList();

      final config = await _sendService.prepareApiConfig(
          conv: conv, history: history, userText: failedMsg.displayText);
      final result = await _sendService.executeApiCall(
          config: config,
          sessionId: convId,
          userText: failedMsg.displayText,
          turnId: messageId);
      final buildResult = _sendService.buildAssistantMessages(
          apiResult: result, settings: settings);

      // 先标记原消息为成功
      await _ref.read(conversationsProvider.notifier).updateOne(
          convId,
          (c) => c.copyWith(
                messages: c.messages
                    .map((m) =>
                        m.id == messageId ? m.copyWith(status: 'sent') : m)
                    .toList(),
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
      await _ref.read(conversationsProvider.notifier).updateOne(
          convId,
          (c) => c.copyWith(
                messages: c.messages
                    .map((m) =>
                        m.id == messageId ? m.copyWith(status: 'failed') : m)
                    .toList(),
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

    // 收集被移除的消息 ID，用于数据库软删除
    final removedMessages = conv.messages.sublist(userMsgIndex + 1);

    // 删除AI消息及其后的所有消息，保留到用户消息
    await _ref.read(conversationsProvider.notifier).updateOne(
        convId,
        (c) => c.copyWith(
              messages: c.messages.sublist(0, userMsgIndex + 1),
            ));

    // 在数据库中软删除被移除的消息
    await _softDeleteMessages(removedMessages.map((m) => m.id).toList());

    try {
      final settings = await _ref.read(appSettingsProvider.future);
      final updatedConv = _ref.read(activeConversationProvider)!;
      final history = _sendService.prepareHistory(
          conv: updatedConv,
          userMsg: userMsg,
          limit: settings.historyMessageLimit);
      final config = await _sendService.prepareApiConfig(
          conv: updatedConv, history: history, userText: userText);
      final result = await _sendService.executeApiCall(
          config: config,
          sessionId: convId,
          userText: userText,
          turnId: userMsg.id);
      final buildResult = _sendService.buildAssistantMessages(
          apiResult: result, settings: settings);

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

  /// 撤回失败消息：将失败消息的文本回填到输入框，并从会话中删除该消息
  void recallFailedMessage(String messageId) {
    final conv = _ref.read(activeConversationProvider);
    if (conv == null) return;
    final convId = conv.id;

    final idx = conv.messages.indexWhere(
      (m) => m.id == messageId && m.status == 'failed',
    );
    if (idx < 0) return;
    final failedMsg = conv.messages[idx];

    // 将失败消息文本填入输入框
    final text = failedMsg.displayText;
    if (text.isNotEmpty) {
      _ref.read(editingTextProvider.notifier).state = text;
    }

    // 从会话中删除该失败消息
    _ref.read(conversationsProvider.notifier).updateOne(convId, (c) {
      final newMessages = c.messages.where((m) => m.id != messageId).toList();
      final lastMsg = newMessages.isNotEmpty ? newMessages.last : null;
      return c.copyWith(
        messages: newMessages,
        lastMessage: lastMsg?.displayText ?? '',
        lastMessageTime: lastMsg?.createdAt ?? c.createdAt,
      );
    });
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
    final removedMessages = conv.messages.sublist(msgIndex);
    await _ref.read(conversationsProvider.notifier).updateOne(convId, (c) {
      final newMessages = c.messages.sublist(0, msgIndex);
      final lastMsg = newMessages.isNotEmpty ? newMessages.last : null;
      return c.copyWith(
        messages: newMessages,
        lastMessage: lastMsg?.displayText ?? '',
        lastMessageTime: lastMsg?.createdAt ?? c.createdAt,
      );
    });

    // 在数据库中软删除被移除的消息
    await _softDeleteMessages(removedMessages.map((m) => m.id).toList());

    return text;
  }

  /// 应用切后台时调用
  /// 委托给 AnalyzerScheduler 处理后台分析逻辑
  void onAppBackground() {
    _ref.read(analyzerSchedulerProvider).onAppBackground();
  }

  // ===== 内部：模型轮询 =====

  /// 按模型列表顺序尝试发送，失败后自动切换下一个模型
  /// 返回 (API调用结果, 使用的设置)
  Future<(ApiCallResult, AppSettings)> _executeWithFailover({
    required List<String> modelsToTry,
    required Future<ApiConfig> Function(String model) buildConfig,
    required Future<ApiCallResult> Function(ApiConfig config) execute,
    required AppSettings settings,
  }) async {
    // 只有一个模型时，直接调用不做轮询
    if (modelsToTry.length <= 1) {
      final model = modelsToTry.isNotEmpty
          ? modelsToTry.first
          : settings.defaultModelName;
      final config = await buildConfig(model);
      final result = await execute(config);
      return (result, settings);
    }

    Object? lastError;
    for (var i = 0; i < modelsToTry.length; i++) {
      final model = modelsToTry[i];
      try {
        final config = await buildConfig(model);
        final result = await execute(config);
        // 成功，清除轮询通知
        _ref.read(modelFailoverInfoProvider.notifier).state = null;
        return (result, settings);
      } catch (e) {
        lastError = e;
        AppLogger.warning('ChatActions', '模型 $model 调用失败，尝试下一个', metadata: {
          'failedModel': model,
          'attempt': i + 1,
          'total': modelsToTry.length,
          'error': e.toString(),
        });

        // 还有下一个模型可以尝试
        if (i < modelsToTry.length - 1) {
          final nextModel = modelsToTry[i + 1];
          final displayName = settings.getModelDisplayName(nextModel);
          _ref.read(modelFailoverInfoProvider.notifier).state = displayName;
        }
      }
    }

    // 所有模型都失败了，抛出最后一个错误
    throw lastError!;
  }

  /// 在数据库中软删除指定的消息（及其内容块）
  Future<void> _softDeleteMessages(List<String> messageIds) async {
    if (messageIds.isEmpty) return;
    final msgRepo = _ref.read(messageRepositoryProvider);
    final now = DateTime.now().millisecondsSinceEpoch;
    final purgeAt = now + 30 * 24 * 60 * 60 * 1000; // 30天后物理清除
    for (final id in messageIds) {
      await msgRepo.softDelete(id, now, purgeAt);
    }
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
