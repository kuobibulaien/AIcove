import 'dart:async';
import 'dart:typed_data';

import '../domain/speech_recognizer_port.dart';
import '../domain/voice_call_ports.dart';
import 'call_reply_segmenter.dart';

enum VoiceCallPhase {
  /// 正在建立识别、合成与音频设备。
  connecting,

  /// 等用户说话。
  listening,

  /// 用户说完，等模型回复的第一段。
  thinking,

  /// 角色正在说话。
  speaking,

  ended,
}

/// 通话会话：识别 → 生成 → 切句 → 合成 → 播放，并处理打断（ADR0074）。
///
/// 只依赖端口，不碰数据库和界面；逐句记录在 [transcript]，由调用方在挂断后落库。
class VoiceCallSession {
  VoiceCallSession({
    required this.recognizer,
    required this.tts,
    required this.input,
    required this.output,
    required this.generator,
    this.allowBargeIn = false,
    this.greetOnConnect = true,
    this.segmentMinChars = 6,
    this.turnEndQuiet = const Duration(milliseconds: 1500),
    this.userTurnGap = const Duration(milliseconds: 600),
    this.synthesisTimeout = const Duration(seconds: 8),
    this.pollInterval = const Duration(milliseconds: 100),
    void Function(String message)? log,
  }) : _log = log ?? _noLog;

  static void _noLog(String _) {}

  final SpeechRecognizerPort recognizer;
  final StreamingTtsPort tts;
  final CallAudioInputPort input;
  final CallAudioOutputPort output;
  final CallReplyGeneratorPort generator;

  /// 允许用户开口打断角色。外放且没有回声消除时，角色自己的声音会被录进去，
  /// 导致自己打断自己，所以默认关闭：角色说话期间不把麦克风送去识别。
  final bool allowBargeIn;

  /// 接通后角色先开口说开场白（生成时轮次为空，提示词见回复生成器）。
  final bool greetOnConnect;
  final int segmentMinChars;

  /// 模型写完、最后一块音频送达后再静默这么久，判定本轮说完。
  final Duration turnEndQuiet;

  /// 识别器按短静音切段出结果，真人句中停顿常超过它；最后一段之后再静默
  /// 这么久才算用户这一轮说完，期间接着说的段拼成同一句。零表示立即提交。
  final Duration userTurnGap;

  /// 最后一段文字送去合成后一直没等到它之后的音频，超过这么久按合成失败收尾。
  final Duration synthesisTimeout;
  final Duration pollInterval;

  /// 关键节点诊断日志（阶段、识别结果、首字、首块音频、错误），不含音频内容。
  final void Function(String message) _log;

  final _phases = StreamController<VoiceCallPhase>.broadcast();
  final _partials = StreamController<String>.broadcast();
  final _turns = StreamController<void>.broadcast();
  final List<CallTurn> _transcript = [];
  final List<StreamSubscription<Object?>> _subscriptions = [];

  VoiceCallPhase _phase = VoiceCallPhase.connecting;
  bool _ending = false;
  Future<void>? _starting;
  Future<void>? _hangingUp;
  _ReplyTurn? _reply;
  Timer? _poll;
  final List<String> _pendingUser = [];
  Timer? _userTurnTimer;

  VoiceCallPhase get phase => _phase;
  Stream<VoiceCallPhase> get phases => _phases.stream;

  /// 用户正在说的话（识别器支持中间结果时才有）。
  Stream<String> get partialTranscripts => _partials.stream;

  List<CallTurn> get transcript => List.unmodifiable(_transcript);

  /// [transcript] 每多一句就通知一次。
  Stream<void> get transcriptChanges => _turns.stream;

  /// 接通时刻（识别、合成、麦克风都就绪）；没接通为 null。
  DateTime? get connectedAt => _connectedAt;
  DateTime? _connectedAt;

  /// 关掉话筒：麦克风照常采集，但不送去识别。
  bool muted = false;

  /// 打字模式：输入改由 [sendText] 提供，话筒暂停，不和语音同时输入。
  /// 与 [muted] 分开，回到语音时恢复用户原来的话筒开关。
  bool typing = false;

  /// 扬声器：关掉后角色的声音立刻无声，通话和字幕照常进行。
  bool get speakerOn => !output.silenced;
  set speakerOn(bool value) => output.silenced = !value;

  /// 只执行一次；挂断可能发生在接通途中，每一步之后都检查是否已在挂断。
  Future<void> start() => _starting ??= _start();

  Future<void> _start() async {
    final clock = Stopwatch()..start();
    await tts.open();
    if (_ending) return;
    _log('合成连接就绪 +${clock.elapsedMilliseconds}ms');
    await output.start(tts.sampleRate);
    if (_ending) return;
    await recognizer.start();
    if (_ending) return;
    _log('识别器就绪 +${clock.elapsedMilliseconds}ms');
    _subscriptions
      ..add(recognizer.events.listen(_onRecognition))
      ..add(tts.audio.listen(_onTtsAudio));
    final mic = await input.start();
    if (_ending) return;
    _subscriptions.add(mic.listen(_onMicAudio));
    _poll = Timer.periodic(pollInterval, (_) => _checkTurnEnd());
    _connectedAt = DateTime.now();
    _setPhase(VoiceCallPhase.listening);
    if (greetOnConnect) _startReply();
  }

  /// 挂断。正在说的那句按已播出部分记入记录；重复调用返回同一次挂断。
  Future<void> hangUp() => _hangingUp ??= _hangUp();

  Future<void> _hangUp() async {
    _ending = true;
    _poll?.cancel();
    _userTurnTimer?.cancel();
    // 接通还没走完时先等它停下，免得挂断后才建好的连接无人释放。
    try {
      await _starting;
    } catch (_) {}
    _poll?.cancel();
    await _abortReply(interrupted: true, hangingUp: true);
    // 已播进度算完就立刻停播，挂断后不再出声；不重建播放设备。
    await _release('关闭播放', output.stop);
    // 先停麦克风，再让识别器冲出最后一句；此时仍在订阅识别事件。
    await _release('停止麦克风', input.stop);
    await _release('识别收尾', recognizer.stop);
    await Future<void>.delayed(Duration.zero);
    // 挂断时还没提交的半句也记下来，只是不再回复。
    if (_pendingUser.isNotEmpty) {
      _addTurn(CallTurn(role: 'user', text: _joinPendingUser()));
      _pendingUser.clear();
    }
    _setPhase(VoiceCallPhase.ended);
    for (final sub in _subscriptions) {
      await _release('取消订阅', sub.cancel);
    }
    _subscriptions.clear();
    await _release('释放识别器', recognizer.dispose);
    await _release('关闭合成', tts.close);
    await _phases.close();
    await _partials.close();
    await _turns.close();
  }

  /// 每项资源单独释放，一项失败不影响其它项。
  Future<void> _release(String what, Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      _log('$what失败：$e');
    }
  }

  void _onMicAudio(Uint8List pcm) {
    _meterMic(pcm);
    final busy =
        _phase == VoiceCallPhase.thinking || _phase == VoiceCallPhase.speaking;
    if (muted || typing || (busy && !allowBargeIn)) return;
    recognizer.addAudio(pcm);
  }

  final _micClock = Stopwatch();
  int _micBytes = 0;
  int _micPeak = 0;

  /// 每 2 秒记一次麦克风收到的数据量与峰值，排查「没声音」还是「没检测到说话」。
  void _meterMic(Uint8List pcm) {
    if (!_micClock.isRunning) _micClock.start();
    _micBytes += pcm.length;
    final data = ByteData.sublistView(pcm);
    for (var i = 0; i + 1 < pcm.length; i += 2) {
      final v = data.getInt16(i, Endian.little).abs();
      if (v > _micPeak) _micPeak = v;
    }
    if (_micClock.elapsedMilliseconds < 2000) return;
    _log('麦克风 ${_micBytes ~/ 1024}KB 峰值 $_micPeak');
    _micClock.reset();
    _micBytes = 0;
    _micPeak = 0;
  }

  void _onRecognition(SpeechRecognitionEvent event) {
    switch (event) {
      case SpeechStarted():
        // 用户接着说：这一轮还没完。
        _userTurnTimer?.cancel();
        if (_reply != null && allowBargeIn) {
          unawaited(_abortReply(interrupted: true));
        }
      case SpeechPartial(:final text):
        _partials.add(text);
      case SpeechEnded():
        // 这段没识别出字（咳嗽、杂音）：已有的半句重新开始计时。
        _scheduleUserCommit();
      case SpeechFinal(:final text):
        if (text.trim().isNotEmpty) _pendingUser.add(text.trim());
        _scheduleUserCommit();
      case SpeechRecognitionFailed(:final message):
        if (_ending) return;
        _log('识别失败，挂断：$message');
        unawaited(hangUp());
    }
  }

  void _scheduleUserCommit() {
    _userTurnTimer?.cancel();
    // 挂断收尾时冲出的最后一句只记录，不再回复。
    if (_ending || _pendingUser.isEmpty) return;
    if (userTurnGap == Duration.zero) {
      _commitUserTurn();
    } else {
      _userTurnTimer = Timer(userTurnGap, _commitUserTurn);
    }
  }

  /// 打字输入的一轮：和识别出的一句话走同一条回复链路，写进同一份逐句记录。
  /// 还没提交的语音半句并进来一起发；角色正在想或说时直接打断（文字没有回声问题）。
  /// 返回 false 表示通话还没接通或已在挂断。
  bool sendText(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty || _ending || _connectedAt == null) return false;
    _userTurnTimer?.cancel();
    _pendingUser.add(trimmed);
    _commitUserTurn();
    return true;
  }

  void _commitUserTurn() {
    if (_ending || _pendingUser.isEmpty) return;
    final text = _joinPendingUser();
    _pendingUser.clear();
    unawaited(_onUserFinished(text));
  }

  /// 段与段之间补逗号，段尾已有标点的不补。
  String _joinPendingUser() {
    final out = StringBuffer();
    for (final part in _pendingUser) {
      if (out.isNotEmpty && !_endsWithPunctuation(out.toString())) {
        out.write('，');
      }
      out.write(part);
    }
    return out.toString();
  }

  static bool _endsWithPunctuation(String text) =>
      RegExp(r'[，。！？、；：,.!?;:…]$').hasMatch(text);

  Future<void> _onUserFinished(String text) async {
    if (_ending) return;
    // 打断但识别器还没来得及发 SpeechStarted 时，这里兜底收掉上一轮。
    if (_reply != null) await _abortReply(interrupted: true);
    _addTurn(CallTurn(role: 'user', text: text));
    _log('用户说完（${text.runes.length} 字）');
    _startReply();
  }

  void _startReply() {
    final reply = _ReplyTurn(
      CallReplySegmenter(minChars: segmentMinChars),
      playedBaseline: output.played,
    );
    _reply = reply;
    _setPhase(VoiceCallPhase.thinking);
    reply.subscription = generator
        .streamReply(transcript)
        .listen(
          (delta) {
            if (!identical(_reply, reply)) return;
            if (reply.sentText.isEmpty && !reply.firstDeltaLogged) {
              reply.firstDeltaLogged = true;
              _log('首字到达 +${reply.elapsedMs}ms');
            }
            reply.segmenter.push(delta).forEach((s) => _speak(reply, s));
          },
          onDone: () {
            if (!identical(_reply, reply)) return;
            final rest = reply.segmenter.drain();
            if (rest.isNotEmpty) _speak(reply, rest);
            reply.generationDone = true;
            reply.lastActivity = DateTime.now();
          },
          onError: (Object error) {
            _log('回复生成失败：$error');
            if (!identical(_reply, reply)) return;
            reply.generationDone = true;
            reply.lastActivity = DateTime.now();
          },
          cancelOnError: true,
        );
  }

  void _speak(_ReplyTurn reply, String segment) {
    reply.sentText.write(segment);
    reply.minAudioMs += minSpeechMs(segment);
    final now = DateTime.now();
    reply.lastActivity = now;
    tts.speak(segment);
  }

  void _onTtsAudio(Uint8List pcm) {
    final reply = _reply;
    if (reply == null || pcm.isEmpty) return;
    if (reply.receivedBytes == 0) _log('首块音频 +${reply.elapsedMs}ms');
    reply.receivedBytes += pcm.length;
    final now = DateTime.now();
    reply.lastActivity = now;
    output.push(pcm);
    if (_phase == VoiceCallPhase.thinking) _setPhase(VoiceCallPhase.speaking);
  }

  void _checkTurnEnd() {
    final reply = _reply;
    if (reply == null || !reply.generationDone) return;
    if (output.buffered > Duration.zero) return;
    final now = DateTime.now();
    final quietFor = now.difference(reply.lastActivity);
    if (quietFor < turnEndQuiet) return;
    // 合成服务不回报每段完成：收到的音频还不够念完已发出的字（按偏快语速估的
    // 下限）就继续等，免得前一段晚到的音频被当成最后一段已经到了。合成或网络
    // 停住超过 [synthesisTimeout] 才按没说完收尾。
    final receivedMs = reply.receivedBytes * 1000 ~/ (tts.sampleRate * 2);
    final heardEnough = receivedMs >= reply.minAudioMs;
    if (!heardEnough && quietFor < synthesisTimeout) return;
    if (!heardEnough) {
      _log('合成超时：收到 $receivedMs ms，至少应有 ${reply.minAudioMs} ms');
      // 换掉合成连接，迟到的音频不会混进下一轮。
      unawaited(_release('打断合成', tts.interrupt));
    }
    _reply = null;
    final text = reply.sentText.toString().trim();
    // 一块音频都没收到（合成失败）时，用户没听到这句，不记为角色说过；
    // 超时收尾时只记按音频估算念到的部分。
    final heard = heardEnough
        ? text
        : String.fromCharCodes(
            text.runes.take(
              (text.runes.length * receivedMs / reply.minAudioMs).floor(),
            ),
          ).trim();
    if (heard.isNotEmpty && reply.receivedBytes > 0) {
      _addTurn(
        CallTurn(role: 'assistant', text: heard, interrupted: !heardEnough),
      );
    }
    _setPhase(VoiceCallPhase.listening);
  }

  /// 收掉当前回复。[hangingUp] 时不清空播放、不换合成连接（马上整体释放），
  /// 也就不会因为重建播放设备失败而中断挂断。
  Future<void> _abortReply({
    required bool interrupted,
    bool hangingUp = false,
  }) async {
    final reply = _reply;
    if (reply == null) return;
    _reply = null;
    await _release('取消回复', () async => reply.subscription?.cancel());
    // 播放器的进度是整通电话累计的，减去本轮开始时的基线才是这轮播了多久。
    final played = output.played - reply.playedBaseline;
    if (!hangingUp) {
      await _release('清空播放', () async => output.clear());
      await _release('打断合成', tts.interrupt);
    }
    final spoken = _spokenPrefix(reply, played);
    if (spoken.isNotEmpty) {
      _addTurn(
        CallTurn(role: 'assistant', text: spoken, interrupted: interrupted),
      );
    }
    if (!_ending) _setPhase(VoiceCallPhase.listening);
  }

  /// 按「已播时长 ÷ 已收到音频时长」估算播出了多少字。
  /// 合成服务不返回字与音频的对应关系，这是近似值。
  String _spokenPrefix(_ReplyTurn reply, Duration played) {
    final text = reply.sentText.toString();
    final bytesPerSecond = tts.sampleRate * 2;
    final receivedMs = reply.receivedBytes * 1000 / bytesPerSecond;
    if (receivedMs <= 0) return '';
    final ratio = (played.inMilliseconds / receivedMs).clamp(0.0, 1.0);
    final runes = text.runes.toList();
    final count = (runes.length * ratio).round();
    return String.fromCharCodes(runes.take(count)).trim();
  }

  void _addTurn(CallTurn turn) {
    _transcript.add(turn);
    if (!_turns.isClosed) _turns.add(null);
  }

  void _setPhase(VoiceCallPhase phase) {
    if (_phase == phase) return;
    _phase = phase;
    _log('阶段 ${phase.name}');
    if (!_phases.isClosed) _phases.add(phase);
  }
}

class _ReplyTurn {
  _ReplyTurn(this.segmenter, {required this.playedBaseline});

  final CallReplySegmenter segmenter;

  /// 本轮开始时播放器的累计已播时长。
  final Duration playedBaseline;
  final sentText = StringBuffer();

  /// 已发出的文字至少要念多久（按偏快语速估的下限）。
  int minAudioMs = 0;
  StreamSubscription<String>? subscription;
  int receivedBytes = 0;
  bool generationDone = false;
  bool firstDeltaLogged = false;
  DateTime lastActivity = DateTime.now();
  final _clock = Stopwatch()..start();

  int get elapsedMs => _clock.elapsedMilliseconds;
}

/// 一段文字念出来至少要多久：中文等按字约 110 ms，拉丁字母约 35 ms，取偏快语速，
/// 只用来判断「音频是否可能还没到齐」。
int minSpeechMs(String text) {
  var ms = 0;
  // 语气标签不会被念出来，不算进时长。
  for (final rune in stripSpeechTags(text).runes) {
    if (rune >= 0x3000) {
      ms += 110;
    } else if ((rune >= 0x30 && rune <= 0x39) ||
        (rune | 0x20) >= 0x61 && (rune | 0x20) <= 0x7a) {
      ms += 35;
    }
  }
  return ms;
}
