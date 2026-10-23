import 'dart:convert';
import 'dart:io';

import '../../core/storage/app_data_directory.dart';

/// Awaited, small append for the WorkManager isolate; no Flutter log notifier,
/// message body, trigger title, credentials or dynamic exception text.
Future<void> recordBackgroundDelivery({
  required String event,
  required String entityId,
  required String? conversationId,
  required String phase,
  required bool? success,
  required int elapsedMs,
}) async {
  try {
    final now = DateTime.now();
    final directory = Directory('${(await appDataDirectory()).path}/logs');
    await directory.create(recursive: true);
    final date = now.toIso8601String().substring(0, 10);
    await File('${directory.path}/app_$date.jsonl').writeAsString(
      '${jsonEncode({
        'time': now.toIso8601String(),
        'level': success == false ? 'ERROR' : 'INFO',
        'source': 'BackgroundDelivery',
        'metadata': {'category': 'backgroundDelivery', 'event': event, 'entityId': entityId, if (conversationId != null) 'conversationId': conversationId, 'phase': phase, 'result': success == false
            ? 'failed'
            : success == true
            ? 'success'
            : 'recorded', 'elapsedMs': elapsedMs},
      })}\n',
      mode: FileMode.append,
      flush: true,
    );
  } catch (_) {
    // Diagnostics must not change delivery or its recovery state.
  }
}
