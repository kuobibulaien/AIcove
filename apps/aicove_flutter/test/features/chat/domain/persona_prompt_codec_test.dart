import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/features/chat/domain/persona_prompt_codec.dart';

void main() {
  group('PersonaPromptCodec', () {
    test('compose and parse with drawing bindings', () {
      final raw = PersonaPromptCodec.compose(
        userPrompt: '你是温柔女友',
        customDrawingPrompt: '第一视角，保持人物一致性',
        drawingToolPresetName: '默认',
        drawingArtistPresetName: '防冻液',
      );

      final parts = PersonaPromptCodec.parse(raw);
      expect(parts.userPrompt, '你是温柔女友');
      expect(parts.customDrawingPrompt, '第一视角，保持人物一致性');
      expect(parts.drawingToolPresetName, '默认');
      expect(parts.drawingArtistPresetName, '防冻液');
    });

    test('compose and parse explicit artist preset disable binding', () {
      final raw = PersonaPromptCodec.compose(
        userPrompt: '你是温柔女友',
        drawingArtistPresetName: PersonaPromptCodec.artistPresetDisabledBinding,
      );

      final parts = PersonaPromptCodec.parse(raw);
      expect(
        parts.drawingArtistPresetName,
        PersonaPromptCodec.artistPresetDisabledBinding,
      );
    });

    test('follow-global artist preset should omit artist binding marker', () {
      final raw = PersonaPromptCodec.compose(
        userPrompt: '你是温柔女友',
        customDrawingPrompt: '第一视角，保持人物一致性',
        drawingToolPresetName: '默认',
      );

      expect(
        raw.contains('<<AICOVE_DRAWING_ARTIST_PRESET_START>>'),
        isFalse,
      );

      final parts = PersonaPromptCodec.parse(raw);
      expect(parts.drawingArtistPresetName, isNull);
    });

    test('parse legacy drawing prompt without preset bindings', () {
      const legacy = '''
角色设定文本

<<AICOVE_DRAWING_PROMPT_START>>
旧版生图补充
<<AICOVE_DRAWING_PROMPT_END>>
''';
      final parts = PersonaPromptCodec.parse(legacy);
      expect(parts.userPrompt, '角色设定文本');
      expect(parts.customDrawingPrompt, '旧版生图补充');
      expect(parts.drawingToolPresetName, isNull);
      expect(parts.drawingArtistPresetName, isNull);
    });

    test('incomplete marker should fallback to plain user prompt', () {
      const broken = '''
角色设定文本
<<AICOVE_DRAWING_PROMPT_START>>
未闭合内容
''';
      final parts = PersonaPromptCodec.parse(broken);
      expect(parts.userPrompt, broken.trim());
      expect(parts.customDrawingPrompt, '');
      expect(parts.drawingToolPresetName, isNull);
      expect(parts.drawingArtistPresetName, isNull);
    });
  });
}
