import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/features/agent_context/domain/silly_tavern_preset.dart';
import 'package:aicove_flutter/src/features/agent_context/domain/silly_tavern_regex_processor.dart';

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
}
