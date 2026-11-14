import '../../../core/api/tool_media.dart';
import '../../../core/network/public_network.dart';
import 'dart:convert';
import 'dart:math';
import 'package:aicove_quickjs/aicove_quickjs.dart';
import 'package:flutter/services.dart';
import '../domain/preset_script_runtime.dart';

/// Executes the original preset callbacks in a request-owned headless host.
class QuickJsPresetRuntime
    implements PresetScriptRuntime, PresetToolAwareRuntime {
  final QuickJsSession _session;
  final PublicNetwork _network;
  bool _closed = false;
  static final Map<String, String> _persistentStorage = {};
  final bool _toolsAllowed;
  String? _toolChoice;
  @override
  List<Map<String, dynamic>> businessTools;
  @override
  List<Map<String, dynamic>> transportTools;
  @override
  List<String> diagnostics;
  @override
  List<Map<String, dynamic>> get tools => [...businessTools, ...transportTools];
  @override
  String? get toolChoice => _toolChoice;
  QuickJsPresetRuntime._(
    this._session,
    this._network,
    this.businessTools,
    this.transportTools,
    this.diagnostics,
    this._toolsAllowed,
    this._toolChoice,
  );

  static Future<QuickJsPresetRuntime> open(
    PresetScriptSnapshot snapshot, {
    PublicNetwork Function()? networkFactory,
    Map<String, String>? initialStorage,
    void Function(Map<String, String>)? onStorageChanged,
  }) async {
    _persistentStorage.addAll(initialStorage ?? {});
    final network = networkFactory?.call() ?? PublicNetwork();
    late QuickJsSession session;
    try {
      session = await QuickJsSession.open(
        heapBytes: 256 * 1024 * 1024,
        maxSourceBytes: 32 * 1024 * 1024,
        timeout: const Duration(seconds: 30),
        hostCall: (method, args, isActive) async {
          switch (method) {
            case 'sleep':
              await Future<void>.delayed(
                Duration(
                  milliseconds: (args[0] as num).toInt().clamp(0, 30000),
                ),
              );
              return null;
            case 'storageSnapshot':
              return Map<String, String>.of(_persistentStorage);
            case 'storageSet':
              _persistentStorage[args[0] as String] = args[1] as String;
            case 'storageRemove':
              _persistentStorage.remove(args[0] as String);
            case 'storageClear':
              _persistentStorage.clear();
            case 'fetch':
              final request = Map<String, dynamic>.from(args[0] as Map);
              final response = await network.fetch(
                Uri.parse(request['url'] as String),
                method: request['method'] as String? ?? 'GET',
                headers: Map<String, String>.from(
                  request['headers'] as Map? ?? {},
                ),
                body: request['body'] == null
                    ? null
                    : utf8.encode(request['body'] as String),
                isActive: isActive,
              );
              return {
                'url': response.url.toString(),
                'status': response.status,
                'headers': response.headers,
                'base64': base64Encode(response.bytes),
              };
            default:
              throw StateError('Unknown host call: $method');
          }
          onStorageChanged?.call(Map.of(_persistentStorage));
          return null;
        },
      );
    } catch (_) {
      network.close();
      rethrow;
    }
    try {
      await session.evaluate(
        await rootBundle.loadString('assets/preset_runtime/spreset.js'),
      );
      final result =
          jsonDecode(
                await session.evaluate(
                  'Promise.resolve(__spreset.init(${jsonEncode(snapshot.rawJson)})).then(v=>JSON.stringify(v))',
                ),
              )
              as Map;
      final tools = (result['tools'] as List)
          .map((t) => Map<String, dynamic>.from(t as Map))
          .toList();
      if (tools.isNotEmpty && !snapshot.toolsAllowed) {
        throw StateError(_toolsDisabledMessage);
      }
      await session.evaluate(
        await rootBundle.loadString('assets/preset_runtime/transport.js'),
      );
      final input = snapshot.rawJson;
      final transportInput = {
        ...input,
        'storage': Map<String, String>.of(_persistentStorage),
        'random': _randomBytes(),
        'callerToolChoice': snapshot.callerToolChoice,
        'modelSupportsTools': snapshot.modelSupportsTools,
        'toolsAllowed': snapshot.toolsAllowed,
      };
      final transport =
          jsonDecode(
                await session.evaluate(
                  'Promise.resolve(__transport.init(${jsonEncode(transportInput)})).then(v=>JSON.stringify(v))',
                ),
              )
              as Map;
      return QuickJsPresetRuntime._(
        session,
        network,
        List.unmodifiable(tools),
        List.unmodifiable(
          (transport['tools'] as List).map(
            (t) => Map<String, dynamic>.from(t as Map),
          ),
        ),
        List.unmodifiable((transport['diagnostics'] as List).cast<String>()),
        snapshot.toolsAllowed,
        transport['toolChoice'] as String?,
      );
    } catch (_) {
      try {
        await session.close();
      } finally {
        network.close();
      }
      rethrow;
    }
  }

  static List<int> _randomBytes() {
    final random = Random.secure();
    return List.generate(4096, (_) => random.nextInt(256));
  }

  static const _toolsDisabledMessage = '当前模型未启用工具调用，无法运行此预设的输出协议';

  void _ensureOpen() {
    if (_closed) throw StateError('预设脚本运行环境已关闭，请重新打开。');
  }

  Future<void> _checkTimerTimeout() async {
    final state =
        jsonDecode(
              await _session.evaluate('JSON.stringify(__transport.state())'),
            )
            as Map;
    diagnostics = List.unmodifiable(
      (state['diagnostics'] as List).cast<String>(),
    );
    if (state['timerExpired'] == true) {
      await close();
      throw StateError('预设脚本定时器回调超时，运行环境已关闭。');
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
  ) => prepareWithTools(messages, tools: const []);

  @override
  Future<List<Map<String, dynamic>>> prepareWithTools(
    List<Map<String, dynamic>> messages, {
    required List<Map<String, dynamic>> tools,
  }) async {
    _ensureOpen();
    final references = PresetImageReferences();
    final transformed =
        await _call('prepare', references.hide(messages)) as List;
    final prepared = references.preserveImages([
      for (final message in transformed)
        Map<String, dynamic>.from(message as Map),
    ]);
    // The preset's final-request script may rewrite this round's tools.
    final roundTools = (await _call('tools', null) as List)
        .map((tool) => Map<String, dynamic>.from(tool as Map))
        .toList();
    if (roundTools.isNotEmpty && !_toolsAllowed) {
      throw StateError(_toolsDisabledMessage);
    }
    businessTools = List.unmodifiable(roundTools);
    final result =
        jsonDecode(
              await _session.evaluate(
                'Promise.resolve(__transport.prepare(${jsonEncode(prepared)}, ${jsonEncode(tools)}, ${jsonEncode(roundTools)})).then(v=>JSON.stringify(v))',
              ),
            )
            as List;
    await _checkTimerTimeout();
    final state =
        jsonDecode(
              await _session.evaluate('JSON.stringify(__transport.state())'),
            )
            as Map;
    final stateTools = (state['tools'] as List)
        .map((tool) => Map<String, dynamic>.from(tool as Map))
        .toList();
    final scriptBusinessTools = (state['businessTools'] as List? ?? const [])
        .map((tool) => Map<String, dynamic>.from(tool as Map))
        .toList();
    businessTools = List.unmodifiable(scriptBusinessTools);
    transportTools = List.unmodifiable(stateTools);
    _toolChoice = state['toolChoice'] as String?;
    diagnostics = List.unmodifiable(
      (state['diagnostics'] as List).cast<String>(),
    );
    final preserved = references.preserveImages([
      for (final message in result) Map<String, dynamic>.from(message as Map),
    ]);
    return (references.restore(preserved) as List)
        .map((m) => Map<String, dynamic>.from(m as Map))
        .toList();
  }

  @override
  Future<String> action(String name, Map<String, dynamic> arguments) async {
    _ensureOpen();
    final hasAction = await _session.evaluate(
      'Boolean(__transport.hasAction(${jsonEncode(name)}))',
    );
    if (hasAction == 'true') {
      final result =
          jsonDecode(
                await _session.evaluate(
                  'Promise.resolve(__transport.action(${jsonEncode({'name': name, 'args': arguments})})).then(v=>JSON.stringify(v))',
                ),
              )
              as String;
      await _checkTimerTimeout();
      return result;
    }
    // Registered transport actions have their own gate; reject ordinary tools
    // here so a permission denial cannot throw inside and close the JS session.
    if (!_toolsAllowed) {
      throw StateError(_toolsDisabledMessage);
    }
    return await _call('action', {'name': name, 'args': arguments}) as String;
  }

  @override
  Future<void> reset(bool streaming) async {
    _ensureOpen();
    await _session.evaluate(
      'Promise.resolve(__transport.reset()).then(v=>JSON.stringify(v))',
    );
    await _call('reset', streaming);
  }

  @override
  Future<String> update(
    String cumulativeText, {
    List<Map<String, dynamic>> calls = const [],
  }) async {
    _ensureOpen();
    {
      final selected =
          jsonDecode(
                await _session.evaluate(
                  'Promise.resolve(__transport.preview(${jsonEncode({'text': cumulativeText, 'calls': calls})})).then(v=>JSON.stringify(v))',
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
    _ensureOpen();
    final transport =
        jsonDecode(
              await _session.evaluate(
                'Promise.resolve(__transport.response(${jsonEncode({'text': text, 'calls': calls})})).then(v=>JSON.stringify(v))',
              ),
            )
            as Map;
    await _checkTimerTimeout();
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
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _network.close();
    await _session.close();
  }
}
