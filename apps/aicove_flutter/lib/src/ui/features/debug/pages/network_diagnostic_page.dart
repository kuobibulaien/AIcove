import 'package:aicove_flutter/src/ui/shared/widgets/moe_page_scaffold.dart';
import 'dart:async';

import 'package:aicove_flutter/src/ui/theme/moe_interaction_theme.dart';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/widgets/moe_app_bar.dart';

/// 网络诊断页面 - 输入 URL 发送请求，查看连通状态
class NetworkDiagnosticPage extends StatefulWidget {
  const NetworkDiagnosticPage({super.key});

  @override
  State<NetworkDiagnosticPage> createState() => _NetworkDiagnosticPageState();
}

class _NetworkDiagnosticPageState extends State<NetworkDiagnosticPage> {
  final _urlController = TextEditingController(
    text: 'https://image.novelai.net/ai/generate-image',
  );
  final _headerKeyController = TextEditingController();
  final _headerValueController = TextEditingController();
  final _results = <_DiagnosticResult>[];
  final _customHeaders = <String, String>{};

  String _method = 'GET';
  bool _testing = false;

  @override
  void dispose() {
    _urlController.dispose();
    _headerKeyController.dispose();
    _headerValueController.dispose();
    super.dispose();
  }

  Future<void> _runTest() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;

    setState(() => _testing = true);

    final result = _DiagnosticResult(url: url, method: _method);
    final stopwatch = Stopwatch()..start();
    final client = http.Client();

    try {
      final uri = Uri.parse(url);
      final headers = <String, String>{..._customHeaders};

      late http.Response response;
      switch (_method) {
        case 'HEAD':
          response = await client
              .head(uri, headers: headers)
              .timeout(const Duration(seconds: 15));
          break;
        case 'POST':
          response = await client
              .post(uri, headers: headers, body: '{}')
              .timeout(const Duration(seconds: 15));
          break;
        default:
          response = await client
              .get(uri, headers: headers)
              .timeout(const Duration(seconds: 15));
      }

      stopwatch.stop();
      result.statusCode = response.statusCode;
      result.duration = stopwatch.elapsed;
      result.responseHeaders = response.headers;
      result.bodyPreview = response.body.length > 500
          ? '${response.body.substring(0, 500)}...'
          : response.body;
      result.success = response.statusCode < 500;
    } on TimeoutException {
      stopwatch.stop();
      result.duration = stopwatch.elapsed;
      result.error = '请求超时（15秒）';
    } catch (e) {
      stopwatch.stop();
      result.duration = stopwatch.elapsed;
      result.error = e.toString();
    } finally {
      client.close();
    }

    setState(() {
      _results.insert(0, result);
      _testing = false;
    });
  }

  void _addHeader() {
    final key = _headerKeyController.text.trim();
    final value = _headerValueController.text.trim();
    if (key.isEmpty) return;
    setState(() {
      _customHeaders[key] = value;
      _headerKeyController.clear();
      _headerValueController.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;

    return MoePageScaffold(
      backgroundColor: colors.surface,
      appBar: const MoeAppBar(title: '网络诊断', showBackButton: true),
      body: Column(
        children: [
          // ── 输入区域 ──
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: colors.panel,
              border: Border(
                bottom: BorderSide(color: colors.divider, width: 0.5),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // URL 输入 + 方法选择
                Row(
                  children: [
                    // 方法选择
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      decoration: BoxDecoration(
                        color: colors.surface,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: _method,
                          style: TextStyle(
                            color: colors.text,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                          dropdownColor: colors.panel,
                          items: const [
                            DropdownMenuItem(value: 'GET', child: Text('GET')),
                            DropdownMenuItem(
                              value: 'HEAD',
                              child: Text('HEAD'),
                            ),
                            DropdownMenuItem(
                              value: 'POST',
                              child: Text('POST'),
                            ),
                          ],
                          onChanged: (v) {
                            if (v != null) setState(() => _method = v);
                          },
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // URL 输入
                    Expanded(
                      child: TextField(
                        controller: _urlController,
                        style: TextStyle(color: colors.text, fontSize: 13),
                        decoration: InputDecoration(
                          hintText: '输入 URL...',
                          hintStyle: TextStyle(color: colors.textSecondary),
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          filled: true,
                          fillColor: colors.surface,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // 自定义 Header
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: TextField(
                        controller: _headerKeyController,
                        style: TextStyle(color: colors.text, fontSize: 12),
                        decoration: InputDecoration(
                          hintText: 'Header Key (如 Authorization)',
                          hintStyle: TextStyle(
                            color: colors.textSecondary,
                            fontSize: 12,
                          ),
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          filled: true,
                          fillColor: colors.surface,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(6),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      flex: 3,
                      child: TextField(
                        controller: _headerValueController,
                        style: TextStyle(color: colors.text, fontSize: 12),
                        decoration: InputDecoration(
                          hintText: 'Header Value (如 Bearer xxx)',
                          hintStyle: TextStyle(
                            color: colors.textSecondary,
                            fontSize: 12,
                          ),
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          filled: true,
                          fillColor: colors.surface,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(6),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    SizedBox(
                      height: 32,
                      child: TextButton(
                        onPressed: _addHeader,
                        style: withoutHoverFeedback(
                          TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            backgroundColor: colors.surface,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(6),
                            ),
                          ),
                        ),
                        child: Text(
                          '+',
                          style: TextStyle(color: colors.accent, fontSize: 16),
                        ),
                      ),
                    ),
                  ],
                ),
                // 已添加的 Headers
                if (_customHeaders.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: _customHeaders.entries.map((e) {
                      final display = e.value.length > 20
                          ? '${e.key}: ${e.value.substring(0, 20)}...'
                          : '${e.key}: ${e.value}';
                      return Chip(
                        label: Text(
                          display,
                          style: TextStyle(fontSize: 11, color: colors.text),
                        ),
                        deleteIcon: Icon(
                          Icons.close,
                          size: 14,
                          color: colors.textSecondary,
                        ),
                        onDeleted: () =>
                            setState(() => _customHeaders.remove(e.key)),
                        backgroundColor: colors.surface,
                        visualDensity: VisualDensity.compact,
                      );
                    }).toList(),
                  ),
                ],
                const SizedBox(height: 10),
                // 发送按钮
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _testing ? null : _runTest,
                    style: withoutHoverFeedback(
                      ElevatedButton.styleFrom(
                        elevation: 1,
                        backgroundColor: colors.accent,
                        foregroundColor: colors.text,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                    ),
                    child: _testing
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Text('发送请求'),
                  ),
                ),
              ],
            ),
          ),
          // ── 结果列表 ──
          Expanded(
            child: _results.isEmpty
                ? Center(
                    child: Text(
                      '点击「发送请求」测试网络连通性',
                      style: TextStyle(color: colors.textSecondary),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(12),
                    itemCount: _results.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (_, i) => _ResultCard(result: _results[i]),
                  ),
          ),
        ],
      ),
    );
  }
}

// ── 数据模型 ──

class _DiagnosticResult {
  final String url;
  final String method;
  final DateTime timestamp = DateTime.now();
  int? statusCode;
  Duration? duration;
  String? error;
  Map<String, String>? responseHeaders;
  String? bodyPreview;
  bool success = false;

  _DiagnosticResult({required this.url, required this.method});

  bool get isError => error != null;
}

// ── 结果卡片 ──

class _ResultCard extends StatefulWidget {
  final _DiagnosticResult result;
  const _ResultCard({required this.result});

  @override
  State<_ResultCard> createState() => _ResultCardState();
}

class _ResultCardState extends State<_ResultCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final r = widget.result;
    final colors = context.moeColors;

    final statusColor = r.isError
        ? Colors.red
        : (r.statusCode != null && r.statusCode! < 400)
        ? Colors.green
        : Colors.orange;

    final statusText = r.isError ? 'ERROR' : '${r.statusCode}';

    return GestureDetector(
      onTap: () => setState(() => _expanded = !_expanded),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: colors.panel,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: statusColor.withValues(alpha: 0.3),
            width: 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 状态行
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    statusText,
                    style: TextStyle(
                      color: statusColor,
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: colors.surface,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    r.method,
                    style: TextStyle(color: colors.textSecondary, fontSize: 11),
                  ),
                ),
                const Spacer(),
                if (r.duration != null)
                  Text(
                    '${r.duration!.inMilliseconds}ms',
                    style: TextStyle(color: colors.textSecondary, fontSize: 12),
                  ),
                const SizedBox(width: 4),
                Icon(
                  _expanded
                      ? Icons.keyboard_arrow_up
                      : Icons.keyboard_arrow_down,
                  size: 18,
                  color: colors.textSecondary,
                ),
              ],
            ),
            const SizedBox(height: 4),
            // URL
            Text(
              r.url,
              style: TextStyle(color: colors.text, fontSize: 12),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            // 错误信息
            if (r.isError) ...[
              const SizedBox(height: 6),
              Text(
                r.error!,
                style: const TextStyle(color: Colors.red, fontSize: 12),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            // 展开详情
            if (_expanded) ...[
              const SizedBox(height: 8),
              Divider(color: colors.divider, height: 1),
              const SizedBox(height: 8),
              if (r.responseHeaders != null) ...[
                Text(
                  'Response Headers:',
                  style: TextStyle(
                    color: colors.textSecondary,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                ...r.responseHeaders!.entries.map(
                  (e) => Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Text(
                      '${e.key}: ${e.value}',
                      style: TextStyle(
                        color: colors.textSecondary,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ),
              ],
              if (r.bodyPreview != null && r.bodyPreview!.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  'Response Body:',
                  style: TextStyle(
                    color: colors.textSecondary,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: colors.surface,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: SelectableText(
                    r.bodyPreview!,
                    style: TextStyle(
                      color: colors.text,
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}
