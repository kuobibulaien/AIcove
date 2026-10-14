import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/voice_call_ports.dart';
import 'voice_call_archiver.dart';
import 'voice_call_session.dart';

/// 正在进行的一通电话，生命周期独立于通话页（ADR0074）。
///
/// 通话页和聊天页的悬浮窗都只是它的视图：页面收起成悬浮窗时通话继续，
/// 用户改在聊天输入框打字（[minimize]），打的字经 [sendText] 进通话，
/// 不进主对话；挂断后和语音一起存进同一条通话记录。
class ActiveVoiceCall extends ChangeNotifier {
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
  final ValueNotifier<Duration> elapsed = ValueNotifier(Duration.zero);

  VoiceCallPhase get phase => _phase;
  VoiceCallPhase _phase = VoiceCallPhase.connecting;

  /// 接通失败的原因，展示给用户。
  String? get error => _error;
  String? _error;

  /// 用户正在说的话（识别器支持中间结果时才有）。
  String get partial => _partial;
  String _partial = '';

  bool get muted => _muted;
  bool _muted = false;

  bool get speakerOff => _speakerOff;
  bool _speakerOff = false;

  /// 收起成悬浮窗、改用打字输入；话筒同时暂停。
  bool get minimized => _minimized;
  bool _minimized = false;

  /// 用户主动挂断或通话自己结束，不再接受输入。
  bool get ending => _finishing != null;

  bool get connected =>
      _phase == VoiceCallPhase.listening ||
      _phase == VoiceCallPhase.thinking ||
      _phase == VoiceCallPhase.speaking;

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
        ..typing = _minimized
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

  void toggleMute() {
    _muted = !_muted;
    _session?.muted = _muted;
    notifyListeners();
  }

  void toggleSpeaker() {
    _speakerOff = !_speakerOff;
    _session?.speakerOn = !_speakerOff;
    notifyListeners();
  }

  /// 收起成悬浮窗：输入从语音换成打字，话筒暂停。
  void minimize() {
    if (ending || _minimized) return;
    _minimized = true;
    _session?.typing = true;
    _partial = '';
    notifyListeners();
  }

  /// 回到通话页：输入换回语音，话筒恢复用户原来的开关。
  void restore() {
    if (!_minimized) return;
    _minimized = false;
    _session?.typing = false;
    notifyListeners();
  }

  /// 打字输入的一句。返回 false 表示通话还没接通或已结束，调用方保留草稿。
  bool sendText(String text) {
    if (ending) return false;
    return _session?.sendText(text) ?? false;
  }

  /// 挂断并存档；重复调用返回同一次收尾。
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
