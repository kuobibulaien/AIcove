import 'dart:convert';
import 'kemini_transport_config.dart';
import 'silly_tavern_preset.dart';

/// JSON snapshot: no open runtime or callbacks survive a generation.
class PresetScriptSnapshot {
  final String json;
  final bool toolsAllowed;
  final bool modelSupportsTools;
  const PresetScriptSnapshot(
    this.json, {
    this.toolsAllowed = true,
    this.modelSupportsTools = true,
  });

  /// Request-local display policy; never changes the user's chunking setting.
  bool get hasContentTransport {
    if (!modelSupportsTools) return false;
    try {
      final snapshot = jsonDecode(json);
      final transport = snapshot is Map ? snapshot['transport'] : null;
      return transport is Map &&
          transport['protocol'] == 'content_tool_v1' &&
          transport['enabled'] == true;
    } catch (_) {
      return false;
    }
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
    final transport = KeminiTransportConfig.read(
      extensions is Map ? extensions : const {},
    );
    return PresetScriptSnapshot(
      jsonEncode({
        'config': config is Map ? config : <String, dynamic>{},
        'transport': transport,
        'macros': macros,
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
