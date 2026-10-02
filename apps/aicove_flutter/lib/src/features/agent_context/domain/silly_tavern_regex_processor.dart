library;

import 'dart:async';
import 'dart:convert';
import 'package:aicove_quickjs/aicove_quickjs.dart';

import 'silly_tavern_preset.dart';
import 'silly_tavern_world_book.dart';

class SillyTavernRegexApplyResult {
  final String text;
  final List<Map<String, dynamic>> traces;
  final List<String> warnings;

  const SillyTavernRegexApplyResult({
    required this.text,
    required this.traces,
    required this.warnings,
  });
}

class SillyTavernRegexMessagesResult {
  final List<Map<String, dynamic>> messages;
  final List<Map<String, dynamic>> traces;
  final List<String> warnings;

  const SillyTavernRegexMessagesResult({
    required this.messages,
    required this.traces,
    required this.warnings,
  });
}

/// 在独立 isolate 中执行已授权的 SillyTavern regex。
///
/// QuickJS 在后台 isolate 执行，以引擎中断和内存限额约束正则。
class SillyTavernRegexProcessor {
  static const Duration executionTimeout = Duration(milliseconds: 1500);
  static const int maxInputCharacters = 512 * 1024;
  static const int maxPatternCharacters = 32 * 1024;
  static const int maxReplacementCharacters = 1024 * 1024;

  const SillyTavernRegexProcessor();

  Future<SillyTavernRegexMessagesResult> applyToPromptMessages({
    required List<Map<String, dynamic>> messages,
    required List<SillyTavernRegexScript> scripts,
    required bool authorized,
  }) async {
    final copied = messages
        .map((message) => _copyMessage(message))
        .toList(growable: false);
    if (scripts.isEmpty) {
      return SillyTavernRegexMessagesResult(
        messages: copied,
        traces: const <Map<String, dynamic>>[],
        warnings: const <String>[],
      );
    }
    if (!authorized) {
      return SillyTavernRegexMessagesResult(
        messages: copied,
        traces: const <Map<String, dynamic>>[
          <String, dynamic>{
            'status': 'skipped',
            'reason': 'authorization_required',
          },
        ],
        warnings: const <String>['regex 未授权，本轮未改写 prompt 副本'],
      );
    }

    final nonSystemIndexes = <int>[
      for (var index = 0; index < copied.length; index++)
        if (copied[index]['role'] != 'system') index,
    ];
    final depthByIndex = <int, int>{
      for (
        var logicalIndex = 0;
        logicalIndex < nonSystemIndexes.length;
        logicalIndex++
      )
        nonSystemIndexes[logicalIndex]:
            nonSystemIndexes.length - logicalIndex - 1,
    };
    final items = <Map<String, dynamic>>[];
    for (var messageIndex = 0; messageIndex < copied.length; messageIndex++) {
      final message = copied[messageIndex];
      final role = message['role']?.toString();
      final placement = role == 'user'
          ? 1
          : role == 'assistant'
          ? 2
          : null;
      if (placement == null) continue;
      _collectContentItems(
        items,
        messageIndex: messageIndex,
        content: message['content'],
        placement: placement,
        depth: depthByIndex[messageIndex] ?? 0,
        modes: const <String>['raw', 'prompt'],
      );
      final reasoning = message['reasoning_content'];
      if (reasoning is String) {
        items.add(<String, dynamic>{
          'key': 'm$messageIndex.reasoning',
          'text': reasoning,
          'placement': 6,
          'depth': depthByIndex[messageIndex] ?? 0,
          'modes': const <String>['raw', 'prompt'],
        });
      }
    }
    final execution = await _execute(items, scripts);
    _applyWorkerItems(copied, execution.items);
    return SillyTavernRegexMessagesResult(
      messages: List.unmodifiable(copied),
      traces: List.unmodifiable(execution.traces),
      warnings: List.unmodifiable(execution.warnings),
    );
  }

  /// WORLD_INFO placement=5，只处理命中世界书的请求副本。
  Future<TavernWorldScanResult> applyToWorldInfo({
    required TavernWorldScanResult scan,
    required List<SillyTavernRegexScript> scripts,
    required bool authorized,
  }) async {
    if (!authorized || scripts.isEmpty || scan.injections.isEmpty) return scan;
    final execution = await _execute([
      for (final entry in scan.injections)
        <String, dynamic>{
          'key': entry.id,
          'text': entry.content,
          'placement': 5,
          'depth': entry.position == 4 ? entry.depth : -1,
          'modes': const ['prompt'],
        },
    ], scripts);
    final transformed = {
      for (final item in execution.items) item['key']: item['text'] as String,
    };
    return TavernWorldScanResult(
      [
        for (final entry in scan.injections)
          entry.withContent(transformed[entry.id] ?? entry.content),
      ],
      [...scan.traces, ...execution.traces],
      [...scan.warnings, ...execution.warnings],
    );
  }

  Future<SillyTavernRegexApplyResult> applyToDisplayText({
    required String text,
    required List<SillyTavernRegexScript> scripts,
    required bool authorized,
    int depth = 0,
  }) async {
    if (scripts.isEmpty) {
      return SillyTavernRegexApplyResult(
        text: text,
        traces: const <Map<String, dynamic>>[],
        warnings: const <String>[],
      );
    }
    if (!authorized) {
      return SillyTavernRegexApplyResult(
        text: text,
        traces: const <Map<String, dynamic>>[
          <String, dynamic>{
            'status': 'skipped',
            'reason': 'authorization_required',
          },
        ],
        warnings: const <String>['regex 未授权，本轮未改写显示副本'],
      );
    }
    final execution = await _execute(<Map<String, dynamic>>[
      <String, dynamic>{
        'key': 'display',
        'text': text,
        'placement': 2,
        'depth': depth,
        'modes': const <String>['raw', 'markdown'],
      },
    ], scripts);
    final rendered = execution.items.isEmpty
        ? text
        : execution.items.first['text']?.toString() ?? text;
    return SillyTavernRegexApplyResult(
      text: rendered,
      traces: List.unmodifiable(execution.traces),
      warnings: List.unmodifiable(execution.warnings),
    );
  }

  Map<String, dynamic> _copyMessage(Map<String, dynamic> source) {
    final copy = Map<String, dynamic>.from(source);
    final content = copy['content'];
    if (content is List) {
      copy['content'] = content
          .map((part) => part is Map ? Map<String, dynamic>.from(part) : part)
          .toList(growable: false);
    }
    return copy;
  }

  void _collectContentItems(
    List<Map<String, dynamic>> items, {
    required int messageIndex,
    required dynamic content,
    required int placement,
    required int depth,
    required List<String> modes,
  }) {
    if (content is String) {
      items.add(<String, dynamic>{
        'key': 'm$messageIndex.content',
        'text': content,
        'placement': placement,
        'depth': depth,
        'modes': modes,
      });
      return;
    }
    if (content is! List) return;
    for (var partIndex = 0; partIndex < content.length; partIndex++) {
      final part = content[partIndex];
      if (part is! Map || part['type'] != 'text' || part['text'] is! String) {
        continue;
      }
      items.add(<String, dynamic>{
        'key': 'm$messageIndex.part$partIndex',
        'text': part['text'],
        'placement': placement,
        'depth': depth,
        'modes': modes,
      });
    }
  }

  void _applyWorkerItems(
    List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>> items,
  ) {
    final messagePattern = RegExp(r'^m(\d+)\.(content|reasoning|part(\d+))$');
    for (final item in items) {
      final match = messagePattern.firstMatch(item['key']?.toString() ?? '');
      if (match == null) continue;
      final messageIndex = int.parse(match.group(1)!);
      if (messageIndex < 0 || messageIndex >= messages.length) continue;
      final text = item['text']?.toString() ?? '';
      final target = match.group(2)!;
      if (target == 'content') {
        messages[messageIndex]['content'] = text;
      } else if (target == 'reasoning') {
        messages[messageIndex]['reasoning_content'] = text;
      } else {
        final partIndex = int.parse(match.group(3)!);
        final content = messages[messageIndex]['content'];
        if (content is! List || partIndex >= content.length) continue;
        final part = content[partIndex];
        if (part is Map) part['text'] = text;
      }
    }
  }

  Future<_RegexWorkerResult> _execute(
    List<Map<String, dynamic>> items,
    List<SillyTavernRegexScript> scripts,
  ) async {
    if (items.isEmpty) {
      return const _RegexWorkerResult(
        items: <Map<String, dynamic>>[],
        traces: <Map<String, dynamic>>[],
        warnings: <String>[],
      );
    }
    QuickJsSession? session;
    try {
      session = await QuickJsSession.open();
      return _RegexWorkerResult.fromJson(
        await _runRegexBatch(session, {
          'items': items,
          'scripts': scripts.map((script) => script.toWorkerJson()).toList(),
          'maxInputCharacters': maxInputCharacters,
          'maxPatternCharacters': maxPatternCharacters,
          'maxReplacementCharacters': maxReplacementCharacters,
        }),
      );
    } on TimeoutException {
      return _RegexWorkerResult(
        items: items,
        traces: const <Map<String, dynamic>>[
          <String, dynamic>{'status': 'error', 'reason': 'execution_timeout'},
        ],
        warnings: const <String>['regex 执行超过 1500ms，已终止并保留原文'],
      );
    } catch (error) {
      return _RegexWorkerResult(
        items: items,
        traces: <Map<String, dynamic>>[
          <String, dynamic>{
            'status': 'error',
            'reason': 'worker_failure',
            'errorType': error.runtimeType.toString(),
          },
        ],
        warnings: const <String>['regex 执行异常，已保留原文'],
      );
    } finally {
      await session?.close();
    }
  }
}

class _RegexWorkerResult {
  final List<Map<String, dynamic>> items;
  final List<Map<String, dynamic>> traces;
  final List<String> warnings;

  const _RegexWorkerResult({
    required this.items,
    required this.traces,
    required this.warnings,
  });

  factory _RegexWorkerResult.fromJson(Map<String, dynamic> json) {
    return _RegexWorkerResult(
      items: (json['items'] as List? ?? const <dynamic>[])
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList(growable: false),
      traces: (json['traces'] as List? ?? const <dynamic>[])
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList(growable: false),
      warnings: (json['warnings'] as List? ?? const <dynamic>[])
          .map((item) => item.toString())
          .toList(growable: false),
    );
  }
}

Future<Map<String, dynamic>> _runRegexBatch(
  QuickJsSession session,
  Map<String, dynamic> payload,
) async {
  final stopwatch = Stopwatch()..start();
  final items = (payload['items'] as List? ?? const <dynamic>[])
      .whereType<Map>()
      .map((item) => Map<String, dynamic>.from(item))
      .toList(growable: false);
  final scripts = (payload['scripts'] as List? ?? const <dynamic>[])
      .whereType<Map>()
      .map((item) => Map<String, dynamic>.from(item))
      .toList(growable: false);
  final maxInputCharacters = payload['maxInputCharacters'] as int;
  final maxPatternCharacters = payload['maxPatternCharacters'] as int;
  final maxReplacementCharacters = payload['maxReplacementCharacters'] as int;
  final traces = <Map<String, dynamic>>[];
  final warnings = <String>[];
  final outputItems = <Map<String, dynamic>>[];
  for (final item in items) {
    var text = item['text']?.toString() ?? '';
    if (text.length > maxInputCharacters) {
      traces.add(<String, dynamic>{
        'key': item['key'],
        'status': 'skipped',
        'reason': 'input_too_large',
      });
      warnings.add('${item['key']} 超过 regex 输入上限，已保留原文');
      outputItems.add(<String, dynamic>{...item, 'text': text});
      continue;
    }
    final modes = (item['modes'] as List? ?? const <dynamic>[])
        .map((mode) => mode.toString())
        .toList(growable: false);
    modeLoop:
    for (final mode in modes) {
      for (final script in scripts) {
        // SillyTavern's runRegexScript returns immediately for an empty
        // source. Once an earlier script removes the whole message, later
        // scripts must not repopulate it with a ^$ replacement.
        if (text.isEmpty) break modeLoop;
        final decision = _regexDecision(
          script,
          placement: item['placement'] as int,
          depth: item['depth'] as int,
          mode: mode,
        );
        if (!decision.run) {
          if (decision.trace) {
            traces.add(<String, dynamic>{
              'key': item['key'],
              'scriptId': script['id'],
              'scriptName': script['name'],
              'mode': mode,
              'status': 'skipped',
              'reason': decision.reason,
            });
          }
          continue;
        }
        final findRegex = script['findRegex']?.toString() ?? '';
        final rawReplaceString = script['replaceString']?.toString() ?? '';
        final replaceString = _sanitizeReplacementMarkup(rawReplaceString);
        final executableMarkupRemoved = replaceString != rawReplaceString;
        if (executableMarkupRemoved) {
          warnings.add('${script['name']} 的可执行 HTML 已移除，只保留静态替换内容');
        }
        if (findRegex.length > maxPatternCharacters ||
            replaceString.length > maxReplacementCharacters) {
          traces.add(<String, dynamic>{
            'key': item['key'],
            'scriptId': script['id'],
            'scriptName': script['name'],
            'mode': mode,
            'status': 'error',
            'reason': 'script_too_large',
          });
          warnings.add('${script['name']} 超过 regex 安全上限，已跳过');
          continue;
        }
        try {
          if (stopwatch.elapsed > SillyTavernRegexProcessor.executionTimeout) {
            throw TimeoutException('regex batch timeout');
          }
          final before = text;
          final value =
              jsonDecode(
                    await session.evaluate(
                      '($_jsReplace)(${jsonEncode({'text': text, 'source': findRegex, 'replacement': replaceString, 'trim': script['trimStrings'] ?? [], 'maxOutput': maxInputCharacters})})',
                    ),
                  )
                  as Map;
          if (value['error'] != null) {
            throw FormatException(value['error'] as String);
          }
          text = value['text'] as String;
          traces.add(<String, dynamic>{
            'key': item['key'],
            'scriptId': script['id'],
            'scriptName': script['name'],
            'source': script['source'],
            'mode': mode,
            'status': 'applied',
            'changed': before != text,
            if (executableMarkupRemoved) 'executableMarkupRemoved': true,
          });
        } on QuickJsException {
          rethrow;
        } on TimeoutException {
          rethrow;
        } catch (error) {
          traces.add(<String, dynamic>{
            'key': item['key'],
            'scriptId': script['id'],
            'scriptName': script['name'],
            'mode': mode,
            'status': 'error',
            'reason': 'invalid_regex',
            'errorType': error.runtimeType.toString(),
          });
          warnings.add('${script['name']} 无法编译，已跳过');
        }
      }
    }
    outputItems.add(<String, dynamic>{...item, 'text': text});
  }
  return <String, dynamic>{
    'items': outputItems,
    'traces': traces,
    'warnings': warnings.toSet().toList(growable: false),
  };
}

// SillyTavern uses its own $0 / {{match}} / trimStrings replacement contract.
// Compile and match in JavaScript without translating patterns to Dart RegExp.
const _jsReplace = r'''function(input) {
  let pattern = input.source, flags = '';
  if (pattern.startsWith('/')) {
    let end = -1;
    for(let i=pattern.length-1;i>0;i--) {
      if(pattern[i] !== '/') continue;
      let n=0; for(let j=i-1;j>=0 && pattern[j]==='\\';j--) n++;
      if(n%2===0) { end=i; break; }
    }
    if(end<1) return JSON.stringify({error:'Missing regex slash'});
    flags=pattern.slice(end+1); pattern=pattern.slice(1,end);
  }
  let re;
  try { re=new RegExp(pattern,flags); }
  catch(e) { return JSON.stringify({error:String(e)}); }
  const replacement=input.replacement.replace(/{{match}}/gi,'$0');
  const text=input.text.replace(re,(...args)=>{
    const groups=typeof args[args.length-1]==='object' ? args.pop() : {};
    const captures=args.slice(0,-2);
    return replacement.replace(/\$(\d+)|\$<([^>]+)>/g,(_,number,name)=>{
      let value=(number !== undefined ? captures[Number(number)] : groups[name]) ?? '';
      for(const trim of input.trim) value=value.split(trim).join('');
      return value;
    });
  });
  if(text.length>input.maxOutput) throw Error('Regex output limit exceeded');
  return JSON.stringify({text});
}''';

({bool run, bool trace, String reason}) _regexDecision(
  Map<String, dynamic> script, {
  required int placement,
  required int depth,
  required String mode,
}) {
  final placements = (script['placements'] as List? ?? const <dynamic>[])
      .whereType<int>()
      .toSet();
  if (!placements.contains(placement)) {
    return (run: false, trace: false, reason: 'placement_mismatch');
  }
  if (script['disabled'] == true) {
    return (run: false, trace: true, reason: 'disabled');
  }
  if ((script['substituteRegex'] as int? ?? 0) != 0) {
    return (run: false, trace: true, reason: 'substitute_regex_unsupported');
  }
  final minDepth = script['minDepth'] as int?;
  if (depth >= 0 && minDepth != null && minDepth >= -1 && depth < minDepth) {
    return (run: false, trace: true, reason: 'below_min_depth');
  }
  final maxDepth = script['maxDepth'] as int?;
  if (depth >= 0 && maxDepth != null && maxDepth >= 0 && depth > maxDepth) {
    return (run: false, trace: true, reason: 'above_max_depth');
  }
  final markdownOnly = script['markdownOnly'] == true;
  final promptOnly = script['promptOnly'] == true;
  final contextMatches = switch (mode) {
    'markdown' => markdownOnly,
    'prompt' => promptOnly,
    _ => !markdownOnly && !promptOnly,
  };
  return contextMatches
      ? (run: true, trace: true, reason: '')
      : (run: false, trace: false, reason: 'phase_mismatch');
}

String _sanitizeReplacementMarkup(String source) {
  var sanitized = source.replaceAll(
    RegExp(r'<script\b[^>]*>[\s\S]*?<\/script\s*>', caseSensitive: false),
    '',
  );
  sanitized = sanitized.replaceAll(
    RegExp(
      r'''\s+on[a-z]+\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)''',
      caseSensitive: false,
    ),
    '',
  );
  sanitized = sanitized.replaceAll(
    RegExp(r'javascript\s*:', caseSensitive: false),
    '',
  );
  return sanitized;
}
