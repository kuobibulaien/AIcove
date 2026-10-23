import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/features/agent_context/domain/silly_tavern_preset.dart';
import 'package:aicove_flutter/src/features/agent_context/domain/silly_tavern_regex_processor.dart';
import 'package:aicove_flutter/src/features/agent_context/domain/silly_tavern_world_book.dart';

void main() {
  const processor = SillyTavernRegexProcessor();

  SillyTavernRegexScript script({
    required String id,
    required String find,
    required String replace,
    required List<int> placements,
    bool promptOnly = false,
    bool markdownOnly = false,
    bool disabled = false,
    int? minDepth,
    int? maxDepth,
    List<String> trimStrings = const <String>[],
  }) {
    return SillyTavernRegexScript(
      id: id,
      name: id,
      source: 'test',
      disabled: disabled,
      runOnEdit: false,
      findRegex: find,
      replaceString: replace,
      trimStrings: trimStrings,
      placements: placements,
      substituteRegex: 0,
      minDepth: minDepth,
      maxDepth: maxDepth,
      markdownOnly: markdownOnly,
      promptOnly: promptOnly,
    );
  }

  test(
    'oversized replacement preserves prior result and runs later rules',
    () async {
      final result = await processor.applyToDisplayText(
        text: 'foo',
        scripts: [
          script(id: 'before', find: 'foo', replace: 'bar', placements: [2]),
          script(
            id: 'oversized',
            find: 'bar',
            replace: 'x' * (SillyTavernRegexProcessor.maxInputCharacters + 1),
            placements: [2],
          ),
          script(id: 'after', find: 'bar', replace: 'done', placements: [2]),
        ],
        authorized: true,
      );
      expect(result.text, 'done');
      expect(
        result.traces.any((t) => t['reason'] == 'output_too_large'),
        isTrue,
      );
      expect(result.warnings, isNotEmpty);
    },
  );

  test(
    'invalid prompt regex preserves multimodal source and later rules run',
    () async {
      const messages = <Map<String, dynamic>>[
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'foo'},
            {
              'type': 'image_url',
              'image_url': {'url': 'fixture://image'},
            },
          ],
        },
        {'role': 'assistant', 'content': 'foo', 'reasoning_content': 'foo'},
      ];
      final result = await processor.applyToPromptMessages(
        messages: messages,
        scripts: [
          script(
            id: 'invalid',
            find: '/(/g',
            replace: '',
            placements: [1, 2, 6],
          ),
          script(
            id: 'valid',
            find: 'foo',
            replace: 'bar',
            placements: [1, 2, 6],
          ),
        ],
        authorized: true,
      );
      expect((result.messages.first['content'] as List).first['text'], 'bar');
      expect(
        (result.messages.first['content'] as List).last,
        (messages.first['content'] as List).last,
      );
      expect(result.messages.last['content'], 'bar');
      expect(result.messages.last['reasoning_content'], 'bar');
      expect(messages.last['content'], 'foo');
      expect(result.warnings, isNotEmpty);
    },
  );

  test(
    'world-info regex skips bad rule without changing original injection',
    () async {
      const scan = TavernWorldScanResult(
        [
          TavernWorldInjection(
            id: 'world',
            content: 'foo',
            position: 0,
            depth: 0,
            role: 'system',
            order: 0,
          ),
        ],
        [],
        [],
      );
      final result = await processor.applyToWorldInfo(
        scan: scan,
        scripts: [
          script(
            id: 'invalid',
            find: '/(/g',
            replace: '',
            placements: [5],
            promptOnly: true,
          ),
          script(
            id: 'valid',
            find: 'foo',
            replace: 'bar',
            placements: [5],
            promptOnly: true,
          ),
        ],
        authorized: true,
      );
      expect(result.injections.single.content, 'bar');
      expect(scan.injections.single.content, 'foo');
      expect(result.warnings, isNotEmpty);
    },
  );

  test(
    'engine failure preserves original text and later calls still work',
    () async {
      final text = '${'a' * 40}!';
      final result = await processor.applyToDisplayText(
        text: text,
        scripts: [
          script(
            id: 'backtracking',
            find: r'/(a+)+$/',
            replace: '',
            placements: [2],
          ),
        ],
        authorized: true,
      );
      expect(result.text, text);
      expect(result.warnings, isNotEmpty);
      final next = await processor.applyToDisplayText(
        text: 'foo',
        scripts: [
          script(id: 'valid', find: 'foo', replace: 'bar', placements: [2]),
        ],
        authorized: true,
      );
      expect(next.text, 'bar');
    },
  );

  test('authorization gates every regex mutation', () async {
    final result = await processor.applyToDisplayText(
      text: '<thinking>secret</thinking>',
      scripts: <SillyTavernRegexScript>[
        script(
          id: 'hide',
          find: r'/<thinking>[\s\S]*?<\/thinking>/g',
          replace: '',
          placements: const <int>[2],
          markdownOnly: true,
        ),
      ],
      authorized: false,
    );

    expect(result.text, '<thinking>secret</thinking>');
    expect(result.warnings, contains(contains('未授权')));
  });

  test(
    'prompt rules honor placement, depth, JS flags, and trim strings',
    () async {
      final result = await processor.applyToPromptMessages(
        messages: const <Map<String, dynamic>>[
          {'role': 'user', 'content': 'OLD'},
          {'role': 'assistant', 'content': '<thinking>`secret`</thinking>'},
          {'role': 'user', 'content': 'latest'},
        ],
        scripts: <SillyTavernRegexScript>[
          script(
            id: 'old-user-only',
            find: r'/^[\s\S]*$/gi',
            replace: '',
            placements: const <int>[1],
            promptOnly: true,
            minDepth: 1,
          ),
          script(
            id: 'assistant-cot',
            find: r'/<thinking>([^]*?)<\/thinking>/gis',
            replace: r'[$1]',
            placements: const <int>[2],
            promptOnly: true,
            trimStrings: const <String>['`'],
          ),
        ],
        authorized: true,
      );

      expect(result.messages[0]['content'], '');
      expect(result.messages[1]['content'], '[secret]');
      expect(result.messages[2]['content'], 'latest');
      expect(
        result.traces.where((trace) => trace['status'] == 'applied'),
        isNotEmpty,
      );
    },
  );

  test(
    'display runs general then markdown-only and skips invalid regex',
    () async {
      final result = await processor.applyToDisplayText(
        text: 'foo <tag>value</tag>',
        scripts: <SillyTavernRegexScript>[
          script(
            id: 'general',
            find: 'foo',
            replace: 'bar',
            placements: const <int>[2],
          ),
          script(
            id: 'markdown',
            find: r'/<tag>([\s\S]*?)<\/tag>/g',
            replace: r'<b>$1</b>',
            placements: const <int>[2],
            markdownOnly: true,
          ),
          script(
            id: 'invalid',
            find: '/(/g',
            replace: '',
            placements: const <int>[2],
            markdownOnly: true,
          ),
        ],
        authorized: true,
      );

      expect(result.text, 'bar <b>value</b>');
      expect(result.warnings, contains(contains('invalid')));
      expect(
        result.traces.any((trace) => trace['reason'] == 'invalid_regex'),
        isTrue,
      );
    },
  );

  test(
    'later scripts cannot repopulate text removed by an earlier script',
    () async {
      final result = await processor.applyToDisplayText(
        text: 'remove me',
        scripts: <SillyTavernRegexScript>[
          script(
            id: 'remove',
            find: r'/^[\s\S]*$/g',
            replace: '',
            placements: const <int>[2],
          ),
          script(
            id: 'repopulate',
            find: r'/^$/g',
            replace: 'unexpected',
            placements: const <int>[2],
          ),
        ],
        authorized: true,
      );

      expect(result.text, isEmpty);
    },
  );
  test('native JS identity escapes work without forced unicode mode', () async {
    final result = await processor.applyToPromptMessages(
      messages: const [
        {
          'role': 'assistant',
          'content': '<think_nya~>秘密</think_nya~><summary>花开了</summary>',
        },
      ],
      scripts: [
        script(
          id: 'summary',
          find: r'/[\s\S]*?\<summary\>([\s\S]*?)\<\/summary\>[\s\S]*/g',
          replace: r'$1',
          placements: [2],
          promptOnly: true,
        ),
      ],
      authorized: true,
    );
    expect(result.messages.single['content'], '花开了');
    expect(result.warnings, isEmpty);
  });
}
