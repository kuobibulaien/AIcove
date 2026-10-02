import 'dart:convert';
import 'dart:io';

import 'package:aicove_flutter/src/features/agent_context/domain/preset_tag_mapping.dart';
import 'package:aicove_flutter/src/features/agent_context/domain/silly_tavern_preset_parser.dart';
import 'package:flutter_test/flutter_test.dart';

/// 本机真实预设回归（第三方资料只在本地，不入库）；目录不存在时跳过。
const _localRoot = '../../opusdocs/预设与正则';

void main() {
  final root = Directory(_localRoot);
  final files = root.existsSync()
      ? (root
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.json'))
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path)))
      : <File>[];

  test('local real presets', () {
    for (final file in files) {
      final Map<String, dynamic> json;
      try {
        json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }
      final dynamic preset;
      try {
        preset = const SillyTavernPresetParser()
            .parseMap(json, sourceFileName: file.uri.pathSegments.last);
      } catch (_) {
        continue;
      }
      final mapping = inferPresetTagMapping(preset);
      // ignore: avoid_print
      print('${file.uri.pathSegments.last}\n  '
          '${mapping.rules.map((r) => '${r.name}=${r.display.name}「${r.title}」(${r.source.name})').join(', ')}'
          '${mapping.candidates.isEmpty ? '' : '\n  待确认: ${mapping.candidates.join(', ')}'}');
    }
  }, skip: files.isEmpty ? '本机没有真实预设资料' : null);
}
