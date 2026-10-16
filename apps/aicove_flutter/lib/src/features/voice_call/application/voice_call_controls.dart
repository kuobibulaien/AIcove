import 'package:flutter/foundation.dart';

import '../domain/voice_call_ports.dart';
import 'voice_call_session.dart';

/// 通话界面看到和能操作的一通电话。主窗口里是 [ActiveVoiceCall] 本身，
/// 桌面端独立通话小窗里是转发到主窗口的镜像（小窗有自己的引擎，拿不到主窗口的对象）。
abstract interface class VoiceCallControls implements Listenable {
  /// 每秒走一次的通话时长，单独通知，免得计时带着整页重建。
  ValueListenable<Duration> get elapsed;

  VoiceCallPhase get phase;

  /// 接通失败的原因，展示给用户。
  String? get error;

  /// 用户正在说的话（识别器支持中间结果时才有）。
  String get partial;

  bool get muted;
  bool get speakerOff;

  /// 正在挂断或已经挂断，不再接受操作。
  bool get ending;

  bool get connected;
  List<CallTurn> get transcript;

  void toggleMute();
  void toggleSpeaker();
  Future<void> hangUp();
}
