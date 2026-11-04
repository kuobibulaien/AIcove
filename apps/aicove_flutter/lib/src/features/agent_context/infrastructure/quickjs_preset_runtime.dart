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
  final String? _atePrefix;
  String _transportName;
  final _usedTransportNames = <String>{};
  final bool _toolsAllowed;
  final bool _isWave;
  bool get isWaveTransport => _isWave;
  bool _waveActionEnabled = false;
  @override
  List<Map<String, dynamic>> businessTools;
  @override
  List<Map<String, dynamic>> transportTools;
  @override
  List<String> diagnostics;
  @override
  List<Map<String, dynamic>> get tools => [...businessTools, ...transportTools];
  @override
  String? get toolChoice => transportTools.isEmpty ? null : 'auto';
  QuickJsPresetRuntime._(
    this._session,
    this._network,
    this.businessTools,
    this.transportTools,
    this.diagnostics,
    this._atePrefix,
    this._transportName,
    this._toolsAllowed,
    this._isWave,
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
                  'Promise.resolve(__spreset.init(${snapshot.json})).then(v=>JSON.stringify(v))',
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
        await rootBundle.loadString('assets/preset_runtime/wave_context.js'),
      );
      await session.evaluate(
        await rootBundle.loadString('assets/preset_runtime/transport.js'),
      );
      final input = jsonDecode(snapshot.json) as Map;
      final config = input['transport'];
      final isAte = config is Map && config['protocol'] == 'ate_buffer_v1';
      final isWave = config is Map && config['protocol'] == 'wave_context_v1';
      final isCustom =
          config is Map && config['protocol'] == 'custom_script_v1';
      final prefix = isAte
          ? config['prefix'] as String? ?? 'view_file_stream_'
          : 'emit_complete_response_';
      final name = isWave ? 'wave_context_reference' : _randomName(prefix);
      final transportInput = {
        'config': config,
        'storage': Map<String, String>.of(_persistentStorage),
        if (isAte ||
            isCustom ||
            (config is Map &&
                config['scripts'] is List &&
                (config['scripts'] as List).isNotEmpty))
          'random': _randomBytes(),
        'presetName': input['presetName'] ?? '',
        'macros': input['macros'] ?? <String, String>{},
        'prompts': input['prompts'] ?? [],
        'extensions': input['extensions'] ?? {},
        'name': name,
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
        isAte ? prefix : null,
        name,
        snapshot.toolsAllowed,
        isWave,
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

  static String _randomName(String prefix) {
    final random = Random.secure();
    final suffix = List.generate(
      12,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    return '$prefix$suffix';
  }

  void _ensureOpen() {
    if (_closed) throw StateError('预设脚本运行环境已关闭，请重新打开。');
  }

  Future<void> _checkTimerTimeout() async {
    final state = jsonDecode(
      await _session.evaluate('JSON.stringify(__transport.state())'),
    ) as Map;
    diagnostics = List.unmodifiable((state['diagnostics'] as List).cast<String>());
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
  ) => prepareWithTools(messages, tools: businessTools);

  @override
  Future<List<Map<String, dynamic>>> prepareWithTools(
    List<Map<String, dynamic>> messages, {
    required List<Map<String, dynamic>> tools,
  }) async {
    _ensureOpen();
    if (_atePrefix != null) {
      final names = {
        for (final schema in [...businessTools, ...tools])
          if (schema['function'] is Map) (schema['function'] as Map)['name'],
      };
      // Every prepared round owns a fresh identity, including recovery attempts.
      // Newly activated ordinary tools and earlier round names stay unavailable.
      do {
        _transportName = _randomName(_atePrefix);
      } while (names.contains(_transportName) ||
          _usedTransportNames.contains(_transportName));
      _usedTransportNames.add(_transportName);
    }
    final references = PresetImageReferences();
    final prepared = await _call('prepare', references.hide(messages));
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
                'Promise.resolve(__transport.prepare(${jsonEncode(prepared)}, ${jsonEncode(_transportName)}, ${jsonEncode([...tools, ...roundTools])})).then(v=>JSON.stringify(v))',
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
    _waveActionEnabled = _isWave && state['actionTool'] == true;
    businessTools = List.unmodifiable([
      ...roundTools,
      ...scriptBusinessTools,
      if (_waveActionEnabled) ...stateTools,
    ]);
    if (_waveActionEnabled) {
      transportTools = const [];
    } else {
      transportTools = List.unmodifiable(stateTools);
    }
    diagnostics = List.unmodifiable(
      (state['diagnostics'] as List).cast<String>(),
    );
    return (references.restore(result) as List)
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
      final result = jsonDecode(
        await _session.evaluate(
          'Promise.resolve(__transport.action(${jsonEncode({'name': name, 'args': arguments})})).then(v=>JSON.stringify(v))',
        ),
      ) as String;
      await _checkTimerTimeout();
      return result;
    }
    if (_waveActionEnabled && name == 'wave_context_reference') {
      return '资料已经完整放在 wave_context_reference 的说明中，无需再调用。请按 messages 中本轮交付约定回复。';
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
    await _call('reset', streaming);
  }

  @override
  Future<String> update(
    String cumulativeText, {
    List<Map<String, dynamic>> calls = const [],
  }) async {
    _ensureOpen();
    if (transportTools.isNotEmpty) {
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
