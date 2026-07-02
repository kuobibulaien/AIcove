import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/features/observability/trace_models.dart';
import 'package:aicove_flutter/src/features/observability/trace_query_service.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/log_viewer/log_viewer_trace_conversation_view.dart';

void main() {
  test(
      'buildTraceTurnTitle should add background badge for background agent turn',
      () {
    final turn = TraceTurnSummary(
      traceId: 'tr_bg_title',
      sessionId: 'conv_bg_title',
      turnId: 'bg_turn_title',
      startedAt: DateTime(2026, 4, 23, 20, 25, 48),
      endedAt: DateTime(2026, 4, 23, 20, 25, 58),
      totalDurationMs: 10000,
      roundCount: 1,
      eventCount: 4,
      toolCallCount: 0,
      status: TraceEventStatus.success.value,
      traceKind: TraceKind.backgroundAgent.value,
    );

    final title = buildTraceTurnTitle(turn);
    expect(title, contains('<后台>'));
    expect(title, contains('1轮'));
    expect(title, contains('成功'));
  });
}
