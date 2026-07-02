import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/features/plugins/image/image_config.dart';

void main() {
  group('ImageConfig tool description blocks', () {
    test('default marker should resolve to built-in default blocks', () {
      const config = ImageConfig(
        drawingSystemPrompt: ImageConfig.defaultToolDescriptionPresetMarker,
      );

      final blocks = config.manualToolDescriptionBlocks;
      expect(blocks.toolDescription, ImageConfig.defaultToolDescription);
      expect(blocks.promptDescription, ImageConfig.defaultPromptDescription);
      expect(
        blocks.negativePromptDescription,
        ImageConfig.defaultNegativePromptDescription,
      );
    });

    test('legacy plain text should map to promptDescription', () {
      const config = ImageConfig(drawingSystemPrompt: 'legacy prompt text');

      final blocks = config.manualToolDescriptionBlocks;
      expect(blocks.promptDescription, 'legacy prompt text');
      expect(blocks.toolDescription, ImageConfig.defaultToolDescription);
    });

    test('selected preset blocks should override manual blocks', () {
      final custom = const DrawImageToolDescriptionBlocks(
        toolDescription: 'tool desc',
        promptDescription: 'prompt desc',
        negativePromptDescription: 'neg desc',
        widthDescription: 'w desc',
        heightDescription: 'h desc',
      );
      final preset = DrawingPromptPreset(
        name: 'p1',
        content: ImageConfig.encodeToolDescriptionBlocks(custom),
      );
      final config = ImageConfig(
        drawingSystemPrompt: ImageConfig.defaultToolDescriptionPresetMarker,
        systemPromptPresets: [preset],
        selectedSystemPromptPresetName: 'p1',
      );

      final blocks = config.effectiveToolDescriptionBlocks;
      expect(blocks.toolDescription, 'tool desc');
      expect(blocks.promptDescription, 'prompt desc');
      expect(blocks.negativePromptDescription, 'neg desc');
      expect(blocks.widthDescription, 'w desc');
      expect(blocks.heightDescription, 'h desc');
    });
  });
}
