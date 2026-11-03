import 'package:aicove_flutter/src/features/chat/services/chat_reply_display_transform.dart';
import 'package:aicove_flutter/src/features/agent_context/domain/silly_tavern_preset.dart';
import 'package:flutter_test/flutter_test.dart';

const plan = '''<comic_plan>
- 角色母表:
  - C1:
    - 固定身份词: silver hair, green eyes
    - 初始服装词: white dress
  - C2:
    - 固定身份词: black hair
    - 初始服装词: blue shirt
</comic_plan>''';

void main() {
  test(
    'expands all aliases in each image, preserving dialogue and other text',
    () {
      const image = '''<image>@page
@C1, @C1_id, @C1_identity, @C1_outfit, @C1_costume
Text: @C1 says @C1_outfit
@C2 is dialogue too
@panel
@C2, @C2_costume, @C3, @C10, @C1_unknown</image>''';
      final result = expandComicPlanCharacterVariables(
        '$plan outside @C1$image$image',
      );
      expect(result, startsWith('$plan outside @C1'));
      expect('silver hair'.allMatches(result), hasLength(7));
      expect(
        result,
        contains('Text: @C1 says @C1_outfit\n@C2 is dialogue too'),
      );
      expect(
        result,
        contains('black hair, blue shirt, @C3, @C10, @C1_unknown'),
      );
    },
  );

  test(
    'missing dictionary stays unchanged and expansions do not leak between turns',
    () {
      const image = '<image>@C1 @C1_outfit</image>';
      expect(expandComicPlanCharacterVariables(image), image);
      expandComicPlanCharacterVariables('$plan$image');
      expect(expandComicPlanCharacterVariables(image), image);
      expect(
        expandComicPlanCharacterVariables(
          '<comic_plan>unrelated</comic_plan>$image',
        ),
        '<comic_plan>unrelated</comic_plan>$image',
      );
    },
  );

  test(
    'expands before thinking extraction and display regex hides the mother table',
    () async {
      final source = AssistantReplyDisplaySource(
        '<think>$plan</think><image>@C1, @C1_outfit</image>',
      );
      final projected = await source.project(
        scripts: const [
          SillyTavernRegexScript(
            id: 'hide',
            name: 'hide',
            source: 'test',
            disabled: false,
            runOnEdit: false,
            findRegex: r'/<comic_plan>[\s\S]*?<\/comic_plan>/g',
            replaceString: '',
            trimStrings: [],
            placements: [2],
            substituteRegex: 0,
            minDepth: null,
            maxDepth: null,
            markdownOnly: true,
            promptOnly: false,
          ),
        ],
        authorized: true,
      );
      expect(
        projected.regexResult.text,
        '<image>silver hair, green eyes, white dress</image>',
      );
    },
  );
}
