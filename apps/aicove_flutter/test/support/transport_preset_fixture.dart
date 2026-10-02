import 'dart:convert';
import 'dart:io';

import 'package:aicove_flutter/src/features/agent_context/domain/silly_tavern_preset.dart';
import 'package:aicove_flutter/src/features/agent_context/domain/silly_tavern_preset_parser.dart';

/// The default fixture is synthetic and contains no third-party preset text.
/// Set AICOVE_KEMINI_FIXTURE to an absolute original-export path for a private
/// compatibility run. An explicitly requested missing fixture is an error.
Map<String, dynamic> keminiSource() {
  final original = Platform.environment['AICOVE_KEMINI_FIXTURE'];
  if (original != null) {
    final file = File(original);
    if (!file.isAbsolute || !file.existsSync()) {
      throw StateError(
        'AICOVE_KEMINI_FIXTURE must point to an existing absolute JSON path',
      );
    }
    return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  }
  // JSON decoding also gives mutable, dynamically typed nested containers,
  // just like a real imported file (the tests intentionally mutate metadata).
  return jsonDecode(
        jsonEncode({
          'name': 'Synthetic content transport',
          'function_calling': false,
          'prompt_order': [
            {
              'character_id': 100001,
              'order': [
                {'identifier': 'synthetic.system', 'enabled': true},
              ],
            },
          ],
          'prompts': [
            {
              'identifier': 'synthetic.system',
              'name': 'Synthetic system',
              'role': 'system',
              'content': '<format>Respond with text.</format>',
            },
          ],
          'extensions': {
            'tavern_helper': {
              'scripts': [
                {
                  'id': 'synthetic.transport',
                  'enabled': true,
                  'content':
                      'keminiCompanion; const transportControlAnchor = "<format>";',
                },
              ],
            },
          },
        }),
      )
      as Map<String, dynamic>;
}

SillyTavernPreset keminiPreset([Map<String, dynamic>? source]) =>
    const SillyTavernPresetParser().parseMap(
      source ?? keminiSource(),
      sourceFileName: 'transport-fixture.json',
    );
