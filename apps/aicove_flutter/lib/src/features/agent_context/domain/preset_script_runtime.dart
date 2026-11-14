import 'dart:convert';
import 'silly_tavern_preset.dart';

/// JSON snapshot: no open runtime or callbacks survive a generation.
class PresetScriptSnapshot {
  final String json;
  final bool toolsAllowed;
  final bool modelSupportsTools;
  final String? callerToolChoice;
  const PresetScriptSnapshot(
    this.json, {
    this.toolsAllowed = true,
    this.modelSupportsTools = true,
    this.callerToolChoice,
  });

  /// Normalized input for both imported presets and historical JSON callers.
  Map<String, dynamic> get rawJson {
    final input = Map<String, dynamic>.from(jsonDecode(json) as Map);
    if (!input.containsKey('scripts')) {
      input['scripts'] = _enabledScripts(input['extensions']);
    }
    final preset = Map<String, dynamic>.from(
      input['preset'] as Map? ?? const {},
    );
    final functionCalling =
        input['functionCalling'] ?? preset['function_calling'] ?? true;
    input['functionCalling'] = functionCalling;
    input['preset'] = {...preset, 'function_calling': functionCalling};
    return input;
  }

  /// Conservative initial display policy, refined by the prepared runtime.
  bool get hasContentTransport {
    if (!modelSupportsTools) return false;
    try {
      final scripts = rawJson['scripts'];
      return scripts is List && scripts.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  static List<Map<String, dynamic>> _enabledScripts(dynamic extensions) {
    final rawHelper = extensions is Map ? extensions['tavern_helper'] : null;
    final helper = rawHelper is List
        ? Map.fromEntries(
            rawHelper
                .whereType<List>()
                .where((pair) => pair.length == 2)
                .map((pair) => MapEntry(pair[0], pair[1])),
          )
        : rawHelper;
    final scripts = helper is Map ? helper['scripts'] : null;
    if (scripts is! List) return [];
    return [
      for (final script in scripts.whereType<Map>())
        if (script['enabled'] != false &&
            script['id'] != 'f0801c1a-3b0f-4e1c-82b6-f0f8990fbde6' &&
            script['content'] is String &&
            !(script['content'] as String).contains('regex_bind/inject.js') &&
            (script['content'] as String).trim().isNotEmpty)
          Map<String, dynamic>.from(script),
    ];
  }

  static PresetScriptSnapshot? fromPreset(
    SillyTavernPreset? preset, {
    required Map<String, String> macros,
    required bool toolsAllowed,
    bool modelSupportsTools = true,
  }) {
    if (preset == null) return null;
    final root = preset.rawPreset;
    final body = root['data'] is Map ? root['data'] as Map : root;
    final extensions = body['extensions'] ?? root['extensions'];
    final config = extensions is Map ? extensions['SPreset'] : null;
    final extensionMap = extensions is Map ? extensions : const {};
    return PresetScriptSnapshot(
      jsonEncode({
        'config': config is Map ? config : <String, dynamic>{},
        'scripts': _enabledScripts(extensionMap),
        'functionCalling': preset.functionCalling ?? true,
        'preset': {
          'function_calling': preset.functionCalling ?? true,
          'squash_system_messages': preset.squashSystemMessages,
          'custom_prompt_post_processing':
              (body['custom_prompt_post_processing'] ?? '').toString(),
        },
        'macros': macros,
        'extensions': extensionMap,
        'presetName': preset.name,
        'prompts': preset.prompts
            .map(
              (p) => {
                'id': p.identifier,
                'identifier': p.identifier,
                'name': p.name,
                'role': p.role,
                'content': p.content,
                'enabled': preset.enabledPrompts.any(
                  (e) => e.identifier == p.identifier,
                ),
                'system_prompt': p.systemPrompt,
                'marker': p.marker,
                'injection_position': p.injectionPosition,
                'injection_depth': p.injectionDepth,
                'injection_order': p.injectionOrder,
                'injection_trigger': p.injectionTriggers,
                'position': {
                  'type': p.injectionPosition == 1 ? 'in_chat' : 'relative',
                  'depth': p.injectionDepth,
                  'order': p.injectionOrder,
                },
              },
            )
            .toList(),
        'activeIds': preset.enabledPrompts
            .where(
              (p) =>
                  p.injectionTriggers.isEmpty ||
                  p.injectionTriggers.any(
                    (trigger) => trigger.toLowerCase() == 'normal',
                  ),
            )
            .map((p) => p.identifier)
            .toList(),
      }),
      toolsAllowed: toolsAllowed,
      modelSupportsTools: modelSupportsTools,
    );
  }
}

/// Opens a preset runtime for one request; the tavern compatibility plugin
/// provides it as a service.
typedef PresetRuntimeOpener =
    Future<PresetScriptRuntime> Function(PresetScriptSnapshot snapshot);

abstract interface class PresetScriptRuntime {
  /// Only business tools may enter the ordinary tool execution loop.
  List<Map<String, dynamic>> get businessTools;
  List<Map<String, dynamic>> get transportTools;
  List<Map<String, dynamic>> get tools;
  String? get toolChoice;
  List<String> get diagnostics;
  Future<List<Map<String, dynamic>>> prepare(
    List<Map<String, dynamic>> messages,
  );
  Future<String> action(String name, Map<String, dynamic> arguments);
  Future<void> reset(bool streaming);
  Future<String> update(
    String cumulativeText, {
    List<Map<String, dynamic>> calls = const [],
  });
  Future<({String text, Set<String> consumedIds, Set<int> consumedIndexes})>
  response(String text, List<Map<String, dynamic>> calls);
  Future<void> close();
}

/// Optional request preparation for runtimes whose generated tools must avoid
/// the current round's ordinary tool names. Existing runtimes keep their original preparation entry point.
abstract interface class PresetToolAwareRuntime {
  Future<List<Map<String, dynamic>>> prepareWithTools(
    List<Map<String, dynamic>> messages, {
    required List<Map<String, dynamic>> tools,
  });
}
