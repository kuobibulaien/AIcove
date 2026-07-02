import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/core/services/prompt_tag_semantics_service.dart';

void main() {
  group('PromptTagSemanticsService', () {
    test('只汇总启用且非空的标签说明', () {
      const service = PromptTagSemanticsService();

      final snapshot = service.buildSnapshot(
        const <PromptTagSemanticsEntry>[
          PromptTagSemanticsEntry(
            id: 'system-reminder',
            tagName: '<system-reminder>',
            prompt: 'system reminder prompt',
          ),
          PromptTagSemanticsEntry(
            id: 'tts',
            tagName: '<tts>',
            prompt: '',
          ),
          PromptTagSemanticsEntry(
            id: 'image',
            tagName: '<image>',
            prompt: 'image prompt',
            enabled: false,
          ),
        ],
      );

      expect(snapshot.activeEntries, hasLength(1));
      expect(snapshot.activeEntries.first.tagName, '<system-reminder>');
      expect(snapshot.mergedPrompt, contains('system reminder prompt'));
      expect(snapshot.mergedPrompt, isNot(contains('image prompt')));
      expect(
        snapshot.mergedPrompt,
        startsWith(PromptTagSemanticsService.defaultLeadIn),
      );
    });

    test('允许自定义前导说明', () {
      const service = PromptTagSemanticsService();

      final prompt = service.buildMergedPrompt(
        const <PromptTagSemanticsEntry>[
          PromptTagSemanticsEntry(
            id: 'tts',
            tagName: '<tts>',
            prompt: 'tts prompt',
          ),
          PromptTagSemanticsEntry(
            id: 'image',
            tagName: '<image>',
            prompt: 'image prompt',
          ),
        ],
        leadIn: '自定义前导',
      );

      expect(prompt, startsWith('自定义前导'));
      expect(prompt, contains('tts prompt'));
      expect(prompt, contains('image prompt'));
    });
  });
}
