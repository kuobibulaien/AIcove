import 'dart:convert';
import 'package:flutter/foundation.dart';

class ApiLogEntry {
  final DateTime time;
  final String method;
  final String url;
  final int? status;
  final int durationMs;
  final String requestBody;
  final String responseBody;
  final bool ok;

  const ApiLogEntry({
    required this.time,
    required this.method,
    required this.url,
    required this.status,
    required this.durationMs,
    required this.requestBody,
    required this.responseBody,
    required this.ok,
  });
}

class ApiLogger {
  static final ValueNotifier<List<ApiLogEntry>> entries = ValueNotifier<List<ApiLogEntry>>(<ApiLogEntry>[]);
  static const int _max = 200;

  static void add(ApiLogEntry e) {
    final list = List<ApiLogEntry>.from(entries.value);
    list.add(e);
    if (list.length > _max) {
      list.removeRange(0, list.length - _max);
    }
    entries.value = list;
  }

  static void clear() {
    entries.value = <ApiLogEntry>[];
  }

  static String safeSnippet(String s, {int max = 800}) {
    String out = s;
    // 屏蔽常见敏感字段
    out = out.replaceAllMapped(RegExp(r'("api_key"\s*:\s*")([^"\\]{4,})(")', multiLine: true), (m) => '${m.group(1)}***${m.group(3)}');
    out = out.replaceAllMapped(RegExp(r'(sk-)[A-Za-z0-9]{8,}'), (m) => '${m.group(1)}****');
    if (out.length > max) {
      return out.substring(0, max) + '…';
    }
    return out;
  }

  static String prettyJson(String s) {
    try {
      final obj = jsonDecode(s);
      return const JsonEncoder.withIndent('  ').convert(obj);
    } catch (_) {
      return s;
    }
  }
}

