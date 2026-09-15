import 'package:flutter/foundation.dart';

class DiagnosticAccessSession {
  const DiagnosticAccessSession(this.port, this.token);
  final int port;
  final String token;

  String get command => 'python3 tool/collect_diagnostics.py --release '
      '--port $port --token $token --since 2h --print';
}

/// 手动导出与自动本机读取共用同一受控快照，不读取聊天数据库或附件。
abstract interface class DiagnosticAccessPort {
  ValueListenable<DiagnosticAccessSession?> get session;
  Future<Uint8List> exportBundle();
  Future<void> start();
  Future<void> stop();
}
