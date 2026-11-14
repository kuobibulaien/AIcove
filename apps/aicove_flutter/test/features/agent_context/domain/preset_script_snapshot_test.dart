import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/features/agent_context/domain/preset_script_runtime.dart';
import 'package:aicove_flutter/src/features/agent_context/domain/silly_tavern_preset_parser.dart';

void main() {
  Map<String, dynamic> script(
    String id,
    String content, {
    bool enabled = true,
  }) => {
    'id': id,
    'content': content,
    'enabled': enabled,
    'data': {'value': 7},
  };

  for (final tupleHelper in [false, true]) {
    test(
      'snapshot preserves enabled source and settings (tuple=$tupleHelper)',
      () {
        final scripts = [
          script('ordinary', 'synthetic'),
          script('another', 'Imported JavaScript must not execute'),
          {'id': 'default-enabled', 'content': 'defaultEnabled()'},
          script('disabled', 'disabled()', enabled: false),
          script('f0801c1a-3b0f-4e1c-82b6-f0f8990fbde6', 'excluded()'),
          script('regex', 'import "regex_bind/inject.js";'),
          script('empty', ' \n\t'),
        ];
        final extensions = {
          'SPreset': {'custom': 'unchanged'},
          'tavern_helper': tupleHelper
              ? [
                  ['scripts', scripts],
                ]
              : {'scripts': scripts},
        };
        final preset = const SillyTavernPresetParser().parseSource(
          jsonEncode({
            'name': 'Local preset',
            'function_calling': false,
            'squash_system_messages': true,
            'custom_prompt_post_processing': 'strict',
            'extensions': extensions,
            'prompts': [
              {'identifier': 'main', 'content': 'Hello'},
            ],
            'prompt_order': [
              {
                'order': [
                  {'identifier': 'main', 'enabled': true},
                ],
              },
            ],
          }),
          sourceFileName: 'snapshot.json',
        );
        final snapshot = PresetScriptSnapshot.fromPreset(
          preset,
          macros: {'user': 'Reader', 'char': 'Companion'},
          toolsAllowed: false,
        )!;
        final data = snapshot.rawJson;
        expect(data['config'], extensions['SPreset']);
        expect(data['scripts'], scripts.take(3).toList());
        expect(data['extensions'], extensions);
        expect(data['presetName'], 'Local preset');
        expect(data['macros'], {'user': 'Reader', 'char': 'Companion'});
        expect(data['activeIds'], ['main']);
        expect((data['prompts'] as List).single['content'], 'Hello');
        expect(data['functionCalling'], isFalse);
        expect(data['preset'], {
          'function_calling': false,
          'squash_system_messages': true,
          'custom_prompt_post_processing': 'strict',
        });
        expect(data.containsKey('transport'), isFalse);
        expect(snapshot.hasContentTransport, isTrue);
      },
    );
  }

  test(
    'legacy constructor falls back to helper scripts and defaults tools on',
    () {
      final snapshot = PresetScriptSnapshot(
        jsonEncode({
          'extensions': {
            'tavern_helper': {
              'scripts': [script('custom', 'run()')],
            },
          },
        }),
      );
      expect(snapshot.rawJson['functionCalling'], isTrue);
      expect(snapshot.rawJson['preset']['function_calling'], isTrue);
      expect((snapshot.rawJson['scripts'] as List).single['id'], 'custom');
      expect(snapshot.hasContentTransport, isTrue);
      expect(
        PresetScriptSnapshot(
          snapshot.json,
          modelSupportsTools: false,
        ).hasContentTransport,
        isFalse,
      );
      expect(
        const PresetScriptSnapshot('{"scripts":[]}').hasContentTransport,
        isFalse,
      );
      expect(
        const PresetScriptSnapshot('invalid').hasContentTransport,
        isFalse,
      );
    },
  );

  test('an explicit scripts list takes precedence over helper fallback', () {
    final snapshot = PresetScriptSnapshot(
      jsonEncode({
        'scripts': [],
        'extensions': {
          'tavern_helper': {
            'scripts': [script('custom', 'run()')],
          },
        },
      }),
    );
    expect(snapshot.rawJson['scripts'], isEmpty);
  });

  test('imported preset defaults function calling and post processing', () {
    final preset = const SillyTavernPresetParser().parseSource(
      jsonEncode({
        'prompts': [
          {'identifier': 'main', 'content': 'Hello'},
        ],
        'prompt_order': [
          {
            'order': [
              {'identifier': 'main', 'enabled': true},
            ],
          },
        ],
      }),
      sourceFileName: 'defaults.json',
    );
    final data = PresetScriptSnapshot.fromPreset(
      preset,
      macros: {},
      toolsAllowed: true,
    )!.rawJson;
    expect(data['functionCalling'], isTrue);
    expect(data['preset'], {
      'function_calling': true,
      'squash_system_messages': false,
      'custom_prompt_post_processing': '',
    });
  });
}
