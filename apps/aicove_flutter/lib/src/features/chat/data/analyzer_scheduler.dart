/// 分析调度器 - 管理上下文分析的定时触发逻辑
///
/// 职责：
/// - 管理5分钟无消息后触发分析
/// - 处理后台切换时的快速分析
/// - 防抖和冷却期管理
/// - 云端心跳同步
///
/// 遵循 DRY 原则：从 ChatActions 中提取的调度逻辑
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../conversation_providers.dart';
import '../data/context_analyzer.dart';
import '../services/chat_history_store.dart';
import '../../settings/app_settings.dart';
import '../../../core/api/agent_api.dart';
import '../../../core/app_logger.dart';

/// 分析调度器
class AnalyzerScheduler {
  AnalyzerScheduler(this._ref);

  final Ref _ref;

  // 触发器分析延迟定时器（5分钟无消息后触发）
  Timer? _analyzerDelayTimer;

  // 后台切换防抖相关
  Timer? _bgAnalyzerTimer;
  int _bgSwitchCount = 0;
  DateTime? _bgSwitchWindowStart;
  DateTime? _bgProcessingPausedUntil;

  // 配置常量
  static const Duration _defaultDelay = Duration(minutes: 5);
  static const Duration _backgroundDelay = Duration(seconds: 10);
  static const Duration _cooldownDuration = Duration(minutes: 10);
  static const int _maxSwitchesInWindow = 3;
  static const Duration _switchWindow = Duration(minutes: 5);

  /// 启动/重置触发器分析延迟定时器
  /// 每次用户发消息时调用，5分钟无新消息后才触发分析
  void scheduleAnalysis() {
    // 取消之前的定时器
    _analyzerDelayTimer?.cancel();
    _bgAnalyzerTimer?.cancel(); // 用户活跃时取消后台快速触发

    // 创建新的5分钟延迟定时器
    _analyzerDelayTimer = Timer(_defaultDelay, () {
      unawaited(_triggerAnalysis('5分钟无新消息'));
    });

    _log('analyzer:scheduled', {'delayMinutes': 5}, level: 'DEBUG');
  }

  /// 应用切后台时调用
  void onAppBackground() {
    final now = DateTime.now();

    // 1. 检查是否处于冷却期
    if (_bgProcessingPausedUntil != null) {
      if (now.isBefore(_bgProcessingPausedUntil!)) {
        _log('analyzer:background_skipped', {
          'reason': 'cooldown_active',
          'until': _bgProcessingPausedUntil.toString()
        }, level: 'WARN');
        return;
      } else {
        _bgProcessingPausedUntil = null;
        _bgSwitchCount = 0;
        _bgSwitchWindowStart = null;
      }
    }

    // 2. 更新计数窗口
    if (_bgSwitchWindowStart == null ||
        now.difference(_bgSwitchWindowStart!).inMinutes >= _switchWindow.inMinutes) {
      _bgSwitchWindowStart = now;
      _bgSwitchCount = 1;
    } else {
      _bgSwitchCount++;
    }

    // 3. 检查是否触发冷却
    if (_bgSwitchCount > _maxSwitchesInWindow) {
      _bgProcessingPausedUntil = now.add(_cooldownDuration);
      _log('analyzer:background_cooldown', {
        'reason': 'too_frequent',
        'count': _bgSwitchCount,
        'pauseMinutes': _cooldownDuration.inMinutes
      }, level: 'WARN');
      return;
    }

    // 4. 调度快速分析（10秒后）
    _analyzerDelayTimer?.cancel();
    _bgAnalyzerTimer?.cancel();

    _bgAnalyzerTimer = Timer(_backgroundDelay, () {
      unawaited(_triggerAnalysis('app_background'));
    });

    _log('analyzer:scheduled_fast', {'delaySeconds': _backgroundDelay.inSeconds}, level: 'DEBUG');

    // 5. 同步云端心跳（Fire and forget）
    _syncHeartbeat(now);
  }

  /// 触发分析
  Future<void> _triggerAnalysis(String reason) async {
    try {
      final conv = _ref.read(activeConversationProvider);
      if (conv == null) return;
      final messagesCount =
          await _ref.read(chatHistoryStoreProvider).loadMessageCount(conv.id);
      if (messagesCount <= 0) return;
      _log('analyzer:triggered', {
        'reason': reason,
        'messagesCount': messagesCount,
      });
      await _ref.read(contextAnalyzerProvider).analyzeAndSchedule(conv);
    } catch (e) {
      _log('analyzer:error', {'error': e.toString()}, level: 'ERROR');
    }
  }

  /// 同步云端心跳
  Future<void> _syncHeartbeat(DateTime timestamp) async {
    try {
      final settings = await _ref.read(appSettingsProvider.future);
      if (settings.backendApiKey.isNotEmpty) {
        final agent = AgentApiClient();
        await agent.syncTriggerHeartbeat(timestamp, token: settings.backendApiKey);
        _log('cloud:heartbeat_sent', {'timestamp': timestamp.toIso8601String()}, level: 'DEBUG');
      }
    } catch (e) {
      _log('cloud:heartbeat_failed', {'error': e.toString()}, level: 'WARN');
    }
  }

  /// 立即触发分析（延迟2秒，避免阻塞UI）
  void triggerDelayed() {
    Future.delayed(const Duration(seconds: 2), () {
      unawaited(_triggerAnalysis('immediate_delayed'));
    });
  }

  /// 取消所有定时器
  void cancel() {
    _analyzerDelayTimer?.cancel();
    _bgAnalyzerTimer?.cancel();
  }

  /// 日志辅助
  void _log(String name, Map<String, Object?> data, {String level = 'INFO'}) {
    final metadata = <String, dynamic>{};
    data.forEach((k, v) {
      if (v != null) metadata[k] = v;
    });

    switch (level.toUpperCase()) {
      case 'DEBUG':
        AppLogger.debug('AnalyzerScheduler', name, metadata: metadata);
        break;
      case 'WARN':
        AppLogger.warning('AnalyzerScheduler', name, metadata: metadata);
        break;
      case 'ERROR':
        AppLogger.error('AnalyzerScheduler', name, metadata: metadata);
        break;
      default:
        AppLogger.info('AnalyzerScheduler', name, metadata: metadata);
    }
  }
}

/// Provider 定义
final analyzerSchedulerProvider = Provider((ref) => AnalyzerScheduler(ref));
