import 'package:aicove_flutter/src/features/agent_context/domain/preset_tag_mapping.dart';
import 'package:aicove_flutter/src/features/agent_context/domain/silly_tavern_preset_parser.dart';
import 'package:aicove_flutter/src/features/content_tags/domain/tag_presentation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('comic_plan defaults to a folded storyboard plan', () {
    final rule = builtinPresetTagMapping.presentationMap['comic_plan']!;
    expect(rule.presentation, TagPresentation.fold);
    expect(rule.title, '分镜规划');
  });

  test(
    'extracts artist prompts including disabled choices without losing compatibility data',
    () {
      final preset = const SillyTavernPresetParser().parseMap(
        {
          'prompts': [
            {
              'identifier': 'a',
              'name': '画风-水彩',
              'content': '[正面]\nwatercolor, artist:a\n[负面]\nlowres',
            },
            {'identifier': 'b', 'name': '画风：漫画', 'content': '[正面]comic'},
            {
              'identifier': 'c',
              'name': '画风:素描',
              'content': '[正面]sketch[负面]blur',
            },
            {'identifier': 'd', 'name': '画风-无效', 'content': 'no marker'},
            {'identifier': 'e', 'name': '其他画风-无效', 'content': '[正面]ignored'},
          ],
          'prompt_order': [
            {'identifier': 'a'},
            {'identifier': 'b', 'enabled': false},
          ],
        },
        sourceFileName: 'artist.json',
        compatibilityData: {'custom': 42},
      );
      expect(preset.compatibilityData['custom'], 42);
      expect(preset.compatibilityData['extractedArtistPresets'], [
        {
          'name': '水彩',
          'content': 'watercolor, artist:a',
          'negativeContent': 'lowres',
        },
        {'name': '漫画', 'content': 'comic', 'negativeContent': ''},
        {'name': '素描', 'content': 'sketch', 'negativeContent': 'blur'},
      ]);
    },
  );
}
