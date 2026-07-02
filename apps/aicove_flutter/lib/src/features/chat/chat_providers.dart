/// 聊天相关的全局 Provider
///
/// 从 chat_actions.dart 提取的全局状态 Provider。
///
/// 更新记录：
/// - 2025-12-31: 从 chat_actions.dart 提取
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'domain/sort_mode.dart';
import 'conversation_providers.dart' show activeConversationProvider;

// ===== 发送状态 =====

/// 每个会话各自的发送状态（会话A和会话B互不影响）
final conversationSendingProvider =
    StateProvider.family<bool, String>((ref, conversationId) => false);

/// 当前激活会话的发送状态（兼容现有 UI：ref.watch(sendingProvider)）
final sendingProvider = Provider<bool>((ref) {
  final activeConversation = ref.watch(activeConversationProvider);
  if (activeConversation == null) return false;
  return ref.watch(conversationSendingProvider(activeConversation.id));
});

/// 聊天进度状态（用于 AppBar 标题显示详细阶段）
enum ChatStatus {
  /// 空闲，显示对话名称
  idle(''),

  /// AI 正在思考（等待 API 响应）
  thinking('对方思考中...'),

  /// 正在执行工具调用（通用）
  toolCalling('工具调用中...'),

  /// 正在生成图片（draw_image 工具）
  generatingImage('图片生成中...'),

  /// 正在生成语音（speak 工具或 TTS 合成）
  generatingVoice('语音生成中...'),

  /// 正在整理消息（构建 + 交付阶段）
  processingResponse('消息整理中...');

  final String label;
  const ChatStatus(this.label);
}

/// 聊天进度状态 Provider（保持全局）
final chatStatusProvider = StateProvider<ChatStatus>((ref) => ChatStatus.idle);

/// 错误信息（保持全局）
final errorProvider = StateProvider<String?>((ref) => null);

// ===== 侧边栏状态 =====

/// 侧边栏可见性
final sidebarVisibleProvider = StateProvider<bool>((ref) => true);

// ===== 联系人列表排序状态 =====
// 遵循 DRY 原则：将排序状态提升到 Provider，供 ContactsPage 和 SplitChatPage 共享
// 更新记录：
// - 2025-12-06: 从 ContactsPage/SplitChatPage 提取，消除状态重复

/// 排序模式 Provider
final sortModeProvider = StateProvider<SortMode>((ref) => SortMode.latest);

/// 升序/降序 Provider
final sortAscendingProvider = StateProvider<bool>((ref) => false);

// ===== 模型轮询通知 =====

/// 模型切换通知（轮询时 UI 层监听此 Provider 弹 toast）
/// 值为正在尝试的模型名称，null 表示无通知
final modelFailoverInfoProvider = StateProvider<String?>((ref) => null);

enum ModelFailoverDecision {
  retryCurrent,
  tryNext,
  cancel,
}

class ModelFailoverPromptRequest {
  const ModelFailoverPromptRequest({
    required this.requestId,
    required this.conversationId,
    required this.failedModelName,
    required this.nextModelName,
    required this.errorMessage,
  });

  final int requestId;
  final String conversationId;
  final String failedModelName;
  final String nextModelName;
  final String errorMessage;
}

class ModelFailoverPromptController
    extends Notifier<ModelFailoverPromptRequest?> {
  Completer<ModelFailoverDecision>? _pendingCompleter;
  int _requestSerial = 0;

  @override
  ModelFailoverPromptRequest? build() => null;

  Future<ModelFailoverDecision> request({
    required String conversationId,
    required String failedModelName,
    required String nextModelName,
    required String errorMessage,
  }) async {
    _resolve(ModelFailoverDecision.tryNext);

    final completer = Completer<ModelFailoverDecision>();
    _pendingCompleter = completer;
    state = ModelFailoverPromptRequest(
      requestId: ++_requestSerial,
      conversationId: conversationId,
      failedModelName: failedModelName,
      nextModelName: nextModelName,
      errorMessage: errorMessage,
    );

    final decision = await completer.future;
    if (identical(_pendingCompleter, completer)) {
      _pendingCompleter = null;
      state = null;
    }
    return decision;
  }

  void resolve(ModelFailoverDecision decision) {
    _resolve(decision);
  }

  void dismiss({
    ModelFailoverDecision defaultDecision = ModelFailoverDecision.tryNext,
  }) {
    _resolve(defaultDecision);
  }

  void _resolve(ModelFailoverDecision decision) {
    final completer = _pendingCompleter;
    if (completer == null || completer.isCompleted) {
      if (state != null) {
        state = null;
      }
      return;
    }
    completer.complete(decision);
    _pendingCompleter = null;
    state = null;
  }
}

final modelFailoverPromptProvider = NotifierProvider<
    ModelFailoverPromptController, ModelFailoverPromptRequest?>(
  ModelFailoverPromptController.new,
);
