import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../features/observability/trace_models.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/shared/widgets/moe_toast.dart';
import '../../../../ui/theme/tokens.dart';
import 'log_formatters.dart' show tryFormatJson, stageToZh;

/// 载荷详情面板 —— 展示选中事件的原始数据（上下文/请求/响应/工具等）
class TracePayloadPanel extends StatefulWidget {
  const TracePayloadPanel({
    super.key,
    required this.selectedEvent,
    required this.payloadEnvelope,
    this.isLoading = false,
  });

  final TraceEvent? selectedEvent;
  final Map<String, dynamic>? payloadEnvelope;
  final bool isLoading;

  @override
  State<TracePayloadPanel> createState() => _TracePayloadPanelState();
}

class _TracePayloadPanelState extends State<TracePayloadPanel> {
  int _tabIndex = 0;
  bool _initialTabResolved = false;

  @override
  void didUpdateWidget(covariant TracePayloadPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldEvent = oldWidget.selectedEvent;
    final newEvent = widget.selectedEvent;
    final changed = oldEvent?.traceId != newEvent?.traceId ||
        oldEvent?.eventSeq != newEvent?.eventSeq;
    if (changed) {
      _initialTabResolved = false;
      final root = _resolvePayloadRoot(widget.payloadEnvelope);
      final sections = _buildSections(root, newEvent);
      setState(() => _tabIndex =
          sections.isEmpty ? 0 : _tabIndex.clamp(0, sections.length - 1));
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;

    if (widget.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final event = widget.selectedEvent;
    if (event == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.touch_app_outlined, size: 40, color: colors.muted),
            const SizedBox(height: 8),
            Text('请选择一个事件查看详情',
                style: TextStyle(color: colors.textSecondary, fontSize: 13)),
          ],
        ),
      );
    }

    final payloadRoot = _resolvePayloadRoot(widget.payloadEnvelope);
    final sections = _buildSections(payloadRoot, event);
    if (!_initialTabResolved) {
      _initialTabResolved = true;
    }
    final safeIndex = _tabIndex.clamp(0, sections.length - 1);
    final current = sections[safeIndex];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  stageToZh(event.stage),
                  style: TextStyle(
                    color: colors.text,
                    fontSize: 14,
                    fontWeight: MoeFontWeights.emphasis,
                  ),
                ),
              ),
              IconButton(
                tooltip: '复制当前区块',
                icon: Icon(
                  Icons.copy_outlined,
                  color: colors.textSecondary,
                  size: 18,
                ),
                visualDensity: VisualDensity.compact,
                onPressed: () => _copyCurrentSection(current),
              ),
              IconButton(
                tooltip: '复制全部区块',
                icon: Icon(
                  Icons.library_books_outlined,
                  color: colors.textSecondary,
                  size: 18,
                ),
                visualDensity: VisualDensity.compact,
                onPressed: () => _copyAllSections(sections),
              ),
            ],
          ),
        ),
        if (sections.length > 1) ...[
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                for (var i = 0; i < sections.length; i++) ...[
                  _buildTabChip(
                    context,
                    label: sections[i].label,
                    selected: safeIndex == i,
                    onTap: () => setState(() => _tabIndex = i),
                  ),
                  if (i != sections.length - 1) const SizedBox(width: 6),
                ],
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
        Expanded(
          child: Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            padding: const EdgeInsets.all(10),
            decoration: MoeG2Decoration(
              radius: 10,
              color: colors.componentBackground,
              border: Border.all(color: colors.borderLight, width: borderWidth),
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                current.content,
                style: TextStyle(
                  color: colors.text,
                  fontSize: 11,
                  height: 1.4,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _copyCurrentSection(_PayloadSection section) async {
    final content = section.content.trim();
    if (content.isEmpty || content == '(空)') {
      MoeToast.info(context, '当前区块暂无可复制内容');
      return;
    }
    final text = '[${section.label}]\n$content';
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    MoeToast.success(context, '已复制${section.label}');
  }

  Future<void> _copyAllSections(List<_PayloadSection> sections) async {
    final copyable = sections.where((section) {
      final content = section.content.trim();
      return content.isNotEmpty && content != '(空)';
    }).toList(growable: false);
    if (copyable.isEmpty) {
      MoeToast.info(context, '当前事件暂无可复制内容');
      return;
    }

    final buffer = StringBuffer();
    for (var i = 0; i < copyable.length; i++) {
      final section = copyable[i];
      buffer.writeln('[${section.label}]');
      buffer.writeln(section.content.trim());
      if (i != copyable.length - 1) {
        buffer.writeln('---');
      }
    }

    await Clipboard.setData(ClipboardData(text: buffer.toString().trim()));
    if (!mounted) return;
    MoeToast.success(context, '已复制${copyable.length}个区块');
  }

  Widget _buildTabChip(
    BuildContext context, {
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final colors = context.moeColors;
    final textColor = selected ? Colors.white : colors.text;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? colors.primary : colors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? colors.primary : colors.borderLight,
            width: borderWidth,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: textColor,
            fontSize: 11,
            fontWeight:
                selected ? MoeFontWeights.emphasis : MoeFontWeights.normal,
          ),
        ),
      ),
    );
  }

  Map<String, dynamic> _resolvePayloadRoot(Map<String, dynamic>? envelope) {
    if (envelope == null || envelope.isEmpty) {
      return const <String, dynamic>{};
    }
    final payload = envelope['payload'];
    if (payload is Map<String, dynamic>) return payload;
    if (payload is Map) return payload.cast<String, dynamic>();
    return envelope;
  }

  List<_PayloadSection> _buildSections(
    Map<String, dynamic> payload,
    TraceEvent? event,
  ) {
    final rawRequestValue = _readByKeys(
        payload, const ['rawRequestBody', 'requestBody', 'request']);
    final rawReplyValue =
        _readByKeys(payload, const ['rawAiResponse', 'reply', 'finalReply']);
    final rawReplyContent = _stringifyPayload(rawReplyValue);
    final deliveredReplyValue = _readByKeys(payload, const ['finalReply']);
    final deliveredReplyContent = _stringifyPayload(deliveredReplyValue);
    final requestBody = _decodeJsonMap(rawRequestValue) ??
        _decodeJsonMap(_readByKeys(payload, const ['requestBody'])) ??
        _decodeJsonMap(_readByKeys(payload, const ['request']));

    final sections = <_PayloadSection>[
      _PayloadSection(
        label: '运行时背景',
        content: _stringifyPayload(
          _readByKeys(payload, const ['runtimeContext']),
        ),
      ),
      _PayloadSection(
        label: '上下文装配',
        content: _stringifyPayload(
          _readByKeys(payload, const ['promptAssembly']),
        ),
      ),
      _PayloadSection(
        label: '错误信息',
        content: _extractErrorDetails(payload, event),
      ),
      _PayloadSection(
        label: '系统提示词',
        content: _extractSystemPrompts(payload, requestBody),
      ),
      _PayloadSection(
        label: '工具清单',
        content: _extractToolCatalog(requestBody),
      ),
      _PayloadSection(
        label: '上下文',
        content: _stringifyPayload(
          _readByKeys(payload, const ['rawContext', 'context', 'messages']),
        ),
      ),
      _PayloadSection(
        label: '请求体',
        content: _stringifyPayload(rawRequestValue),
      ),
      _PayloadSection(
        label: '响应体',
        content: _stringifyPayload(
          _readByKeys(
            payload,
            const ['rawResponseBody', 'responseBody', 'response'],
          ),
        ),
      ),
      _PayloadSection(
        label: '工具调用',
        content: _stringifyPayload(
          _readByKeys(payload, const ['rawToolCalls', 'toolCalls']),
        ),
      ),
      _PayloadSection(
        label: '工具结果',
        content: _stringifyPayload(
          _readByKeys(payload, const ['rawToolResults', 'toolResults']),
        ),
      ),
      _PayloadSection(
        label: '最终回复',
        content: rawReplyContent,
      ),
      if (deliveredReplyContent != '(空)' &&
          deliveredReplyContent != rawReplyContent)
        _PayloadSection(
          label: '最终交付文本',
          content: deliveredReplyContent,
        ),
    ].where((section) => !section.isEmpty).toList(growable: false);

    if (sections.isNotEmpty) {
      return sections;
    }

    return const <_PayloadSection>[
      _PayloadSection(label: '详情', content: '(空)'),
    ];
  }

  String _stringifyPayload(dynamic value) {
    if (value == null) return '(空)';
    if (value is String) {
      final trimmed = value.trim();
      if (trimmed.isEmpty) return '(空)';
      return tryFormatJson(trimmed);
    }
    if (value is Map || value is List) {
      try {
        return const JsonEncoder.withIndent('  ').convert(value);
      } catch (_) {
        return value.toString();
      }
    }
    return value.toString();
  }

  dynamic _readByKeys(Map<String, dynamic> payload, List<String> keys) {
    for (final key in keys) {
      if (!payload.containsKey(key)) continue;
      return payload[key];
    }
    return null;
  }

  Map<String, dynamic>? _decodeJsonMap(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return value.cast<String, dynamic>();
    if (value is! String) return null;
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return decoded.cast<String, dynamic>();
      return null;
    } catch (_) {
      return null;
    }
  }

  List<dynamic>? _decodeJsonList(dynamic value) {
    if (value is List) return value;
    if (value is! String) return null;
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is List) return decoded;
      return null;
    } catch (_) {
      return null;
    }
  }

  String _extractSystemPrompts(
    Map<String, dynamic> payload,
    Map<String, dynamic>? requestBody,
  ) {
    final systems = <Map<String, dynamic>>[];

    void collectFromMessages(dynamic rawMessages) {
      if (rawMessages is! List) return;
      for (var i = 0; i < rawMessages.length; i++) {
        final message = rawMessages[i];
        if (message is! Map) continue;
        final map = message.cast<String, dynamic>();
        final role = map['role']?.toString() ?? '';
        if (role != 'system') continue;
        systems.add({
          'index': i,
          'content': map['content'],
        });
      }
    }

    void collectTopLevelSystem(dynamic rawSystem, String source) {
      final text = _extractSystemText(rawSystem);
      if (text == null || text.isEmpty) return;
      systems.add({
        'source': source,
        'content': text,
      });
    }

    collectFromMessages(requestBody?['messages']);
    collectTopLevelSystem(requestBody?['system'], 'request.system');
    collectTopLevelSystem(
      requestBody?['systemInstruction'],
      'request.systemInstruction',
    );
    if (systems.isEmpty) {
      final rawContext = _readByKeys(payload, const ['rawContext', 'context']);
      collectFromMessages(_decodeJsonList(rawContext));
    }

    if (systems.isEmpty) return '(空)';
    return const JsonEncoder.withIndent('  ').convert(systems);
  }

  String? _extractSystemText(dynamic raw) {
    if (raw == null) return null;
    if (raw is String) {
      final trimmed = raw.trim();
      return trimmed.isEmpty ? null : trimmed;
    }
    if (raw is List) {
      final parts = raw
          .map(_extractSystemText)
          .whereType<String>()
          .where((part) => part.trim().isNotEmpty)
          .toList();
      if (parts.isEmpty) return null;
      return parts.join('\n');
    }
    if (raw is Map) {
      final map = raw.cast<String, dynamic>();
      final fromText = _extractSystemText(map['text']);
      if (fromText != null && fromText.isNotEmpty) return fromText;
      final fromContent = _extractSystemText(map['content']);
      if (fromContent != null && fromContent.isNotEmpty) return fromContent;
      final fromParts = _extractGeminiPartsText(map['parts']);
      if (fromParts != null && fromParts.isNotEmpty) return fromParts;
    }
    return null;
  }

  String? _extractGeminiPartsText(dynamic rawParts) {
    if (rawParts is! List) return null;
    final texts = <String>[];
    for (final part in rawParts) {
      if (part is! Map) continue;
      final text = part['text']?.toString().trim() ?? '';
      if (text.isNotEmpty) {
        texts.add(text);
      }
    }
    if (texts.isEmpty) return null;
    return texts.join('\n');
  }

  String _extractToolCatalog(Map<String, dynamic>? requestBody) {
    if (requestBody == null) return '(空)';
    final rawTools = requestBody['tools'];
    if (rawTools is! List || rawTools.isEmpty) return '(空)';

    final catalog = <Map<String, dynamic>>[];
    var catalogIndex = 0;

    void addCatalogEntry({
      required String source,
      String? type,
      String? name,
      dynamic description,
      dynamic parameters,
      dynamic raw,
    }) {
      catalog.add({
        'index': catalogIndex++,
        'source': source,
        'type': type ?? 'function',
        if (name != null && name.trim().isNotEmpty) 'name': name,
        if (description != null) 'description': description,
        if (parameters != null) 'parameters': parameters,
        if (raw != null) 'raw': raw,
      });
    }

    for (final rawTool in rawTools) {
      if (rawTool is! Map) continue;
      final tool = rawTool.cast<String, dynamic>();
      final function = tool['function'];
      if (function is Map) {
        final fn = function.cast<String, dynamic>();
        addCatalogEntry(
          source: 'openai.tools',
          type: tool['type']?.toString(),
          name: fn['name']?.toString(),
          description: fn['description'],
          parameters: fn['parameters'],
        );
        continue;
      }

      final declarations = tool['functionDeclarations'];
      if (declarations is List && declarations.isNotEmpty) {
        for (final rawDeclaration in declarations) {
          if (rawDeclaration is! Map) continue;
          final declaration = rawDeclaration.cast<String, dynamic>();
          addCatalogEntry(
            source: 'gemini.functionDeclarations',
            type: 'function',
            name: declaration['name']?.toString(),
            description: declaration['description'],
            parameters: declaration['parameters'],
          );
        }
        continue;
      }

      final toolName = tool['name']?.toString();
      final toolParameters = tool['input_schema'] ?? tool['parameters'];
      if (toolName != null && toolName.trim().isNotEmpty) {
        addCatalogEntry(
          source: 'provider.tools',
          type: tool['type']?.toString() ?? 'function',
          name: toolName,
          description: tool['description'],
          parameters: toolParameters,
        );
        continue;
      }

      addCatalogEntry(
        source: 'provider.tools',
        type: tool['type']?.toString(),
        raw: tool,
      );
    }
    if (catalog.isEmpty) {
      return _stringifyPayload(rawTools);
    }
    return const JsonEncoder.withIndent('  ').convert(catalog);
  }

  String _extractErrorDetails(Map<String, dynamic> payload, TraceEvent? event) {
    final errorInfo = <String, dynamic>{};

    if (event != null) {
      if (event.status == TraceEventStatus.failed.value) {
        errorInfo['status'] = event.status;
        errorInfo['stage'] = event.stage;
        errorInfo['source'] = event.source;
        errorInfo['eventSeq'] = event.eventSeq;
        errorInfo['roundIndex'] = event.roundIndex;
      }
      if (event.meta != null && event.meta!.isNotEmpty) {
        errorInfo['eventMeta'] = event.meta;
      }
    }

    final directError = _readByKeys(
      payload,
      const ['error', 'errorMessage', 'exception', 'exceptionMessage'],
    );
    if (directError != null && directError.toString().trim().isNotEmpty) {
      errorInfo['error'] = directError;
    }

    final rawResponseValue = _readByKeys(
      payload,
      const ['rawResponseBody', 'responseBody', 'response'],
    );
    final rawResponseMap = _decodeJsonMap(rawResponseValue);
    if (rawResponseMap != null && rawResponseMap.isNotEmpty) {
      final vendorError = _firstNonEmptyValue([
        rawResponseMap['error'],
        rawResponseMap['message'],
        rawResponseMap['detail'],
        rawResponseMap['error_message'],
        rawResponseMap['error_description'],
      ]);
      if (vendorError != null) {
        errorInfo['vendorError'] = vendorError;
      }
      if (event?.status == TraceEventStatus.failed.value ||
          vendorError != null) {
        errorInfo['rawResponseBody'] = rawResponseMap;
      }
    } else if (rawResponseValue != null &&
        rawResponseValue.toString().trim().isNotEmpty &&
        event?.status == TraceEventStatus.failed.value) {
      errorInfo['rawResponseBody'] = rawResponseValue.toString();
    }

    if (errorInfo.isEmpty) return '(空)';
    return const JsonEncoder.withIndent('  ').convert(errorInfo);
  }

  dynamic _firstNonEmptyValue(Iterable<dynamic> values) {
    for (final value in values) {
      if (value == null) continue;
      final text = value.toString().trim();
      if (text.isNotEmpty) return value;
    }
    return null;
  }
}

class _PayloadSection {
  final String label;
  final String content;

  const _PayloadSection({required this.label, required this.content});

  bool get isEmpty => content == '(空)';
}
