import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/app_logger.dart';
import '../../plugins/plugin_providers.dart';
import '../../plugins/trigger/trigger_plugin.dart';
import '../../plugins/memory/memory_plugin.dart';
import '../providers2.dart';

/// 浼氳瘽绠＄悊鍣?
/// 璐熻矗鐩戝惉鐢ㄦ埛娲诲姩鍜?App 鐢熷懡鍛ㄦ湡锛屽喅瀹氫綍鏃惰Е鍙戔€滅瀹?AI鈥濊繘琛屾暣鐞嗐€?
final sessionManagerProvider = Provider<SessionManager>((ref) {
  final manager = SessionManager(ref);
  ref.onDispose(() => manager.dispose());
  return manager;
});

class SessionManager {
  final Ref _ref;
  Timer? _inactivityTimer;
  AppLifecycleListener? _lifecycleListener;

  // 5鍒嗛挓鏃犳搷浣滆涓烘寕鏈?
  static const Duration _inactivityTimeout = Duration(minutes: 5);

  SessionManager(this._ref) {
    _init();
  }

  void _init() {
    AppLogger.info('SessionManager', 'Initializing session manager...');

    // 1. 鐩戝惉 App 鐢熷懡鍛ㄦ湡 (鍚庡彴缁撶畻鏈哄埗)
    _lifecycleListener = AppLifecycleListener(
      onStateChange: _onLifecycleChanged,
    );

    // 2. 鐩戝惉鐢ㄦ埛娑堟伅娲诲姩 (鍓嶅彴璁℃椂鏈哄埗)
    // 鐩戝惉 activeConversationProvider锛屽綋娑堟伅鍒楄〃鍙樺寲鏃堕噸缃鏃跺櫒
    _ref.listen(activeConversationProvider, (previous, next) {
      if (next == null) return;

      // 濡傛灉鏄柊浼氳瘽锛屾垨鑰呮秷鎭暟閲忓鍔犱簡
      final prevLen = previous?.messages.length ?? 0;
      final nextLen = next.messages.length;

      if (nextLen > prevLen) {
        final lastMsg = next.messages.last;
        // 鍙湁鐢ㄦ埛鍙戠殑娑堟伅鎵嶉噸缃鏃跺櫒 (閬垮厤 AI 鍥炲瑙﹀彂閲嶇疆)
        if (lastMsg.role == 'user') {
          _resetInactivityTimer();
        }
      }
    });

    // 鍒濆鍖栧惎鍔ㄨ鏃跺櫒
    _resetInactivityTimer();
  }

  void dispose() {
    _inactivityTimer?.cancel();
    _lifecycleListener?.dispose();
  }

  /// 閲嶇疆鍓嶅彴鎸傛満璁℃椂鍣?
  void _resetInactivityTimer() {
    _inactivityTimer?.cancel();
    AppLogger.debug('SessionManager', 'User active. Timer reset.');

    _inactivityTimer = Timer(_inactivityTimeout, () {
      AppLogger.info('SessionManager',
          'User inactive for 5 mins. Triggering session summary & poke.');
      _handleSessionEnd(isForegroundTimeout: true);
    });
  }

  /// 澶勭悊鐢熷懡鍛ㄦ湡鍙樺寲
  void _onLifecycleChanged(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      AppLogger.info('SessionManager',
          'App paused. Triggering immediate session summary.');
      // 鍙栨秷鍓嶅彴璁℃椂鍣紝鍥犱负宸茬粡杩涘叆鍚庡彴缁撶畻娴佺▼
      _inactivityTimer?.cancel();
      _handleSessionEnd(isForegroundTimeout: false);
    } else if (state == AppLifecycleState.resumed) {
      AppLogger.info('SessionManager', 'App resumed. Restarting timer.');
      _resetInactivityTimer();
    }
  }

  /// 澶勭悊浼氳瘽缁撴潫閫昏緫 (鏍稿績)
  ///
  /// 浼氳瘽缁撴潫鏃舵墽琛岋細
  /// 1. MemoryPlugin: 璁板繂鎽樿锛堟彁鍙栧璇濅腑鐨勫叧閿簨瀹烇級
  /// 2. TriggerPlugin: 鍒嗘瀽鏄惁闇€瑕佸垱寤哄畾鏃舵彁閱?
  /// 3. 鍓嶅彴鎸傛満鏃? 瑙﹀彂涓诲姩娑堟伅
  Future<void> _handleSessionEnd({required bool isForegroundTimeout}) async {
    final pluginManager = _ref.read(pluginManagerProvider);
    // 记忆总结已改为次日首条消息触发，这里不再执行 SessionEnd 总结。
    final memoryPlugin = pluginManager.getPlugin('memory') as MemoryPlugin?;
    if (memoryPlugin != null && memoryPlugin.enabled) {
      AppLogger.debug('SessionManager',
          'Memory summarization is handled by next-day trigger.');
    }

    // === 2. 瑙﹀彂鍣ㄥ垎鏋?(Logic Track) ===
    final triggerPlugin = pluginManager.getPlugin('trigger') as TriggerPlugin?;

    if (triggerPlugin != null && triggerPlugin.enabled) {
      AppLogger.info('SessionManager', 'Starting Logic Track analysis...');
      // TODO: 璋冪敤 TriggerPlugin 鐨?analyzeSession 鏂规硶
      // await triggerPlugin.analyzeSession();
    } else {
      AppLogger.debug('SessionManager', 'TriggerPlugin not found or disabled.');
    }

    // === 3. 涓诲姩娑堟伅 (Chat Track) ===
    if (isForegroundTimeout) {
      AppLogger.info('SessionManager', 'Starting Chat Track proactive poke...');
      // TODO: 璋冪敤 ChatActions 鍙戦€佷富鍔ㄦ秷鎭?
      // _ref.read(chatActionsProvider).sendProactivePoke();
    }
  }
}
