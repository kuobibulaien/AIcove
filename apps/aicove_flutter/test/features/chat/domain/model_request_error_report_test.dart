import 'package:aicove_flutter/src/core/app_logger.dart';
import 'package:aicove_flutter/src/features/chat/domain/model_request_error_report.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ModelRequestErrorReport.summarize', () {
    test('extracts provider message from HTTP JSON body', () {
      final summary = ModelRequestErrorReport.summarize(
        'Exception: HTTP 401: {"error":{"message":"Invalid API key provided",'
        '"type":"invalid_request_error","code":"invalid_api_key"}}',
      );
      expect(summary, 'HTTP 401 鉴权失败，请检查 API Key：Invalid API key provided');
    });

    test('handles string error field and unknown status', () {
      expect(
        ModelRequestErrorReport.summarize('Exception: HTTP 418: {"error":"teapot"}'),
        'HTTP 418 请求被拒绝：teapot',
      );
    });

    test('strips html from non JSON body', () {
      expect(
        ModelRequestErrorReport.summarize(
          'Exception: HTTP 502: <html><body><h1>502 Bad Gateway</h1></body></html>',
        ),
        'HTTP 502 网关错误：502 Bad Gateway',
      );
    });

    test('labels network and SSE errors', () {
      expect(
        ModelRequestErrorReport.summarize(
          "ClientException with SocketException: Failed host lookup: 'api.x.com'",
        ),
        startsWith('网络连接失败：'),
      );
      expect(
        ModelRequestErrorReport.summarize('Exception: SSE error: overloaded'),
        '流式返回错误：overloaded',
      );
    });
  });

  test('buildFullLog keeps full error and only entries of this round', () {
    final start = DateTime(2026, 10, 4, 10);
    final log = ModelRequestErrorReport.buildFullLog(
      failedModelName: 'A',
      nextModelName: 'B',
      errorMessage: 'Exception: HTTP 500: boom',
      errorDetail: '_Exception: Exception: HTTP 500: boom\n\n#0 main',
      roundStartedAt: start,
      failedAt: start.add(const Duration(seconds: 3)),
      logEntries: [
        LogEntry(
          time: start.subtract(const Duration(seconds: 1)),
          level: LogLevel.info,
          source: 'Old',
          message: 'previous round',
        ),
        LogEntry(
          time: start.add(const Duration(seconds: 1)),
          level: LogLevel.error,
          source: 'AgentApiClient',
          message: '直连流式请求失败(非2xx)',
          metadata: const {'statusCode': 500},
        ),
      ],
    );
    expect(log, contains('主要原因：HTTP 500 服务端内部错误：boom'));
    expect(log, contains('#0 main'));
    expect(log, contains('本轮日志（1 条'));
    expect(log, contains('直连流式请求失败(非2xx) {"statusCode":500}'));
    expect(log, isNot(contains('previous round')));
  });
}
