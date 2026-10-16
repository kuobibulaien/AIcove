import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/voice_call_ports.dart';
import 'voice_call_archiver.dart';
import 'voice_call_controls.dart';
import 'voice_call_session.dart';

/// 正在进行的一通电话，生命周期独立于通话页（ADR0074）。
///
/// 通话视图、宽屏的标签栏和窄屏的悬浮窗都只是它的视图：切回聊天（[minimize]）
/// 时通话和话筒照常，聊天输入框打的字经 [sendText] 进通话，不进主对话；
/// 挂断后和语音一起存进同一条通话记录。
class ActiveVoiceCall extends ChangeNotifier implements VoiceCallControls {
  ActiveVoiceCall({
    required this.conversationId,
    required Future<VoiceCallSession> Function() createSession,
    required VoiceCallArchiver archiver,
    required String Function(Object error) describeError,
    void Function(String message)? log,
    VoidCallback? onFinished,
  }) : _createSession = createSession,
       _archiver = archiver,
       _describeError = describeError,
       _log = log ?? ((_) {}),
       _onFinished = onFinished;

  final String conversationId;
  final Future<VoiceCallSession> Function() _createSession;
  final VoiceCallArchiver _archiver;
  final String Function(Object error) _describeError;
  final void Function(String message) _log;
  final VoidCallback? _onFinished;

  VoiceCallSession? _session;
  final List<StreamSubscription<Object?>> _subs = [];
  final _clock = Stopwatch();
  Timer? _ticker;
  Future<void>? _finishing;

  /// 每秒走一次的通话时长，单独通知，免得计时带着整页重建。
  @override
  final ValueNotifier<Duration> elapsed = ValueNotifier(Duration.zero);

  @override
  VoiceCallPhase get phase => _phase;
  VoiceCallPhase _phase = VoiceCallPhase.connecting;

  /// 接通失败的原因，展示给用户。
  @override
  String? get error => _error;
  String? _error;

  /// 用户正在说的话（识别器支持中间结果时才有）。
  @override
  String get partial => _partial;
  String _partial = '';

  @override
  bool get muted => _muted;
  bool _muted = false;

  @override
  bool get speakerOff => _speakerOff;
  bool _speakerOff = false;

  /// 切回了聊天（宽屏是「聊天」标签，窄屏是悬浮窗），通话视图不显示。
  bool get minimized => _minimized;
  bool _minimized = false;

  /// 显示在桌面端独立的通话小窗里（宽屏拨出时决定，整通电话不变）；聊天页
  /// 不再显示通话视图和悬浮窗，只保留临时气泡和打字输入。
  bool get inWindow => _inWindow;
  bool _inWindow = false;

  void showInWindow() {
    if (_inWindow || ending) return;
    _inWindow = true;
    _minimized = true;
    notifyListeners();
  }

  /// 小窗没打开（插件出错等）：退回聊天页里的通话视图。
  void leaveWindow() {
    if (!_inWindow) return;
    _inWindow = false;
    _minimized = false;
    notifyListeners();
  }

  /// 用户主动挂断或通话自己结束，不再接受输入。
  @override
  bool get ending => _finishing != null;

  @override
  bool get connected =>
      _phase == VoiceCallPhase.listening ||
      _phase == VoiceCallPhase.thinking ||
      _phase == VoiceCallPhase.speaking;

  @override
  List<CallTurn> get transcript => _session?.transcript ?? _lastTranscript;

  /// 在聊天里删掉的句子：只是不再显示，通话记录和摘要照常包含它们。
  final Set<int> _hiddenTurns = {};

  bool isTurnHidden(int index) => _hiddenTurns.contains(index);

  void hideTurn(int index) {
    if (_hiddenTurns.add(index)) notifyListeners();
  }

  List<CallTurn> _lastTranscript = const [];

  /// 通话开始的时刻；聊天页按它把通话内容排在已有消息之后。
  final DateTime startedAt = DateTime.now();

  Future<void> connect() async {
    try {
      final session = await _createSession();
      if (ending) {
        await session.hangUp();
        return;
      }
      _session = session;
      session
        ..muted = _muted
        ..speakerOn = !_speakerOff;
      _subs
        ..add(session.phases.listen(_onPhase))
        ..add(session.transcriptChanges.listen((_) => notifyListeners()))
        ..add(
          session.partialTranscripts.listen((text) {
            _partial = text;
            notifyListeners();
          }),
        );
      await session.start();
      // 接通途中挂断：收尾由 hangUp 负责，这里不再启动计时。
      if (ending) return;
      _clock.start();
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        elapsed.value = _clock.elapsed;
      });
    } catch (e) {
      _log('通话接通失败：$e');
      _error = _describeError(e);
      _phase = VoiceCallPhase.ended;
      notifyListeners();
      unawaited(hangUp());
    }
  }

  void _onPhase(VoiceCallPhase phase) {
    _phase = phase;
    if (phase != VoiceCallPhase.listening) _partial = '';
    notifyListeners();
    // 识别出错等原因由会话自己挂断时，同样存档收尾。
    if (phase == VoiceCallPhase.ended) unawaited(hangUp());
  }

  @override
  void toggleMute() {
    _muted = !_muted;
    _session?.muted = _muted;
    notifyListeners();
  }

  @override
  void toggleSpeaker() {
    _speakerOff = !_speakerOff;
    _session?.speakerOn = !_speakerOff;
    notifyListeners();
  }

  /// 切回聊天，通话视图收起；话筒不变，说话和打字都进通话。
  void minimize() {
    if (ending || _minimized) return;
    _minimized = true;
    notifyListeners();
  }

  /// 回到通话视图。
  void restore() {
    if (!_minimized || _inWindow) return;
    _minimized = false;
    notifyListeners();
  }

  /// 打字输入的一句。返回 false 表示通话还没接通或已结束，调用方保留草稿。
  bool sendText(String text) {
    if (ending) return false;
    return _session?.sendText(text) ?? false;
  }

  /// 挂断并存档；重复调用返回同一次收尾。
  @override
  Future<void> hangUp() => _finishing ??= _finish();

  Future<void> _finish() async {
    notifyListeners();
    _ticker?.cancel();
    _clock.stop();
    final session = _session;
    if (session != null) {
      for (final sub in _subs) {
        await sub.cancel();
      }
      _subs.clear();
      try {
        await session.hangUp();
      } catch (e) {
        _log('挂断出错：$e');
      }
      _lastTranscript = session.transcript;
      _phase = VoiceCallPhase.ended;
      notifyListeners();
      try {
        await _archiver.archive(
          conversationId: conversationId,
          connectedAt: session.connectedAt,
          turns: session.transcript,
        );
      } catch (e) {
        _log('通话记录保存失败：$e');
      }
    } else {
      _phase = VoiceCallPhase.ended;
      notifyListeners();
    }
    // 气泡写进聊天之后再撤掉聊天页里的临时显示，中间不留空档。
    _onFinished?.call();
  }
}
