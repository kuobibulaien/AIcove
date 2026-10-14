import 'package:aicove_agent_kernel/aicove_agent_kernel.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'file_change_journal.dart';

/// Reversible changes to one local setting stored in [SharedPreferences].
/// State is `{key, value}`; a null value means the setting is absent.
class PreferenceChangeApplier implements ChangeApplier {
  const PreferenceChangeApplier(this._prefs);

  static const kind = 'preference';

  final SharedPreferences _prefs;

  /// Snapshots the current value of [key] as `before`.
  ReversibleChange changeOf(
    String key,
    Object? value, {
    required String description,
  }) =>
      ReversibleChange(
        kind: kind,
        description: description,
        before: {'key': key, 'value': _prefs.get(key)},
        after: {'key': key, 'value': value},
      );

  @override
  Future<void> apply(Map<String, Object?> state) async {
    final key = state['key']! as String;
    final value = state['value'];
    final ok = switch (value) {
      null => await _prefs.remove(key),
      String() => await _prefs.setString(key, value),
      bool() => await _prefs.setBool(key, value),
      int() => await _prefs.setInt(key, value),
      double() => await _prefs.setDouble(key, value),
      List() => await _prefs.setStringList(key, value.cast<String>()),
      _ => throw ArgumentError('不支持的设置值类型：${value.runtimeType}'),
    };
    if (!ok) throw StateError('设置写入失败：$key');
  }
}
