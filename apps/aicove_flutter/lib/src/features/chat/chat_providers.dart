/// 聊天相关的全局 Provider
///
/// 从 chat_actions.dart 提取的全局状态 Provider。
///
/// 更新记录：
/// - 2025-12-31: 从 chat_actions.dart 提取
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart' show VoidCallback;
import 'package:aicove_agent_kernel/aicove_agent_kernel.dart' show KernelCancellation;
import '../../core/app_logger.dart';
import 'domain/sort_mode.dart';
import 'domain/message.dart';
import 'conversation_providers.dart' show activeConversationProvider;

/// 尚未确认发送的用户消息；各会话独立，确认前不写入聊天历史。
final stagedUserMessagesProvider = StateProvider.family<List<Message>, String>(
    (ref, convId) => const <Message>[]);

/// 会话清空或删除时递增，防止异步暂存（如读取文件）在清理后晚到回写。
final stagedMessagesResetEpochProvider =
    StateProvider.family<int, String>((ref, convId) => 0);

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

/// 每个会话正在执行的工具（如 `read · /tmp/a.json`），没有工具在跑时为 null。
final conversationToolActivityProvider =
    StateProvider.family<String?, String>((ref, conversationId) => null);

/// Agent 运行中排队的一条输入。插话等当前这批工具跑完就生效，排队等整轮
/// 结束才发；两者都不打断正在执行的工具。
class QueuedChatInput {
  const QueuedChatInput(this.text, {required this.steer});
  final String text;
  final bool steer;
}

/// 每个会话运行中排队的输入，按加入顺序；发出时插话优先。
final conversationQueuedInputsProvider =
    StateProvider.family<List<QueuedChatInput>, String>(
        (ref, conversationId) => const []);

/// 停止或失败后没发出去的排队输入，由输入框取回到草稿里。
final returnedQueuedInputsProvider =
    StateProvider.family<List<String>, String>(
        (ref, conversationId) => const []);

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

/// 主对话阶段与后台媒体任务分别记账，避免并发任务相互恢复旧状态。
final conversationChatStatusProvider = StateProvider.family<ChatStatus, String>(
    (ref, conversationId) => ChatStatus.idle);
final conversationVoiceTaskCountProvider =
    StateProvider.family<int, String>((ref, conversationId) => 0);
final conversationImageTaskCountProvider =
    StateProvider.family<int, String>((ref, conversationId) => 0);

final effectiveConversationChatStatusProvider =
    Provider.family<ChatStatus, String>((ref, conversationId) {
  final mainStatus = ref.watch(conversationChatStatusProvider(conversationId));
  if (mainStatus != ChatStatus.idle) return mainStatus;
  if (ref.watch(conversationVoiceTaskCountProvider(conversationId)) > 0) {
    return ChatStatus.generatingVoice;
  }
  if (ref.watch(conversationImageTaskCountProvider(conversationId)) > 0) {
    return ChatStatus.generatingImage;
  }
  return ChatStatus.idle;
});

/// 保留可写入口，切换会话时自动派生该会话的有效状态。
final chatStatusProvider = StateProvider<ChatStatus>((ref) {
  final activeConversation = ref.watch(activeConversationProvider);
  if (activeConversation == null) return ChatStatus.idle;
  return ref.watch(effectiveConversationChatStatusProvider(activeConversation.id));
});

void _syncActiveConversationChatStatus(Ref ref, String convId) {
  if (ref.read(activeConversationProvider)?.id != convId) return;
  ref.read(chatStatusProvider.notifier).state =
      ref.read(effectiveConversationChatStatusProvider(convId));
}

void setConversationMainChatStatus(Ref ref, String convId, ChatStatus status) {
  ref.read(conversationChatStatusProvider(convId).notifier).state = status;
  _syncActiveConversationChatStatus(ref, convId);
}

void beginConversationVoiceTask(Ref ref, String convId) {
  ref.read(conversationVoiceTaskCountProvider(convId).notifier).state++;
  _syncActiveConversationChatStatus(ref, convId);
}

void endConversationVoiceTask(Ref ref, String convId) {
  final count = ref.read(conversationVoiceTaskCountProvider(convId).notifier);
  if (count.state > 0) count.state--;
  _syncActiveConversationChatStatus(ref, convId);
}

void beginConversationImageTask(Ref ref, String convId) {
  ref.read(conversationImageTaskCountProvider(convId).notifier).state++;
  _syncActiveConversationChatStatus(ref, convId);
}

void endConversationImageTask(Ref ref, String convId) {
  final count = ref.read(conversationImageTaskCountProvider(convId).notifier);
  if (count.state > 0) count.state--;
  _syncActiveConversationChatStatus(ref, convId);
}

/// 错误和重试状态按会话保存。
final conversationErrorProvider =
    StateProvider.family<String?, String>((ref, conversationId) => null);

class ModelRetryStatus {
  const ModelRetryStatus({required this.attempt, required this.maxAttempts});
  final int attempt;
  final int maxAttempts;
}

final conversationRetryStatusProvider =
    StateProvider.family<ModelRetryStatus?, String>((ref, conversationId) => null);

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
    this.errorDetail,
    this.roundStartedAt,
    required this.failedAt,
  });

  final int requestId;
  final String conversationId;
  final String failedModelName;
  final String nextModelName;
  final String errorMessage;

  /// 完整异常文本（含堆栈），复制本轮报错日志时使用。
  final String? errorDetail;

  /// 本轮请求开始时间，用于截取本轮日志。
  final DateTime? roundStartedAt;
  final DateTime failedAt;
}

class ModelFailoverPromptController
    extends Notifier<Map<String, ModelFailoverPromptRequest>> {
  final _pending = <String, Completer<ModelFailoverDecision>>{};
  final _presenters = <String, int>{};
  int _requestSerial = 0;

  @override
  Map<String, ModelFailoverPromptRequest> build() {
    ref.onDispose(() {
      for (final completer in _pending.values) {
        if (!completer.isCompleted) completer.complete(ModelFailoverDecision.tryNext);
      }
      _pending.clear();
    });
    return const {};
  }

  VoidCallback attachPresenter(String conversationId) {
    _presenters.update(conversationId, (count) => count + 1, ifAbsent: () => 1);
    var attached = true;
    return () {
      if (!attached) return;
      attached = false;
      final count = _presenters[conversationId];
      if (count == null) return;
      if (count > 1) {
        _presenters[conversationId] = count - 1;
      } else {
        _presenters.remove(conversationId);
        dismiss(conversationId);
      }
    };
  }

  Future<ModelFailoverDecision> request({
    required String conversationId,
    required String failedModelName,
    required String nextModelName,
    required String errorMessage,
    String? errorDetail,
    DateTime? roundStartedAt,
    KernelCancellation? cancellation,
  }) async {
    if (cancellation?.isCancelled == true) return ModelFailoverDecision.cancel;
    dismiss(conversationId);
    if ((_presenters[conversationId] ?? 0) == 0) {
      AppLogger.info('ModelFailover', '没有界面等待确认，自动尝试下一个模型',
          metadata: {'conversationId': conversationId});
      return ModelFailoverDecision.tryNext;
    }
    final completer = Completer<ModelFailoverDecision>();
    final id = ++_requestSerial;
    _pending[conversationId] = completer;
    state = {...state, conversationId: ModelFailoverPromptRequest(
      requestId: id,
      conversationId: conversationId,
      failedModelName: failedModelName,
      nextModelName: nextModelName,
      errorMessage: errorMessage,
      errorDetail: errorDetail,
      roundStartedAt: roundStartedAt,
      failedAt: DateTime.now(),
    )};
    if (cancellation != null) {
      unawaited(cancellation.whenCancelled.then((_) {
        if (identical(_pending[conversationId], completer)) {
          resolve(conversationId, id, ModelFailoverDecision.cancel);
        }
      }));
    }
    return completer.future;
  }

  void resolve(String conversationId, int requestId, ModelFailoverDecision decision) {
    if (state[conversationId]?.requestId != requestId) return;
    dismiss(conversationId, defaultDecision: decision);
  }

  void dismiss(String conversationId, {
    ModelFailoverDecision defaultDecision = ModelFailoverDecision.tryNext,
  }) {
    final completer = _pending.remove(conversationId);
    if (state.containsKey(conversationId)) {
      state = Map.of(state)..remove(conversationId);
    }
    if (completer != null && !completer.isCompleted) completer.complete(defaultDecision);
  }
}

final modelFailoverPromptProvider = NotifierProvider<
    ModelFailoverPromptController, Map<String, ModelFailoverPromptRequest>>(
  ModelFailoverPromptController.new,
);

final modelFailoverPromptForProvider = Provider.family<ModelFailoverPromptRequest?, String>(
  (ref, conversationId) => ref.watch(modelFailoverPromptProvider.select((state) => state[conversationId])),
);
