import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/features/agent_context/domain/preset_script_runtime.dart';
import 'package:aicove_flutter/src/features/agent_context/domain/silly_tavern_preset_assembler.dart';
import 'package:aicove_flutter/src/features/agent_context/infrastructure/quickjs_preset_runtime.dart';

import '../../../support/transport_preset_fixture.dart';

List<Map<String, dynamic>> _messages() => [
  {'role': 'system', 'content': '<format>Reply in full.</format>'},
  {'role': 'user', 'content': '去花园'},
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<QuickJsPresetRuntime> open({
    Map<String, dynamic>? source,
    bool capable = true,
    bool toolsAllowed = false,
  }) async {
    final runtime = await QuickJsPresetRuntime.open(
      PresetScriptSnapshot.fromPreset(
        keminiPreset(source),
        macros: {},
        toolsAllowed: toolsAllowed,
        modelSupportsTools: capable,
      )!,
    );
    addTearDown(runtime.close);
    return runtime;
  }

  test(
    'executes the enabled original fetch wrapper, not script-name detection',
    () async {
      final source = keminiSource();
      final script = source['extensions']['tavern_helper']['scripts'][0];
      script['id'] = 'unrecognized-id';
      script['name'] = 'Arbitrary script name';
      final runtime = await open(source: source);
      final input = _messages(), saved = jsonEncode(input);
      final prepared = await runtime.prepare(input);
      expect(runtime.businessTools, isEmpty);
      expect(
        runtime.transportTools.single['function']['name'],
        'emit_complete_response_fixture',
      );
      expect(
        prepared.last['content'],
        contains('emit_complete_response_fixture'),
      );
      expect(jsonEncode(input), saved);
      expect(runtime.toolChoice, 'auto');
    },
  );

  test('unsupported model does not receive a wrapper-added tool', () async {
    final runtime = await open(capable: false);
    expect(await runtime.prepare(_messages()), _messages());
    expect(runtime.tools, isEmpty);
    expect((await runtime.response('花开了。', [])).text, '花开了。');
  });

  test('disabled script does not register or inject anything', () async {
    final source = keminiSource();
    source['extensions']['tavern_helper']['scripts'][0]['enabled'] = false;
    final runtime = await open(source: source);
    expect(await runtime.prepare(_messages()), _messages());
    expect(runtime.tools, isEmpty);
    expect((await runtime.response('plain', [])).text, 'plain');
  });

  for (final streaming in [false, true]) {
    test(
      'fetch unwrap stream=$streaming consumes only its precise tool identity',
      () async {
        final runtime = await open();
        await runtime.prepare(_messages());
        await runtime.reset(streaming);
        const calls = <Map<String, dynamic>>[
          {
            'id': 'delivery',
            'name': 'emit_complete_response_fixture',
            'arguments': {'content': '花开了。'},
          },
          {
            'id': 'business',
            'name': 'weather',
            'arguments': {'city': '杭州'},
          },
          {
            'id': 'foreign',
            'name': 'emit_complete_response_other',
            'arguments': {'content': '别吞掉'},
          },
        ];
        if (streaming) {
          expect(await runtime.update('', calls: calls), '花开了。');
        }
        final result = await runtime.response('', calls);
        expect(result.text, '花开了。');
        expect(result.consumedIds, {'delivery'});
        expect(result.consumedIndexes, {0});
      },
    );
  }

  test(
    'structured argument snapshots hold trailing fields until final delivery',
    () async {
      final runtime = await open();
      await runtime.prepare(_messages());
      await runtime.reset(true);
      final name = runtime.transportTools.single['function']['name'];
      expect(
        await runtime.update(
          '',
          calls: [
            {
              'id': 'out',
              'name': name,
              'arguments': {'content': 'a', 'done': false},
            },
          ],
        ),
        'a',
      );
      final calls = <Map<String, dynamic>>[
        {
          'id': 'out',
          'name': name,
          'arguments': {'content': 'ab', 'done': false},
        },
      ];
      expect(await runtime.update('', calls: calls), 'ab');
      final result = await runtime.response('', calls);
      expect(result.text, 'ab');
      expect(result.consumedIds, {'out'});
      expect(result.consumedIndexes, {0});
    },
  );

  test(
    'growing leading metadata keeps the final argument object valid',
    () async {
      final runtime = await open();
      await runtime.prepare(_messages());
      await runtime.reset(true);
      final name = runtime.transportTools.single['function']['name'];
      await runtime.update(
        '',
        calls: [
          {
            'id': 'out',
            'name': name,
            'arguments': {'count': 1, 'content': 'a'},
          },
        ],
      );
      final calls = <Map<String, dynamic>>[
        {
          'id': 'out',
          'name': name,
          'arguments': {'count': 12, 'content': 'ab'},
        },
      ];
      await runtime.update('', calls: calls);
      final result = await runtime.response('', calls);
      expect(result.text, 'ab');
      expect(result.consumedIds, {'out'});
      expect(result.consumedIndexes, {0});
    },
  );

  for (final path in localTransportPresetPaths) {
    final file = localTransportPreset(path);
    test(
      'local original scripts: $path',
      () async {
        final source =
            jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        final preset = keminiPreset(source);
        final assembled = const SillyTavernPresetAssembler().assemble(
          preset: preset,
          historyMessages: [
            {'role': 'user', 'content': '去花园'},
            {'role': 'assistant', 'content': '旧故事'},
            {'role': 'user', 'content': '继续'},
          ],
          context: const SillyTavernAssemblyContext(
            characterName: '角色',
            userName: '用户',
            characterDescription: '设定',
            scenario: '花园',
          ),
          maxContextTokens: 2000000,
          reserveTokens: 2048,
          randomIndexPicker: (_) => 0,
        );
        for (final capable in [true, false]) {
          final runtime = await open(source: source, capable: capable);
          final prepared = await runtime.prepare(assembled.scriptMessages);
          expect(prepared, isNotEmpty);
          expect(
            runtime.diagnostics.where(
              (d) => d.startsWith('custom_script_failed:'),
            ),
            isEmpty,
            reason: '$path modelSupportsTools=$capable',
          );
          final fetchTransport = [
            'Kemini_Dramatron_v3.1.json',
            'kunlun_linux_1.6.json',
          ].any(path.endsWith);
          if (!capable ||
              (!fetchTransport && preset.functionCalling == false)) {
            expect(runtime.tools, isEmpty);
          }
          if (capable && fetchTransport) {
            expect(preset.functionCalling, isFalse);
            expect(runtime.transportTools, isNotEmpty, reason: path);
            expect(
              runtime.diagnostics,
              isNot(contains('transport_skipped_model_without_tools')),
            );
            final definition = runtime.transportTools.first['function'] as Map;
            final properties = definition['parameters']['properties'] as Map;
            final key = [
              'content',
              'buffer_content',
              'manuscript',
              'display_stream',
            ].firstWhere((key) => properties[key]?['type'] == 'string');
            final result = await runtime.response('', [
              {
                'id': 'original-delivery',
                'name': definition['name'],
                'arguments': {key: '本轮正文'},
              },
            ]);
            expect(result.text, contains('本轮正文'), reason: path);
            expect(result.consumedIds, {'original-delivery'});
            expect(result.consumedIndexes, {0});
          } else {
            final result = await runtime.response('本轮正文', []);
            expect(result.text, contains('本轮正文'));
          }
          await runtime.close();
        }
        // Tavern-managed channels need the business toggle for this separate
        // enabled-channel test. Fetch channels retain the export's saved toggle.
        final activeSource =
            jsonDecode(jsonEncode(source)) as Map<String, dynamic>;
        if (path.contains('我即浪潮') || path.contains('TRANS-AM')) {
          activeSource['function_calling'] = true;
        }
        // This private manga export saves its independent transport switch off.
        // Activate only that script setting for the enabled-channel regression.
        if (path.endsWith('漫画v1.3.1.json')) {
          final scripts =
              activeSource['extensions']['tavern_helper']['scripts'] as List;
          final transport = scripts.firstWhere(
            (script) => script['name'] == '照本宣科',
          );
          expect(transport['data']['universalAntiTruncation'], isFalse);
          transport['data']['universalAntiTruncation'] = true;
        }
        for (final streaming in [false, true]) {
          final runtime = await open(source: activeSource, toolsAllowed: true);
          await runtime.prepareWithTools(
            assembled.scriptMessages,
            tools: [
              {
                'type': 'function',
                'function': {
                  'name': 'weather',
                  'parameters': {'type': 'object', 'properties': {}},
                },
              },
            ],
          );
          expect(
            runtime.diagnostics.where(
              (d) => d.startsWith('custom_script_failed:'),
            ),
            isEmpty,
            reason: '$path native stream=$streaming',
          );
          final deliveries = runtime.transportTools.where((schema) {
            final properties =
                schema['function']['parameters']['properties'] as Map? ?? {};
            return [
              'content',
              'buffer_content',
              'manuscript',
              'display_stream',
            ].any((key) => properties[key]?['type'] == 'string');
          }).toList();
          if (path.endsWith('漫画v1.3.1.json')) {
            expect(deliveries, isNotEmpty);
          }
          await runtime.reset(streaming);
          if (deliveries.isEmpty) {
            expect((await runtime.response('本轮正文', [])).text, contains('本轮正文'));
          } else {
            final definition = deliveries.first['function'] as Map;
            final properties = definition['parameters']['properties'] as Map;
            final key = [
              'content',
              'buffer_content',
              'manuscript',
              'display_stream',
            ].firstWhere((key) => properties[key]?['type'] == 'string');
            final calls = <Map<String, dynamic>>[
              {
                'id': 'local-delivery',
                'name': definition['name'],
                'arguments': {key: '本轮正文'},
              },
              {'id': 'ordinary', 'name': 'weather', 'arguments': {}},
            ];
            if (streaming) await runtime.update('', calls: calls);
            final result = await runtime.response('', calls);
            expect(
              result.text,
              contains('本轮正文'),
              reason: '$path stream=$streaming',
            );
            expect(result.consumedIds, {'local-delivery'});
            expect(result.consumedIndexes, {0});
          }
          await runtime.close();
        }
      },
      skip: file.existsSync() ? null : 'Private fixture unavailable',
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }

  final transam = localTransportPreset('预设与正则/TRANS-AM-4A版-v1.0.4.8.json');
  test(
    'real TRANS-AM separates business decision from stealth content delivery',
    () async {
      final source =
          jsonDecode(transam.readAsStringSync()) as Map<String, dynamic>;
      for (final order in source['prompt_order'] as List) {
        for (final entry in order['order'] as List) {
          if ([
            'ta-decision-tool',
            'ta-random-reaction',
            'ta-transport-tool',
          ].contains(entry['identifier']))
            entry['enabled'] = true;
          if ([
            'ta-ooc-review',
            'ta-kunlun-transport',
            'ta-transport-unicode',
          ].contains(entry['identifier']))
            entry['enabled'] = false;
        }
      }
      final runtime = await QuickJsPresetRuntime.open(
        PresetScriptSnapshot.fromPreset(
          keminiPreset(source),
          macros: {},
          toolsAllowed: true,
        )!,
      );
      addTearDown(runtime.close);
      await runtime.prepare(_messages());
      expect(
        runtime.businessTools.map((t) => t['function']['name']),
        contains('transam_decide'),
      );
      expect(
        runtime.transportTools.map((t) => t['function']['name']),
        contains('transam_content'),
      );
      final decision =
          jsonDecode(
                await runtime.action('transam_decide', {
                  'npc': '角色',
                  'focus': '是否进入花园',
                  'options': [
                    {
                      'id': 'enter',
                      'action': '进入',
                      'support': '门已打开',
                      'weight': 1,
                    },
                  ],
                }),
              )
              as Map;
      expect(decision['ok'], isTrue);
      expect(decision['selected'], 'enter');
      final result = await runtime.response('', [
        {'id': 'decision', 'name': 'transam_decide', 'arguments': {}},
        {
          'id': 'delivery',
          'name': 'transam_content',
          'arguments': {'content': '本轮正文'},
        },
      ]);
      expect(result.text, '本轮正文');
      expect(result.consumedIds, {'delivery'});
      expect(result.consumedIndexes, {1});
    },
    skip: transam.existsSync() ? null : 'Private fixture unavailable',
  );
}
