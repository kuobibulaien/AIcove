import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class JsonHttpResponse {
  final int statusCode;
  final Map<String, dynamic> data;
  final String body;
  final Map<String, String> headers;

  const JsonHttpResponse({
    required this.statusCode,
    required this.data,
    required this.body,
    required this.headers,
  });
}

class JsonHttpRequestException implements Exception {
  final String message;
  final int? statusCode;
  final String? responseBody;
  final Map<String, dynamic>? responseJson;
  final Object? cause;
  final bool isTimeout;

  const JsonHttpRequestException(
    this.message, {
    this.statusCode,
    this.responseBody,
    this.responseJson,
    this.cause,
    this.isTimeout = false,
  });

  @override
  String toString() {
    final parts = <String>[message];
    if (statusCode != null) {
      parts.add('status=$statusCode');
    }
    if (cause != null) {
      parts.add('cause=$cause');
    }
    return 'JsonHttpRequestException(${parts.join(', ')})';
  }
}

class JsonHttpClient {
  const JsonHttpClient._();

  static Future<JsonHttpResponse> postJson({
    required Uri uri,
    required Map<String, String> headers,
    required Map<String, dynamic> jsonBody,
    Duration timeout = const Duration(seconds: 30),
    Set<int>? successStatusCodes,
    http.Client? client,
  }) {
    return _send(
      timeout: timeout,
      successStatusCodes: successStatusCodes,
      client: client,
      send: (c) => c.post(
        uri,
        headers: headers,
        body: jsonEncode(jsonBody),
      ),
    );
  }

  static Future<JsonHttpResponse> getJson({
    required Uri uri,
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 30),
    Set<int>? successStatusCodes,
    http.Client? client,
  }) {
    return _send(
      timeout: timeout,
      successStatusCodes: successStatusCodes,
      client: client,
      send: (c) => c.get(uri, headers: headers),
    );
  }

  static Future<JsonHttpResponse> _send({
    required Future<http.Response> Function(http.Client client) send,
    required Duration timeout,
    Set<int>? successStatusCodes,
    http.Client? client,
  }) async {
    final ownedClient = client ?? http.Client();
    final shouldClose = client == null;
    try {
      final response = await send(ownedClient).timeout(timeout);
      final body = utf8.decode(response.bodyBytes);
      Map<String, dynamic>? decoded;
      try {
        decoded = _decodeObject(body);
      } catch (_) {
        decoded = null;
      }

      final ok = successStatusCodes == null
          ? (response.statusCode >= 200 && response.statusCode < 300)
          : successStatusCodes.contains(response.statusCode);
      if (!ok) {
        throw JsonHttpRequestException(
          'HTTP ${response.statusCode}',
          statusCode: response.statusCode,
          responseBody: body,
          responseJson: decoded,
        );
      }

      if (decoded == null) {
        throw JsonHttpRequestException(
          'Response is not a JSON object',
          statusCode: response.statusCode,
          responseBody: body,
        );
      }

      return JsonHttpResponse(
        statusCode: response.statusCode,
        data: decoded,
        body: body,
        headers: response.headers,
      );
    } on TimeoutException catch (e) {
      throw JsonHttpRequestException(
        'Request timeout',
        isTimeout: true,
        cause: e,
      );
    } on http.ClientException catch (e) {
      throw JsonHttpRequestException(
        'Network error',
        cause: e,
      );
    } finally {
      if (shouldClose) {
        ownedClient.close();
      }
    }
  }

  static Map<String, dynamic>? _decodeObject(String body) {
    final trimmed = body.trim();
    if (trimmed.isEmpty) return <String, dynamic>{};
    final decoded = jsonDecode(trimmed);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) {
      final out = <String, dynamic>{};
      decoded.forEach((key, value) {
        out[key.toString()] = value;
      });
      return out;
    }
    return null;
  }
}
