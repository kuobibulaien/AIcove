import 'dart:ui';
import 'package:flutter/foundation.dart';
import '../features/observability/frontend_diagnostics_port.dart';

/// 保留 Flutter 默认控制台报告与既有平台错误处理，不吞掉异常。
class FrontendErrorCapture {
  FrontendErrorCapture(this.diagnostics);
  final FrontendDiagnosticsPort diagnostics;
  FlutterExceptionHandler? _previousFlutter;
  ErrorCallback? _previousPlatform;
  bool _installed = false;

  void install() {
    if (_installed) return;
    _installed = true;
    _previousFlutter = FlutterError.onError;
    _previousPlatform = PlatformDispatcher.instance.onError;
    FlutterError.onError = _onFlutterError;
    PlatformDispatcher.instance.onError = _onPlatformError;
  }

  void uninstall() {
    if (!_installed) return;
    if (FlutterError.onError == _onFlutterError) {
      FlutterError.onError = _previousFlutter;
    }
    if (PlatformDispatcher.instance.onError == _onPlatformError) {
      PlatformDispatcher.instance.onError = _previousPlatform;
    }
    _installed = false;
  }

  void _record(FrontendStage stage, Object error, StackTrace? stack) {
    try {
      diagnostics.record(
          FrontendDiagnosticContext(
            operationId: 'error_${DateTime.now().microsecondsSinceEpoch}',
          ),
          stage,
          error: error,
          stackTrace: stack);
    } catch (_) {/* 诊断失败不能覆盖原异常。 */}
  }

  void _onFlutterError(FlutterErrorDetails details) {
    _record(FrontendStage.frameworkError, details.exception, details.stack);
    (_previousFlutter ?? FlutterError.presentError)(details);
  }

  bool _onPlatformError(Object error, StackTrace stack) {
    _record(FrontendStage.unhandledError, error, stack);
    return _previousPlatform?.call(error, stack) ?? false;
  }
}
