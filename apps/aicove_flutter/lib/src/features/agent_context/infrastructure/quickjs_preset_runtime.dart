import 'dart:convert';
import 'dart:math';
import 'package:aicove_quickjs/aicove_quickjs.dart';
import 'package:flutter/services.dart';
import '../domain/preset_script_runtime.dart';

/// Executes the original preset callbacks in a request-owned headless host.
class QuickJsPresetRuntime implements PresetScriptRuntime {
  final QuickJsSession _session;
  @override
  final List<Map<String, dynamic>> businessTools;
  @override
  final List<Map<String, dynamic>> transportTools;
  @override
  final List<String> diagnostics;
  @override
  List<Map<String, dynamic>> get tools => [...businessTools, ...transportTools];
  @override
  String? get toolChoice => transportTools.isEmpty ? null : 'auto';
  QuickJsPresetRuntime._(
    this._session,
    this.businessTools,
    this.transportTools,
    this.diagnostics,
  );

  static Future<QuickJsPresetRuntime> open(
    PresetScriptSnapshot snapshot,
  ) async {
    final session = await QuickJsSession.open();
    try {
      await session.evaluate(
        await rootBundle.loadString('assets/preset_runtime/spreset.js'),
      );
      final result =
          jsonDecode(
                await session.evaluate(
                  '__spreset.init(${snapshot.json}).then(v=>JSON.stringify(v))',
                ),
              )
              as Map;
      final tools = (result['tools'] as List)
          .map((t) => Map<String, dynamic>.from(t as Map))
          .toList();
      if (tools.isNotEmpty && !snapshot.toolsAllowed) {
        throw StateError('当前模型未启用工具调用，无法运行此预设的输出协议');
      }
      await session.evaluate(
        await rootBundle.loadString('assets/preset_runtime/transport.js'),
      );
      final input = jsonDecode(snapshot.json) as Map;
      final random = Random.secure();
      final suffix = List.generate(
        12,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      final transportInput = {
        'config': input['transport'],
        'name': 'emit_complete_response_$suffix',
        'modelSupportsTools': snapshot.modelSupportsTools,
      };
      final transport =
          jsonDecode(
                await session.evaluate(
                  'JSON.stringify(__transport.init(${jsonEncode(transportInput)}))',
                ),
              )
              as Map;
      return QuickJsPresetRuntime._(
        session,
        List.unmodifiable(tools),
        List.unmodifiable(
          (transport['tools'] as List).map(
            (t) => Map<String, dynamic>.from(t as Map),
          ),
        ),
        List.unmodifiable((transport['diagnostics'] as List).cast<String>()),
      );
    } catch (_) {
      await session.close();
      rethrow;
    }
  }

  Future<dynamic> _call(String method, Object? input) async => jsonDecode(
    await _session.evaluate(
      'Promise.resolve(__spreset.$method(${jsonEncode(input)})).then(v=>JSON.stringify(v))',
    ),
  );

  @override
  Future<List<Map<String, dynamic>>> prepare(
    List<Map<String, dynamic>> messages,
  ) async {
    final prepared = await _call('prepare', messages);
    final result =
        jsonDecode(
              await _session.evaluate(
                'JSON.stringify(__transport.prepare(${jsonEncode(prepared)}))',
              ),
            )
            as List;
    return result.map((m) => Map<String, dynamic>.from(m as Map)).toList();
  }

  @override
  Future<String> action(String name, Map<String, dynamic> arguments) async =>
      await _call('action', {'name': name, 'args': arguments}) as String;
  @override
  Future<void> reset(bool streaming) async {
    await _call('reset', streaming);
  }

  @override
  Future<String> update(
    String cumulativeText, {
    List<Map<String, dynamic>> calls = const [],
  }) async {
    if (transportTools.isNotEmpty) {
      final selected =
          jsonDecode(
                await _session.evaluate(
                  'JSON.stringify(__transport.response(${jsonEncode({'text': cumulativeText, 'calls': calls})}))',
                ),
              )
              as Map;
      cumulativeText = selected['text'] as String;
    }
    return (await _call('update', {
          'text': cumulativeText,
          'final': false,
        }))['output']
        as String;
  }

  @override
  Future<({String text, Set<String> consumedIds, Set<int> consumedIndexes})>
  response(String text, List<Map<String, dynamic>> calls) async {
    final transport =
        jsonDecode(
              await _session.evaluate(
                'JSON.stringify(__transport.response(${jsonEncode({'text': text, 'calls': calls})}))',
              ),
            )
            as Map;
    final indexes = (transport['consumedIndexes'] as List).cast<int>().toSet();
    final remainingIndexes = [
      for (var i = 0; i < calls.length; i++)
        if (!indexes.contains(i)) i,
    ];
    final result =
        await _call('response', {
              'text': transport['text'],
              'calls': [for (final i in remainingIndexes) calls[i]],
            })
            as Map;
    for (final index in (result['consumedIndexes'] as List).cast<int>()) {
      indexes.add(remainingIndexes[index]);
    }
    return (
      text: result['output'] as String,
      consumedIds: {for (final i in indexes) calls[i]['id'] as String},
      consumedIndexes: indexes,
    );
  }

  @override
  Future<void> close() => _session.close();
}
