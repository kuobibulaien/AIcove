library;

import '../../../core/sync/cloud_local_write.dart';

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/app_logger.dart';

typedef PresetVariablesDocumentsDirectoryResolver =
    Future<Directory> Function();

class SillyTavernVariableSnapshot {
  final Map<String, String> values;
  final List<String> warnings;

  const SillyTavernVariableSnapshot({
    required this.values,
    this.warnings = const <String>[],
  });
}

/// Persists SillyTavern local variables per conversation and preset.
///
/// Chat text is never written here. The conversation id is hashed before it is
/// used as a file name so file-system state does not expose user-facing ids.
class SillyTavernVariableStore {
  static const String _logTag = 'SillyTavernVariableStore';
  static const String _directoryName = 'aicove/sillytavern_preset_variables';
  static const int _maxVariableCount = 1000;
  static const int _maxValueCharacters = 128 * 1024;

  SillyTavernVariableStore({
    PresetVariablesDocumentsDirectoryResolver? documentsDirectoryResolver,
  }) : _documentsDirectoryResolver =
           documentsDirectoryResolver ?? getApplicationDocumentsDirectory;

  final PresetVariablesDocumentsDirectoryResolver _documentsDirectoryResolver;

  Future<SillyTavernVariableSnapshot> load({
    required String presetId,
    required String conversationId,
  }) async {
    final file = await _fileFor(
      presetId: presetId,
      conversationId: conversationId,
      ensureDirectory: false,
    );
    if (!await file.exists()) {
      return const SillyTavernVariableSnapshot(values: <String, String>{});
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map || decoded['values'] is! Map) {
        throw const FormatException('Invalid variable snapshot');
      }
      final values = <String, String>{};
      final rawValues = Map<dynamic, dynamic>.from(decoded['values'] as Map);
      for (final entry in rawValues.entries.take(_maxVariableCount)) {
        final key = entry.key.toString().trim();
        if (key.isEmpty) continue;
        final value = entry.value?.toString() ?? '';
        values[key] = value.length <= _maxValueCharacters
            ? value
            : value.substring(0, _maxValueCharacters);
      }
      return SillyTavernVariableSnapshot(values: Map.unmodifiable(values));
    } catch (error) {
      AppLogger.warning(
        _logTag,
        '读取酒馆预设变量失败，已按空变量继续',
        metadata: <String, dynamic>{
          'presetId': presetId,
          'errorType': error.runtimeType.toString(),
        },
      );
      return const SillyTavernVariableSnapshot(
        values: <String, String>{},
        warnings: <String>['会话变量文件损坏或不可读，本轮已按空变量继续'],
      );
    }
  }

  Future<bool> saveIfChanged({
    required String presetId,
    required String conversationId,
    required Map<String, String> previousValues,
    required Map<String, String> values,
  }) async {
    if (_mapsEqual(previousValues, values)) return false;
    final safeValues = <String, String>{};
    for (final entry in values.entries.take(_maxVariableCount)) {
      final key = entry.key.trim();
      if (key.isEmpty) continue;
      safeValues[key] = entry.value.length <= _maxValueCharacters
          ? entry.value
          : entry.value.substring(0, _maxValueCharacters);
    }
    final file = await _fileFor(
      presetId: presetId,
      conversationId: conversationId,
      ensureDirectory: true,
    );
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(
      jsonEncode(<String, dynamic>{'schemaVersion': 1, 'values': safeValues}),
      flush: true,
    );
    await cloudLocalWrite(() => temp.rename(file.path));
    return true;
  }

  Future<File> _fileFor({
    required String presetId,
    required String conversationId,
    required bool ensureDirectory,
  }) async {
    final normalizedPresetId = presetId.trim();
    if (!RegExp(r'^st_preset_[a-f0-9]{24}$').hasMatch(normalizedPresetId)) {
      throw const FormatException('Invalid preset id');
    }
    final root = await _documentsDirectoryResolver();
    final directory = Directory(
      '${root.path}/$_directoryName/$normalizedPresetId',
    );
    if (ensureDirectory && !await directory.exists()) {
      await directory.create(recursive: true);
    }
    final conversationHash = sha256
        .convert(utf8.encode(conversationId.trim()))
        .toString()
        .substring(0, 32);
    return File('${directory.path}/$conversationHash.json');
  }

  bool _mapsEqual(Map<String, String> left, Map<String, String> right) {
    if (left.length != right.length) return false;
    for (final entry in left.entries) {
      if (right[entry.key] != entry.value) return false;
    }
    return true;
  }
}
