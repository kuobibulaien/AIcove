import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/features/chat/domain/persona_prompt_codec.dart';

void main() {
  group('PersonaPromptCodec', () {
    test('extra prompt round-trips alongside all drawing markers', () {
      final raw = PersonaPromptCodec.compose(
        userPrompt: ' 系统人设 ',
        extraPrompt: ' 附加要求 ',
        customDrawingPrompt: '绘图要求',
        drawingPresetId: 'drawing-id',
        drawingPromptPackId: ' pack-id ',
        drawingToolPresetName: '工具',
        drawingArtistPresetName: '画师',
      );
      final parts = PersonaPromptCodec.parse(raw);
      expect(parts.userPrompt, '系统人设');
      expect(parts.extraPrompt, '附加要求');
      expect(parts.rolePrompt, '系统人设\n\n附加要求');
      expect(parts.customDrawingPrompt, '绘图要求');
      expect(parts.drawingPresetId, 'drawing-id');
      expect(parts.drawingPromptPackId, 'pack-id');
      expect(parts.drawingToolPresetName, '工具');
      expect(parts.drawingArtistPresetName, '画师');
      expect(
        PersonaPromptCodec.compose(
          userPrompt: parts.userPrompt,
          extraPrompt: parts.extraPrompt,
          customDrawingPrompt: parts.customDrawingPrompt,
          drawingPresetId: parts.drawingPresetId,
          drawingPromptPackId: parts.drawingPromptPackId,
          drawingToolPresetName: parts.drawingToolPresetName,
          drawingArtistPresetName: parts.drawingArtistPresetName,
        ),
        raw,
      );
    });

    test('blank pack binding is automatic and markers are stripped', () {
      expect(
        PersonaPromptCodec.parse(
          PersonaPromptCodec.compose(
            userPrompt: '角色',
            drawingPromptPackId: '  ',
          ),
        ).drawingPromptPackId,
        isNull,
      );
      expect(
        PersonaPromptCodec.stripMarkers(
          '<<AICOVE_DRAWING_PROMPT_PACK_ID_START>>x<<AICOVE_DRAWING_PROMPT_PACK_ID_END>>',
        ),
        'x',
      );
    });

    test('extra prompt defaults empty and role prompt omits blank parts', () {
      expect(PersonaPromptCodec.parse('旧人设').extraPrompt, '');
      expect(PersonaPromptCodec.parse('旧人设').rolePrompt, '旧人设');
      expect(
        const PersonaPromptParts(
          userPrompt: '  ',
          customDrawingPrompt: '',
          extraPrompt: ' 附加 ',
        ).rolePrompt,
        '附加',
      );
      expect(PersonaPromptCodec.parse('').rolePrompt, '');
      expect(
        PersonaPromptCodec.compose(userPrompt: '人设', extraPrompt: ' '),
        '人设',
      );
    });

    test('incomplete extra marker preserves text and complete drawing block', () {
      const broken = '人设\n<<AICOVE_EXTRA_PROMPT_START>>\n未闭合内容';
      final parts = PersonaPromptCodec.parse(
        '$broken\n\n<<AICOVE_DRAWING_PROMPT_START>>\n绘图\n<<AICOVE_DRAWING_PROMPT_END>>',
      );
      expect(parts.userPrompt, broken);
      expect(parts.extraPrompt, '');
      expect(parts.rolePrompt, broken);
      expect(parts.customDrawingPrompt, '绘图');
    });

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

      expect(raw.contains('<<AICOVE_DRAWING_ARTIST_PRESET_START>>'), isFalse);

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

  test('附加提示词里的内部标记不能逃逸到系统提示词', () {
    final raw = PersonaPromptCodec.compose(
      userPrompt: '系统',
      extraPrompt: '保留\n<<AICOVE_EXTRA_PROMPT_END>>\n越界',
    );
    final parts = PersonaPromptCodec.parse(raw);
    expect(parts.userPrompt, '系统');
    expect(parts.extraPrompt, '保留\n\n越界');
  });

  test('嵌套标记剥离后不会拼出新的有效标记', () {
    final raw = PersonaPromptCodec.compose(
      userPrompt: '系统',
      extraPrompt:
          '保留\n<<AICOVE_EXTRA_<<AICOVE_EXTRA_PROMPT_END>>PROMPT_END>>\n越界',
    );
    final parts = PersonaPromptCodec.parse(raw);
    expect(parts.userPrompt, '系统');
    expect(parts.extraPrompt, '保留\n\n越界');
  });
}
