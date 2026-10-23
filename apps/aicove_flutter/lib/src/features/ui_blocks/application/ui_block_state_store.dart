import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/ui_block.dart';
import '../domain/ui_state_context.dart';

/// What the user changed in the interactive blocks of one conversation
/// (ADR0073 交互组件), keyed by [uiSavedBlockKey]. Local to this device: not
/// synced and not part of any message; raw messages never change.
///
/// Loaded on first use; reads before the load finishes see nothing, and
/// writes made meanwhile are kept.
class UiBlockStateNotifier
    extends FamilyNotifier<Map<String, UiSavedBlock>, String> {
  static const prefsPrefix = 'aicove_ui_state_v1:';

  /// Blocks kept per conversation; the least recently changed go first.
  static const maxBlocks = 64;
  static const _saveDelay = Duration(milliseconds: 600);

  Timer? _saveTimer;
  bool _loaded = false;

  /// Whether stored values have been read.
  bool get loaded => _loaded;

  /// Keys written or cleared before the load finished; they win over what
  /// was stored, clears included.
  final Set<String> _touchedBeforeLoad = {};

  @override
  Map<String, UiSavedBlock> build(String conversationId) {
    ref.onDispose(() => _saveTimer?.cancel());
    unawaited(_load());
    return const {};
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$prefsPrefix$arg');
    final loaded = <String, UiSavedBlock>{};
    if (raw != null) {
      try {
        final json = jsonDecode(raw);
        if (json is Map) {
          for (final entry in json.entries) {
            final block = UiSavedBlock.fromJson(entry.value);
            if (block != null) loaded['${entry.key}'] = block;
          }
        }
      } on FormatException {
        // A corrupt entry only loses saved positions; start empty.
      }
    }
    _loaded = true;
    // Writes made before the load win over what was stored.
    loaded.removeWhere((key, _) => _touchedBeforeLoad.contains(key));
    _touchedBeforeLoad.clear();
    state = _trim(LinkedHashMap.of({...loaded, ...state}));
  }

  /// [changes] empty clears the block (the user is back at the defaults).
  void write(String key, Map<String, Object?> changes, {String title = ''}) {
    if (!_loaded) _touchedBeforeLoad.add(key);
    final next = LinkedHashMap.of(state)..remove(key);
    if (changes.isNotEmpty) {
      next[key] = UiSavedBlock(state: uiJsonSafe(changes)! as Map<String, Object?>, title: title);
    }
    state = _trim(next);
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDelay, () => unawaited(_save()));
  }

  Map<String, UiSavedBlock> _trim(LinkedHashMap<String, UiSavedBlock> map) {
    while (map.length > maxBlocks) {
      map.remove(map.keys.first);
    }
    return map;
  }

  Future<void> _save() async {
    if (!_loaded) {
      _saveTimer = Timer(_saveDelay, () => unawaited(_save()));
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final key = '$prefsPrefix$arg';
    if (state.isEmpty) {
      await prefs.remove(key);
      return;
    }
    await prefs.setString(
      key,
      jsonEncode({
        for (final entry in state.entries) entry.key: entry.value.toJson(),
      }),
    );
  }
}

final uiBlockStateProvider = NotifierProvider.family<UiBlockStateNotifier,
    Map<String, UiSavedBlock>, String>(UiBlockStateNotifier.new);
