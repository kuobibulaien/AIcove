import 'package:aicove_flutter/src/features/chat/services/chat_reply_display_transform.dart';
import 'package:aicove_flutter/src/features/agent_context/domain/silly_tavern_preset.dart';
import 'package:aicove_flutter/src/features/agent_plugins/plugin_response.dart';
import 'package:aicove_flutter/src/features/plugins/domain/plugin.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('expandComicPlanVariablesInPrompt', () {
    const plan = '''<comic_plan>
- 角色母表:
  - C1:
    - 固定身份词: silver hair
    - 固定外貌词: green eyes
    - 初始服装词: white dress
    - 当前服装词: red coat
  - C2:
    - 固定身份词: black hair
    - 初始服装词: blue shirt
</comic_plan>''';

    test('expands aliases and preserves dialogue and unknown variables', () {
      const prompt = '''@page
@C1, @C1_id, @C1_identity, @C1_outfit, @C1_costume
Text: @C1 says @C1_outfit
@C2 stays dialogue
@panel
@C2, @C2_costume, @C3, @C10, @C1_unknown''';
      expect(
        expandComicPlanVariablesInPrompt(prompt, contextTexts: [plan]),
        '''@page
silver hair, green eyes, silver hair, green eyes, silver hair, green eyes, red coat, red coat
Text: @C1 says @C1_outfit
@C2 stays dialogue
@panel
black hair, blue shirt, @C3, @C10, @C1_unknown''',
      );
    });

    test('newer definitions win while omitted values remain available', () {
      const update = '''<comic_plan>
- 角色母表:
  - C1:
    - 当前服装词: black jacket
  - C2:
    - 固定身份词: brown hair
</comic_plan>''';
      const prompt = '@C1; @C1_outfit; @C2; @C2_outfit';
      expect(
        expandComicPlanVariablesInPrompt(
          prompt,
          contextTexts: [plan, 'a tool result without a plan', update],
        ),
        'silver hair, green eyes; black jacket; brown hair; blue shirt',
      );
      expect(
        expandComicPlanVariablesInPrompt(prompt, contextTexts: [update, plan]),
        'silver hair, green eyes; red coat; black hair; blue shirt',
      );
    });

    test(
      'visible plans take precedence and thinking-only plans still work',
      () {
        final hidden = plan.replaceAll('silver hair', 'hidden hair');
        expect(
          expandComicPlanVariablesInPrompt(
            '@C1',
            contextTexts: ['<think>$hidden</think>$plan'],
          ),
          'silver hair, green eyes',
        );
        expect(
          expandComicPlanVariablesInPrompt(
            '@C1',
            contextTexts: ['<think>$hidden</think>'],
          ),
          'hidden hair, green eyes',
        );
      },
    );

    test(
      'visible definitions override thinking without dropping omitted values',
      () {
        const earlier = '''<comic_plan>
- 角色母表:
  - C1:
    - 固定身份词: silver hair
    - 初始服装词: white dress
</comic_plan>''';
        const reasoning = '''<comic_plan>
- 角色母表:
  - C1:
    - 固定身份词: gold hair
    - 初始服装词: red dress
</comic_plan>''';
        const visible = '''<comic_plan>
- 角色母表:
  - C1:
    - 固定身份词: green hair
</comic_plan>''';
        const source = '<think>$reasoning</think>$visible';
        expect(
          expandComicPlanVariablesInPrompt(
            '@C1, @C1_outfit',
            contextTexts: [earlier, source],
          ),
          'green hair, red dress',
        );
        expect(
          expandComicPlanCharacterVariables(
            '$source<image>@C1, @C1_outfit</image>',
          ),
          '$source<image>green hair, @C1_outfit</image>',
        );
      },
    );

    test(
      'empty or missing plans stay literal without leaking between calls',
      () {
        const prompt = '@C1 @C1_outfit';
        expandComicPlanVariablesInPrompt(prompt, contextTexts: [plan]);
        expect(
          expandComicPlanVariablesInPrompt(prompt, contextTexts: const []),
          prompt,
        );
        expect(
          expandComicPlanVariablesInPrompt(
            prompt,
            contextTexts: const ['<comic_plan>unrelated</comic_plan>'],
          ),
          prompt,
        );
      },
    );
  });

  test(
    'thinking and transport markers are removed before display projection',
    () async {
      final source = AssistantReplyDisplaySource(
        '<think>inline thought</think>SECRET [图片: hint]\n__AICOVE_DRAW_IMAGE_REVIEW__internal',
        reasoning: 'native thought',
      );
      expect(source.text, 'SECRET <image></image>');
      expect(source.reasoning, 'native thought');
      final projected = await source.project(
        scripts: const [],
        authorized: false,
      );
      expect(projected.regexResult.text, source.text);
    },
  );

  test(
    'regex protects payload; ordered processors see display text once',
    () async {
      final source = AssistantReplyDisplaySource(
        '<think>thought</think>SECRET <tts>SECRET</tts>',
      );
      final projected = await source.project(
        scripts: const [
          SillyTavernRegexScript(
            id: 'display',
            name: 'display',
            source: 'test',
            disabled: false,
            runOnEdit: false,
            findRegex: '/SECRET/g',
            replaceString: 'VISIBLE',
            trimStrings: [],
            placements: [2],
            substituteRegex: 0,
            minDepth: null,
            maxDepth: null,
            markdownOnly: false,
            promptOnly: false,
          ),
        ],
        authorized: true,
      );
      final seen = <String>[];
      final result = await projected.process(
        processors: [
          ResponseFunction('late', (text) async {
            seen.add(text);
            return PluginProcessResult(
              processedText: '$text!late',
              events: [PluginEvent(pluginId: 'late', type: 'event', data: {})],
            );
          }, order: ResponseOrder.afterTagRemoval),
          ResponseFunction(
            'broken',
            (text) async => throw StateError('processor failed'),
          ),
          ResponseFunction('first', (text) async {
            seen.add(text);
            return PluginProcessResult(
              processedText: '$text!first',
              events: const [],
            );
          }),
        ],
        logTag: 'test',
      );
      expect(source.text, 'SECRET <tts>SECRET</tts>');
      expect(source.reasoning, 'thought');
      expect(projected.regexResult.text, 'VISIBLE <tts>SECRET</tts>');
      expect(seen, [
        'VISIBLE <tts>SECRET</tts>',
        'VISIBLE <tts>SECRET</tts>!first',
      ]);
      expect(result.processedText, 'VISIBLE <tts>SECRET</tts>!first!late');
      expect(result.events, hasLength(1));
    },
  );

  test(
    'empty tool-round placeholders skip processors; single empty reply retains its contract',
    () async {
      final projected = await AssistantReplyDisplaySource(
        '  ',
      ).project(scripts: const [], authorized: false);
      var calls = 0;
      final processors = [
        ResponseFunction('count', (text) async {
          calls++;
          return PluginProcessResult(processedText: text, events: const []);
        }),
      ];
      await projected.process(
        processors: processors,
        logTag: 'test',
        skipEmpty: true,
      );
      expect(calls, 0);
      await projected.process(processors: processors, logTag: 'test');
      expect(calls, 1);
    },
  );
}
