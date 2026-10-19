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

  group('ModelRequestErrorReport.brief', () {
    test('explains missing API key instead of pointing to the log center', () {
      final brief = ModelRequestErrorReport.brief(
        'Bad state: Missing providerApiKey for direct stream',
      );
      expect(brief, contains('API Key'));
      expect(brief, isNot(contains('日志中心')));
    });

    test('recognizes context overflow from provider bodies', () {
      const bodies = [
        'Exception: HTTP 400: {"error":{"message":"This model\'s maximum '
            'context length is 65536 tokens. However, you requested 70000 '
            'tokens.","code":"context_length_exceeded"}}',
        'Exception: HTTP 400: {"error":{"message":"prompt is too long: '
            '210000 tokens > 200000 maximum"}}',
        'Exception: HTTP 400: {"error":{"message":"The input token count '
            '(1200000) exceeds the maximum number of tokens allowed"}}',
      ];
      for (final body in bodies) {
        expect(ModelRequestErrorReport.brief(body), contains('上下文'));
      }
    });

    test('keeps HTTP hint and provider message short', () {
      final brief = ModelRequestErrorReport.brief(
        'Exception: HTTP 402: {"error":{"message":"Insufficient Balance"}}',
      );
      expect(brief, '发送失败：HTTP 402 账户余额不足：Insufficient Balance');

      final long = ModelRequestErrorReport.brief(
        'Exception: HTTP 500: ${'x' * 500}',
      );
      expect(long.length, lessThanOrEqualTo(110));
    });

    test('shows readable local errors as is', () {
      expect(
        ModelRequestErrorReport.brief(
          'Bad state: 上下文超限：预设处理后的消息与工具定义超过本轮预算',
        ),
        '发送失败：上下文超限：预设处理后的消息与工具定义超过本轮预算',
      );
    });

    test('falls back to the log center only when nothing is known', () {
      expect(ModelRequestErrorReport.brief('  '), contains('日志中心'));
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
