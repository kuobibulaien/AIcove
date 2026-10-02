import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/features/agent_context/domain/preset_script_runtime.dart';
import 'package:aicove_flutter/src/features/agent_context/infrastructure/quickjs_preset_runtime.dart';

import '../../../support/transport_preset_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('content transport registers despite function_calling=false', () async {
      final preset = keminiPreset();
      expect(preset.functionCalling, false);
      final runtime = await QuickJsPresetRuntime.open(
        PresetScriptSnapshot.fromPreset(
          preset,
          macros: {},
          toolsAllowed: false,
        )!,
      );
      addTearDown(runtime.close);
      expect(runtime.tools, hasLength(1));
      expect(
        runtime.tools.single['function']['name'],
        startsWith('emit_complete_response_'),
      );
      expect(runtime.businessTools, isEmpty);
      expect(runtime.transportTools, hasLength(1));
      expect(runtime.toolChoice, 'auto');
    },
  );

  Future<QuickJsPresetRuntime> open({bool capable = true}) async {
    final runtime = await QuickJsPresetRuntime.open(
      PresetScriptSnapshot.fromPreset(
        keminiPreset(),
        macros: {},
        toolsAllowed: false,
        modelSupportsTools: capable,
      )!,
    );
    addTearDown(runtime.close);
    return runtime;
  }

  test(
    'unsupported model has explicit diagnostic and unchanged request',
    () async {
      final runtime = await open(capable: false);
      expect(runtime.tools, isEmpty);
      expect(runtime.toolChoice, isNull);
      expect(
        runtime.diagnostics,
        contains('transport_skipped_model_without_tools'),
      );
      final input = [
        {'role': 'user', 'content': '去花园'},
      ];
      expect(await runtime.prepare(input), input);
      await runtime.reset(false);
      expect((await runtime.response('花开了。', [])).text, '花开了。');
    },
  );

  Future<QuickJsPresetRuntime> openSource(Map<String, dynamic> source) async {
    final runtime = await QuickJsPresetRuntime.open(
      PresetScriptSnapshot.fromPreset(
        keminiPreset(source),
        macros: {},
        toolsAllowed: false,
      )!,
    );
    addTearDown(runtime.close);
    return runtime;
  }

  test('updated companion source still registers host transport', () async {
    final source = keminiSource();
    source['extensions']['tavern_helper']['scripts'][0]['content'] +=
        '\n// new version';
    expect((await openSource(source)).transportTools, hasLength(1));
  });

  test('missing anchor appends control and permits send', () async {
    final source = keminiSource();
    source['extensions']['tavern_helper']['scripts'][0]['content'] =
        'keminiCompanion';
    final runtime = await openSource(source);
    expect(runtime.diagnostics, contains('transport_anchor_missing'));
    final input = [
      {'role': 'user', 'content': '花园'},
    ];
    final prepared = await runtime.prepare(input);
    expect(prepared.first, input.first);
    expect(prepared.last['content'], contains('emit_complete_response_'));
    expect(runtime.transportTools, hasLength(1));
  });

  test(
    'unknown and malformed scripts degrade without a filename gate',
    () async {
      for (final scripts in [
        [],
        'invalid',
        [
          {
            'id': '2c7d747c-22d4-4e8b-95f8-5620b552fe6e',
            'enabled': true,
            'content': null,
          },
        ],
      ]) {
        final source = keminiSource();
        source['extensions']['tavern_helper']['scripts'] = scripts;
        final runtime = await openSource(source);
        expect(runtime.transportTools, isEmpty);
        expect(
          runtime.diagnostics,
          contains(
            anyOf('transport_unrecognized', 'transport_config_read_failed'),
          ),
        );
        expect(
          await runtime.prepare([
            {'role': 'user', 'content': '花园'},
          ]),
          [
            {'role': 'user', 'content': '花园'},
          ],
        );
      }
    },
  );

  test('multiple matches select first enabled script', () async {
    final source = keminiSource();
    final original = source['extensions']['tavern_helper']['scripts'][0] as Map;
    source['extensions']['tavern_helper']['scripts'] = [
      {...original, 'enabled': false},
      {...original, 'content': 'keminiCompanion'},
      original,
    ];
    final runtime = await openSource(source);
    expect(runtime.transportTools, hasLength(1));
    expect(runtime.diagnostics, contains('transport_anchor_missing'));
  });

  for (final scriptDisabled in [false, true]) {
    test(
      'explicit transport disable is respected (script=$scriptDisabled)',
      () async {
        final source = keminiSource();
        final script = source['extensions']['tavern_helper']['scripts'][0];
        if (scriptDisabled) {
          script['enabled'] = false;
        } else {
          script['data'] = {
            'keminiCompanion': {'antiTruncationEnabled': false},
          };
        }
        final runtime = await QuickJsPresetRuntime.open(
          PresetScriptSnapshot.fromPreset(
            keminiPreset(source),
            macros: {},
            toolsAllowed: false,
          )!,
        );
        addTearDown(runtime.close);
        expect(runtime.transportTools, isEmpty);
        expect(runtime.diagnostics, contains('transport_disabled'));
      },
    );
  }

  test(
    'control is anchored on a deep copy and never accumulates on retry',
    () async {
      final runtime = await open();
      final input = <Map<String, dynamic>>[
        {'role': 'system', 'content': '<format>正文</format>'},
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': '花园'},
          ],
        },
      ];
      final saved = jsonEncode(input);
      final first = await runtime.prepare(input);
      expect(first, hasLength(3));
      expect(first.first['content'], contains('emit_complete_response_'));
      expect(first[1]['content'], contains('<format>'));
      expect(await runtime.prepare(input), first);
      (first.last['content'] as List).first['text'] = 'changed';
      expect(jsonEncode(input), saved);
    },
  );

  test(
    'plain streaming, deduplication, empty IDs, and foreign tools stay separate',
    () async {
      final runtime = await open();
      final name = runtime.transportTools.single['function']['name'];
      await runtime.reset(true);
      expect(await runtime.update('花开了。'), '花开了。');
      final result = await runtime.response('花开了。', [
        {
          'id': '',
          'name': name,
          'arguments': {'content': '花开了。'},
        },
        {
          'id': '',
          'name': 'weather',
          'arguments': {'city': '杭州'},
        },
        {
          'id': 'foreign',
          'name': 'emit_complete_response_other',
          'arguments': {'content': '不要吞掉'},
        },
      ]);
      expect(result.text, '花开了。');
      expect(result.consumedIndexes, {0});
      await runtime.reset(true);
      expect(
        (await runtime.response('普通正文更完整', [
          {
            'id': 'next',
            'name': name,
            'arguments': {'content': '短正文'},
          },
        ])).text,
        '普通正文更完整',
      );
    },
  );

  test(
    'preview selects longest, prefers transport ties, and joins Unicode',
    () async {
      final runtime = await open();
      final name = runtime.transportTools.single['function']['name'];
      await runtime.reset(true);
      Future<String> preview(String plain, String body) => runtime.update(
        plain,
        calls: [
          {
            'id': '',
            'name': name,
            'arguments': {'content': body},
          },
          {
            'id': '',
            'name': 'weather',
            'arguments': {'content': 'never display business args'},
          },
        ],
      );
      expect(await preview('普通更长', '短'), '普通更长');
      expect(await preview('普通', '传输'), '传输');
      expect(await preview('', '花${String.fromCharCode(0xD83D)}'), '花');
      expect(
        await preview('', '花${String.fromCharCodes([0xD83D, 0xDE00])}'),
        '花😀',
      );
    },
  );

  for (final sample in <String, String>{
    '{"content":"花开了': '花开了',
    '{"content":"花\\n开\\u4e86\\': '花\n开了',
    '{"content":"花\\uD83D': '花',
    '{"content":"花\\uD83D\\uDE00': '花😀',
    '{"other":"不得误取': '',
    '{"meta":{"content":"不得误取"},"content":"花开了': '花开了',
    '{"meta":{"content":"不得误取': '',
  }.entries) {
    test(
      'truncated JSON recovers only arrived content: ${sample.key}',
      () async {
        final runtime = await open();
        await runtime.reset(false);
        final result = await runtime.response('', [
          {
            'id': 't',
            'name': runtime.transportTools.single['function']['name'],
            'arguments': {},
            'rawArguments': sample.key,
          },
        ]);
        expect(result.text, sample.value);
        expect(result.consumedIndexes, {0});
      },
    );
  }
}
