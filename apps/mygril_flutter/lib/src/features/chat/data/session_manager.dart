import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/app_logger.dart';
import '../../plugins/plugin_providers.dart';
import '../../plugins/trigger/trigger_plugin.dart';
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
  Future<void> _handleSessionEnd({required bool isForegroundTimeout}) async {
    final pluginManager = _ref.read(pluginManagerProvider);
    // 找到 TriggerPlugin
    // 注意：这里假设 TriggerPlugin 已经注册且是 TriggerPlugin 类型
    // 实际项目中可能需要更安全的查找方式
    final triggerPlugin = pluginManager.plugins.firstWhere(
      (p) => p is TriggerPlugin, 
      orElse: () => null as dynamic // 临时处理，后续 TriggerPlugin 重构后会更安全
    ) as TriggerPlugin?;

    if (triggerPlugin == null || !triggerPlugin.enabled) {
      AppLogger.warning('SessionManager', 'TriggerPlugin not found or disabled.');
      return;
    }

    // 1. 调用管家 AI 进行整理 (Logic Track)
    // 无论前台后台，都要整理
    AppLogger.info('SessionManager', 'Starting Logic Track analysis...');
    // TODO: 这里调用 TriggerPlugin 的新方法 analyzeSession
    // 由于 TriggerPlugin 还没重构，这里先注释，等下一步实现
    // await triggerPlugin.analyzeSession(); 

    // 2. 如果是前台挂机，触发“女友 AI”的主动骚扰 (Chat Track)
    if (isForegroundTimeout) {
      AppLogger.info('SessionManager', 'Starting Chat Track proactive poke...');
      // TODO: 调用 ChatActions 发送主动消息
      // _ref.read(chatActionsProvider).sendProactivePoke();
    }
  }
}
