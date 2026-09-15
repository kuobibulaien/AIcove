import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'frontend_diagnostics_port.dart';
import 'frontend_diagnostics_service.dart';
import 'trace_export_service.dart';
import 'diagnostic_access_port.dart';
import 'diagnostic_access_service.dart';

final diagnosticAccessProvider = Provider<DiagnosticAccessPort>(
  (ref) => DiagnosticAccessService.instance,
);

final traceExportProvider =
    Provider<TraceExportPort>((ref) => const TraceExportAdapter());

final frontendDiagnosticsProvider = Provider<FrontendDiagnosticsPort>(
  (ref) => FrontendDiagnosticsService.instance,
);
