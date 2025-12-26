import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/app_logger.dart';
import '../../plugins/plugin_providers.dart';
import '../../plugins/trigger/trigger_plugin.dart';
import '../../plugins/memory/memory_plugin.dart';
import '../providers2.dart';

/// 会话管理器
/// 负责监听用户活动和 App 生命周期，决定何时触发“管家 AI”进行整理。
final sessionManagerProvider = Provider<SessionManager>((ref) {
  final manager = SessionManager(ref);
  ref.onDispose(() => manager.dispose());
  return manager;
});

class SessionManager {
  final Ref _ref;
  Timer? _inactivityTimer;
  AppLifecycleListener? _lifecycleListener;
  
  // 5分钟无操作视为挂机
  static const Duration _inactivityTimeout = Duration(minutes: 5);

  SessionManager(this._ref) {
    _init();
  }

  void _init() {
    AppLogger.info('SessionManager', 'Initializing session manager...');
    
    // 1. 监听 App 生命周期 (后台结算机制)
    _lifecycleListener = AppLifecycleListener(
      onStateChange: _onLifecycleChanged,
    );

    // 2. 监听用户消息活动 (前台计时机制)
    // 监听 activeConversationProvider，当消息列表变化时重置计时器
    _ref.listen(activeConversationProvider, (previous, next) {
      if (next == null) return;
      
      // 如果是新会话，或者消息数量增加了
      final prevLen = previous?.messages.length ?? 0;
      final nextLen = next.messages.length;
      
      if (nextLen > prevLen) {
        final lastMsg = next.messages.last;
        // 只有用户发的消息才重置计时器 (避免 AI 回复触发重置)
        if (lastMsg.role == 'user') {
          _resetInactivityTimer();
        }
      }
    });
    
    // 初始化启动计时器
    _resetInactivityTimer();
  }

  void dispose() {
    _inactivityTimer?.cancel();
    _lifecycleListener?.dispose();
  }

  /// 重置前台挂机计时器
  void _resetInactivityTimer() {
    _inactivityTimer?.cancel();
    AppLogger.debug('SessionManager', 'User active. Timer reset.');
    
    _inactivityTimer = Timer(_inactivityTimeout, () {
      AppLogger.info('SessionManager', 'User inactive for 5 mins. Triggering session summary & poke.');
      _handleSessionEnd(isForegroundTimeout: true);
    });
  }

  /// 处理生命周期变化
  void _onLifecycleChanged(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      AppLogger.info('SessionManager', 'App paused. Triggering immediate session summary.');
      // 取消前台计时器，因为已经进入后台结算流程
      _inactivityTimer?.cancel();
      _handleSessionEnd(isForegroundTimeout: false);
    } else if (state == AppLifecycleState.resumed) {
      AppLogger.info('SessionManager', 'App resumed. Restarting timer.');
      _resetInactivityTimer();
    }
  }

  /// 处理会话结束逻辑 (核心)
  /// 
  /// 会话结束时执行：
  /// 1. MemoryPlugin: 记忆摘要（提取对话中的关键事实）
  /// 2. TriggerPlugin: 分析是否需要创建定时提醒
  /// 3. 前台挂机时: 触发主动消息
  Future<void> _handleSessionEnd({required bool isForegroundTimeout}) async {
    final pluginManager = _ref.read(pluginManagerProvider);
    
    // === 1. 记忆摘要 (Memory Track) ===
    final memoryPlugin = pluginManager.getPlugin('memory') as MemoryPlugin?;

    if (memoryPlugin != null && memoryPlugin.enabled) {
      AppLogger.info('SessionManager', 'Starting Memory Track summarization...');
      // 异步执行，不阻塞其他流程
      unawaited(memoryPlugin.onSessionEnd());
    } else {
      AppLogger.debug('SessionManager', 'MemoryPlugin not found or disabled.');
    }

    // === 2. 触发器分析 (Logic Track) ===
    final triggerPlugin = pluginManager.getPlugin('trigger') as TriggerPlugin?;

    if (triggerPlugin != null && triggerPlugin.enabled) {
      AppLogger.info('SessionManager', 'Starting Logic Track analysis...');
      // TODO: 调用 TriggerPlugin 的 analyzeSession 方法
      // await triggerPlugin.analyzeSession(); 
    } else {
      AppLogger.debug('SessionManager', 'TriggerPlugin not found or disabled.');
    }

    // === 3. 主动消息 (Chat Track) ===
    if (isForegroundTimeout) {
      AppLogger.info('SessionManager', 'Starting Chat Track proactive poke...');
      // TODO: 调用 ChatActions 发送主动消息
      // _ref.read(chatActionsProvider).sendProactivePoke();
    }
  }
}
