import 'dart:convert';
import 'package:http/http.dart' as http;
import 'config.dart';
import 'api_logger.dart';

/// 极简 API 客户端：统一超时与 JSON 解析（KISS/YAGNI）
class ApiClient {
  final http.Client _client;
  final Duration timeout;

  ApiClient({http.Client? client, Duration? timeout})
      : _client = client ?? http.Client(),
        timeout = timeout ?? const Duration(seconds: 30);

  Uri _uri(String path) {
    if (path.startsWith('http://') || path.startsWith('https://')) {
      return Uri.parse(path);
    }
    final base = resolvedApiBase();
    // 确保 path 以 / 开头
    final p = path.startsWith('/') ? path : '/$path';
    return Uri.parse('$base$p');
  }

  Future<Map<String, dynamic>> getJson(String path) async {
    final uri = _uri(path);
    final sw = Stopwatch()..start();
    try {
      final res = await _client
          .get(uri, headers: {'Content-Type': 'application/json'})
          .timeout(timeout);
      sw.stop();
      ApiLogger.add(ApiLogEntry(
        time: DateTime.now(),
        method: 'GET',
        url: uri.toString(),
        status: res.statusCode,
        durationMs: sw.elapsedMilliseconds,
        requestBody: '',
        responseBody: ApiLogger.safeSnippet(utf8.decode(res.bodyBytes)),
        ok: res.statusCode >= 200 && res.statusCode < 300,
      ));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      }
      throw Exception('HTTP ${res.statusCode}: ${res.body}');
    } catch (e) {
      sw.stop();
      ApiLogger.add(ApiLogEntry(
        time: DateTime.now(),
        method: 'GET',
        url: uri.toString(),
        status: null,
        durationMs: sw.elapsedMilliseconds,
        requestBody: '',
        responseBody: ApiLogger.safeSnippet(e.toString()),
        ok: false,
      ));
      rethrow;
    }
  }

  Future<Map<String, dynamic>> postJson(String path, Map<String, dynamic> body) async {
    final uri = _uri(path);
    final payload = jsonEncode(body);
    final sw = Stopwatch()..start();
    try {
      final res = await _client
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: payload,
          )
          .timeout(timeout);
      sw.stop();
      ApiLogger.add(ApiLogEntry(
        time: DateTime.now(),
        method: 'POST',
        url: uri.toString(),
        status: res.statusCode,
        durationMs: sw.elapsedMilliseconds,
        requestBody: ApiLogger.safeSnippet(payload),
        responseBody: ApiLogger.safeSnippet(utf8.decode(res.bodyBytes)),
        ok: res.statusCode >= 200 && res.statusCode < 300,
      ));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      }
      throw Exception('HTTP ${res.statusCode}: ${res.body}');
    } catch (e) {
      sw.stop();
      ApiLogger.add(ApiLogEntry(
        time: DateTime.now(),
        method: 'POST',
        url: uri.toString(),
        status: null,
        durationMs: sw.elapsedMilliseconds,
        requestBody: ApiLogger.safeSnippet(payload),
        responseBody: ApiLogger.safeSnippet(e.toString()),
        ok: false,
      ));
      rethrow;
    }
  }

  Future<Map<String, dynamic>> putJson(String path, Map<String, dynamic> body) async {
    final uri = _uri(path);
    final payload = jsonEncode(body);
    final sw = Stopwatch()..start();
    try {
      final res = await _client
          .put(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: payload,
          )
          .timeout(timeout);
      sw.stop();
      ApiLogger.add(ApiLogEntry(
        time: DateTime.now(),
        method: 'PUT',
        url: uri.toString(),
        status: res.statusCode,
        durationMs: sw.elapsedMilliseconds,
        requestBody: ApiLogger.safeSnippet(payload),
        responseBody: ApiLogger.safeSnippet(utf8.decode(res.bodyBytes)),
        ok: res.statusCode >= 200 && res.statusCode < 300,
      ));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      }
      throw Exception('HTTP ${res.statusCode}: ${res.body}');
    } catch (e) {
      sw.stop();
      ApiLogger.add(ApiLogEntry(
        time: DateTime.now(),
        method: 'PUT',
        url: uri.toString(),
        status: null,
        durationMs: sw.elapsedMilliseconds,
        requestBody: ApiLogger.safeSnippet(payload),
        responseBody: ApiLogger.safeSnippet(e.toString()),
        ok: false,
      ));
      rethrow;
    }
  }

  Future<Map<String, dynamic>> putJsonAuth(String path, Map<String, dynamic> body, {String? bearerToken}) async {
    final uri = _uri(path);
    final payload = jsonEncode(body);
    final sw = Stopwatch()..start();
    final headers = <String, String>{'Content-Type': 'application/json'};
    if (bearerToken != null && bearerToken.trim().isNotEmpty) {
      headers['Authorization'] = 'Bearer ${bearerToken.trim()}';
    }
    try {
      final res = await _client
          .put(
            uri,
            headers: headers,
            body: payload,
          )
          .timeout(timeout);
      sw.stop();
      ApiLogger.add(ApiLogEntry(
        time: DateTime.now(),
        method: 'PUT',
        url: uri.toString(),
        status: res.statusCode,
        durationMs: sw.elapsedMilliseconds,
        requestBody: ApiLogger.safeSnippet(payload),
        responseBody: ApiLogger.safeSnippet(utf8.decode(res.bodyBytes)),
        ok: res.statusCode >= 200 && res.statusCode < 300,
      ));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      }
      throw Exception('HTTP ${res.statusCode}: ${res.body}');
    } catch (e) {
      sw.stop();
      ApiLogger.add(ApiLogEntry(
        time: DateTime.now(),
        method: 'PUT',
        url: uri.toString(),
        status: null,
        durationMs: sw.elapsedMilliseconds,
        requestBody: ApiLogger.safeSnippet(payload),
        responseBody: ApiLogger.safeSnippet(e.toString()),
        ok: false,
      ));
      rethrow;
    }
  }

  Future<Map<String, dynamic>> deleteJson(String path) async {
    final uri = _uri(path);
    final sw = Stopwatch()..start();
    try {
      final res = await _client.delete(uri).timeout(timeout);
      sw.stop();
      ApiLogger.add(ApiLogEntry(
        time: DateTime.now(),
        method: 'DELETE',
        url: uri.toString(),
        status: res.statusCode,
        durationMs: sw.elapsedMilliseconds,
        requestBody: '',
        responseBody: ApiLogger.safeSnippet(utf8.decode(res.bodyBytes)),
        ok: res.statusCode >= 200 && res.statusCode < 300,
      ));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        if (res.bodyBytes.isEmpty) {
          return <String, dynamic>{};
        }
        return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      }
      throw Exception('HTTP ${res.statusCode}: ${res.body}');
    } catch (e) {
      sw.stop();
      ApiLogger.add(ApiLogEntry(
        time: DateTime.now(),
        method: 'DELETE',
        url: uri.toString(),
        status: null,
        durationMs: sw.elapsedMilliseconds,
        requestBody: '',
        responseBody: ApiLogger.safeSnippet(e.toString()),
        ok: false,
      ));
      rethrow;
    }
  }
}
