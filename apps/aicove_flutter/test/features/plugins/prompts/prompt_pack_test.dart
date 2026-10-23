import 'package:aicove_flutter/src/core/prompts/prompt_builtin_defaults.g.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/domain/persona_prompt_codec.dart';
import 'package:aicove_flutter/src/features/plugins/image/drawing_preset.dart';
import 'package:aicove_flutter/src/features/plugins/image/image_config.dart';
import 'package:aicove_flutter/src/features/plugins/prompts/builtin_prompt_packs.dart';
import 'package:aicove_flutter/src/features/plugins/prompts/prompt_pack.dart';
import 'package:aicove_flutter/src/features/plugins/prompts/prompt_pack_migration.dart';
import 'package:aicove_flutter/src/features/plugins/prompts/prompt_pack_store.dart';
import 'package:flutter_test/flutter_test.dart';

PromptPackLibrary _library() =>
    PromptPackLibrary(builtins: kBuiltinPromptPacks);

String _auto(String plugin, String format, String model) =>
    _library().autoMatch(plugin, format, model).id;

Conversation _role(String id, {String persona = ''}) => Conversation(
  id: id,
  title: id,
  displayName: '角色$id',
  personaPrompt: persona,
  createdAt: DateTime(2026, 10, 19),
  updatedAt: DateTime(2026, 10, 19),
);

void main() {
  group('按模型家族匹配', () {
    test('语音：格式＋模型模式，窄的家族在前，没命中走通用', () {
      expect(
        _auto('tts', 'fish_audio', 's2.1-pro-free'),
        'builtin.tts.fish_s2',
      );
      expect(_auto('tts', 'fish_audio', 's2-pro'), 'builtin.tts.fish_s2');
      expect(_auto('tts', 'fish_audio', 's1'), 'builtin.tts.fish_s1');
      expect(_auto('tts', 'minimax', 'speech-2.8-hd'), 'builtin.tts.minimax');
      expect(
        _auto('tts', 'openai_tts', 'IndexTeam/IndexTTS-2'),
        'builtin.tts.indextts',
      );
      expect(_auto('tts', 'aliyun', 'cosyvoice-v3-plus'), 'builtin.tts.aliyun');
      expect(
        _auto('tts', 'openai_tts', 'gpt-4o-mini-tts'),
        'builtin.tts.generic',
      );
      // 不按网址猜：只有格式和模型参与。
      expect(
        _auto('tts', 'openai_tts', 'FunAudioLLM/CosyVoice2-0.5B'),
        'builtin.tts.aliyun',
      );
    });

    test('绘图：NovelAI、ComfyUI 通用、动漫底模、自然语言兜底', () {
      expect(
        _auto('image', 'novelai', 'nai-diffusion-4-5-full'),
        'builtin.image.novelai',
      );
      expect(_auto('image', 'comfyui', 'whatever'), 'builtin.image.comfyui');
      expect(
        _auto('image', 'comfyui', 'template/zimage_turbo'),
        'builtin.image.comfyui',
      );
      expect(
        _auto('image', 'openai', 'illustrious-xl-v2'),
        'builtin.image.danbooru',
      );
      expect(_auto('image', 'openai', 'gpt-image-1'), 'builtin.image.natural');
      expect(
        _auto('image', 'openai', 'doubao-seedream-4-0'),
        'builtin.image.natural',
      );
      expect(
        _auto('image', 'openai', 'unknown-model'),
        'builtin.image.natural',
      );
    });

    test('关键字不区分大小写，/…/ 按正则，坏正则不命中', () {
      const rule = PromptMatchRule(models: ['Flux', '/^sd-?xl/']);
      expect(rule.matches('openai', 'black-forest-labs/FLUX.1-dev'), isTrue);
      expect(rule.matches('openai', 'SDXL-base'), isTrue);
      expect(rule.matches('openai', 'my-sdxl'), isFalse);
      expect(PromptMatchRule.modelMatches('/(/', 'x'), isFalse);
      expect(PromptMatchRule.patternError('/(/'), isNotNull);
      expect(
        const PromptMatchRule(formats: ['comfyui']).matches('openai', 'x'),
        isFalse,
      );
    });

    test('自建包的规则优先于出厂包；绑定优先于一切', () {
      var library = _library().fork('builtin.tts.generic', newId: 'mine');
      library = library.saveCustom(
        library
            .require('mine')
            .copyWith(
              match: const [
                PromptMatchRule(formats: ['fish_audio'], models: ['s2.1']),
              ],
            ),
      );
      expect(library.autoMatch('tts', 'fish_audio', 's2.1-pro').id, 'mine');
      expect(
        library.autoMatch('tts', 'fish_audio', 's2-pro').id,
        'builtin.tts.fish_s2',
      );
      final bound = library.resolve(
        'tts',
        const PresetPromptBinding(packId: 'builtin.tts.minimax'),
        format: 'fish_audio',
        model: 's2.1-pro',
      );
      expect(bound.pack.id, 'builtin.tts.minimax');
      expect(bound.automatic, isFalse);
    });

    test('绑定的包不存在时报错，不静默回退', () {
      expect(
        () => _library().resolve(
          'tts',
          const PresetPromptBinding(packId: 'gone'),
          format: 'fish_audio',
          model: 's2',
        ),
        throwsA(isA<PromptPackMissingException>()),
      );
      expect(
        () => _library().resolve(
          'tts',
          const PresetPromptBinding(packId: 'builtin.image.novelai'),
          format: 'fish_audio',
          model: 's2',
        ),
        throwsA(isA<PromptPackMissingException>()),
      );
    });
  });

  group('渲染', () {
    test('Fish S2 包含改造前的全部说明原文，变量被替换', () {
      final text = _library()
          .resolve(
            'tts',
            const PresetPromptBinding(),
            format: 'fish_audio',
            model: 's2.1-pro',
          )
          .render(PromptScopes.ttsChat, {'max_chars_per_chunk': 30});
      expect(text, contains('不要超过 30 个字'));
      expect(text, contains('【Fish Audio (S2/S2.1) 语音控制】'));
      expect(text, contains('[高潮的娇喘]'));
      expect(text, contains('严禁包含颜文字'));
      expect(text, isNot(contains('MiniMax')));
      expect(text, isNot(contains('{')));
    });

    test('MiniMax 包含语气词与停顿说明；频率为 0 只发不使用语音', () {
      final pack = _library().resolve(
        'tts',
        const PresetPromptBinding(),
        format: 'minimax',
        model: 'speech-2.8-hd',
      );
      final chat = pack.render(PromptScopes.ttsChat, {
        'max_chars_per_chunk': 20,
      });
      expect(
        chat,
        contains(
          PromptBuiltinDefaults.requireTemplate(
            'tts.minimax_guide',
          ).split('\n').first,
        ),
      );
      expect(chat, contains('<#1.5#>'));
      expect(
        pack.render(PromptScopes.ttsChatOff),
        PromptBuiltinDefaults.requireTemplate('tts.disabled_voice_frequency'),
      );
      expect(pack.render(PromptScopes.ttsCall), isEmpty);
    });

    test('通话说明只有 Fish 包有', () {
      String call(String format, String model) => _library()
          .resolve(
            'tts',
            const PresetPromptBinding(),
            format: format,
            model: model,
          )
          .render(PromptScopes.ttsCall);
      expect(call('fish_audio', 's2.1-pro'), contains('方括号'));
      expect(call('fish_audio', 's1'), contains('圆括号'));
      expect(call('openai_tts', 'IndexTTS-2'), isEmpty);
    });

    test('NovelAI 快速模式保留花括号权重与 64 倍数契约，填入预设参数', () {
      final text = _library()
          .resolve(
            'image',
            const PresetPromptBinding(),
            format: 'novelai',
            model: 'nai',
          )
          .render(PromptScopes.imageInline, {
            'default_width': 832,
            'default_height': 1216,
            'default_count': 1,
            'default_steps': 28,
            'default_guidance_scale': 5.0,
          });
      expect(text, contains('{{{pov}}}'));
      expect(text, contains('{pov_hands}'));
      expect(text, contains('"width":832,"height":1216'));
      expect(text, contains('"steps":28,"guidance_scale":5.0'));
      expect(text, contains('64的倍数'));
    });

    test('自然语言包不教标签与权重，也不给 steps', () {
      final text = _library()
          .resolve(
            'image',
            const PresetPromptBinding(),
            format: 'openai',
            model: 'gpt-image-1',
          )
          .render(PromptScopes.imageInline, {'default_width': 1024});
      expect(text, contains('完整的英文句子'));
      expect(text, isNot(contains('Danbooru 标签为骨架')));
      expect(text, contains('不支持 steps'));
    });

    test('预设专属节排在包后面，关掉的节不发', () {
      final binding = const PresetPromptBinding()
          .upsertSection(
            const PromptSection(
              id: 'own',
              scope: PromptScopes.ttsChat,
              title: '口癖',
              text: '句尾多用「呀」',
            ),
          )
          .upsertSection(
            const PromptSection(
              id: 'off',
              scope: PromptScopes.ttsChat,
              title: '关',
              text: '不该出现',
              enabled: false,
            ),
          );
      final text = _library()
          .resolve('tts', binding, format: 'minimax', model: 'speech-2.8-hd')
          .render(PromptScopes.ttsChat);
      expect(text.trim().endsWith('句尾多用「呀」'), isTrue);
      expect(text, isNot(contains('不该出现')));
    });
  });

  group('编辑与存储', () {
    test('出厂包只存差异；改回原文或恢复默认即清除', () {
      var library = _library().editSection(
        'builtin.tts.fish_s2',
        'tts.text',
        text: '新规范',
      );
      expect(library.isModified('builtin.tts.fish_s2', 'tts.text'), isTrue);
      expect(
        library.require('builtin.tts.fish_s2').section('tts.text')!.text,
        '新规范',
      );
      // 别的包里同 id 的节不受影响。
      expect(
        library.require('builtin.tts.minimax').section('tts.text')!.text,
        isNot('新规范'),
      );
      final json = library.toJson();
      expect(json['overrides'], {
        'builtin.tts.fish_s2': {
          'sections': {
            'tts.text': {'text': '新规范'},
          },
        },
      });
      library = library.restoreSection('builtin.tts.fish_s2', 'tts.text');
      expect(library.overrides, isEmpty);
      final factory = _library()
          .require('builtin.tts.fish_s2')
          .section('tts.text')!
          .text;
      library = library
          .editSection('builtin.tts.fish_s2', 'tts.text', text: '新规范')
          .editSection('builtin.tts.fish_s2', 'tts.text', text: factory);
      expect(library.overrides, isEmpty);
    });

    test('出厂节只能关，自己加的节可以删；往返 JSON 不变', () {
      var library = _library()
          .editSection(
            'builtin.image.novelai',
            'novelai.inline',
            enabled: false,
          )
          .addSection(
            'builtin.image.novelai',
            const PromptSection(
              id: 'x',
              scope: PromptScopes.imageInline,
              title: '我的',
              text: '多画猫',
            ),
          );
      expect(
        () => library.removeSection('builtin.image.novelai', 'novelai.inline'),
        throwsStateError,
      );
      expect(
        () => library.addSection(
          'builtin.image.novelai',
          const PromptSection(
            id: 'y',
            scope: PromptScopes.ttsChat,
            title: '',
            text: '',
          ),
        ),
        throwsStateError,
      );
      final restored = PromptPackState.fromJson(
        PromptPackState(library, migrations: {'m'}).toJson(),
      );
      expect(restored.library.toJson(), library.toJson());
      expect(restored.migrations, {'m'});
      library = library.removeSection('builtin.image.novelai', 'x');
      expect(library.require('builtin.image.novelai').section('x'), isNull);
    });

    test('另存为新包不带走出厂匹配规则；自建包可改可删，出厂包不能删', () {
      var library = _library().fork(
        'builtin.tts.fish_s2',
        newId: 'copy',
        name: '纳西妲',
      );
      final copy = library.require('copy');
      expect(copy.name, '纳西妲');
      expect(copy.match, isEmpty);
      expect(copy.fallback, isFalse);
      expect(
        copy.sections.length,
        library.require('builtin.tts.fish_s2').sections.length,
      );
      library = library.editSection(
        'copy',
        'fish_s2.nsfw_example',
        enabled: false,
      );
      expect(
        library.require('copy').section('fish_s2.nsfw_example')!.enabled,
        isFalse,
      );
      expect(
        () => library.saveCustom(
          copy.copyWith(
            match: const [
              PromptMatchRule(models: ['/(/']),
            ],
          ),
        ),
        throwsStateError,
      );
      expect(
        () => library.deleteCustom('builtin.tts.generic'),
        throwsStateError,
      );
      expect(library.deleteCustom('copy').byId('copy'), isNull);
    });
  });

  group('迁移', () {
    test('改过的全局语音／绘图说明变成未绑定的自建包，只做一次', () {
      var state = PromptPackState.initial();
      state = migrateGlobalSlots(state, {
        'tts': '我的语音说明{minimax_guide}',
        'image': '我的画图说明',
        'sticker': 'x',
      });
      final tts = state.library.require('legacy.tts.global');
      expect(tts.section('legacy.text')!.text, '我的语音说明');
      expect(tts.match, isEmpty);
      final image = state.library.require('legacy.image.global');
      expect(image.section('legacy.text')!.text, '我的画图说明');
      expect(image.section('legacy.contract'), isNotNull);
      final again = migrateGlobalSlots(state, {'tts': '别的'});
      expect(identical(again, state), isTrue);
    });

    test('与出厂相同的全局说明不迁移', () {
      final state = migrateGlobalSlots(PromptPackState.initial(), {
        'image': ImageConfig.defaultInlinePromptTemplate,
      });
      expect(state.library.custom, isEmpty);
    });

    test('预设里改过的 draw_image 说明生成专属包并绑回原预设', () {
      final edited = const ImageConfig().copyWith(
        drawingSystemPrompt: ImageConfig.encodeToolDescriptionBlocks(
          ImageConfig.runtimeDefaultToolDescriptionBlocks.copyWith(
            promptDescription: '只用水彩风格',
          ),
        ),
      );
      final catalog = DrawingPresetCatalog(
        presets: [
          const DrawingPreset(id: 'a', name: '默认', config: ImageConfig()),
          DrawingPreset(id: 'b', name: '水彩', config: edited),
        ],
        defaultPresetId: 'a',
        legacyConfig: const ImageConfig(),
      );
      final result = migrateDrawingTools(PromptPackState.initial(), catalog);
      expect(result.changed.map((p) => p.id), ['b']);
      final packId = result.changed.single.prompts.packId!;
      final pack = result.state.library.require(packId);
      expect(pack.section('novelai.prompt')!.text, startsWith('只用水彩风格'));
      expect(
        result.state.migrations,
        isNot(contains(PromptPackMigrations.drawingTools)),
      );
      expect(
        markDrawingToolsDone(result.state).migrations,
        contains(PromptPackMigrations.drawingTools),
      );
    });

    test('角色绘图提示：独占的预设直接加专属节，共用的复制一份只给它', () {
      final catalog = DrawingPresetCatalog(
        presets: const [
          DrawingPreset(id: 'default', name: '默认绘图', config: ImageConfig()),
          DrawingPreset(id: 'own', name: '专用', config: ImageConfig()),
        ],
        defaultPresetId: 'default',
        legacyConfig: const ImageConfig(),
      );
      final solo = _role(
        '1',
        persona: PersonaPromptCodec.compose(
          userPrompt: '人设',
          customDrawingPrompt: '绿发少女',
          drawingPresetId: 'own',
        ),
      );
      final onDefault = _role(
        '2',
        persona: PersonaPromptCodec.compose(
          userPrompt: '人设2',
          customDrawingPrompt: '白发',
        ),
      );
      final roles = [solo, onDefault];

      final first = planRoleDrawingMove(solo, catalog, roles)!;
      expect(first.preset.id, 'own');
      expect(first.preset.prompts.ownSections.map((s) => s.id), [
        kRoleDrawingInlineSection,
        kRoleDrawingToolSection,
      ]);
      final parts = PersonaPromptCodec.parse(first.personaPrompt);
      expect(parts.customDrawingPrompt, isEmpty);
      expect(parts.userPrompt, '人设');
      expect(parts.drawingPresetId, 'own');

      final second = planRoleDrawingMove(onDefault, catalog, roles)!;
      expect(second.preset.id, 'drawing_role_2_default');
      expect(second.preset.name, '角色2 · 默认绘图');
      expect(second.preset.prompts.ownSections.first.text, contains('白发'));
      expect(
        PersonaPromptCodec.parse(second.personaPrompt).drawingPresetId,
        'drawing_role_2_default',
      );

      // 写入时基于当前存储的预设合并：期间别处的修改保留。
      final edited = catalog.upsert(
        catalog.require('own').copyWith(name: '迁移期间改了名'),
      );
      final applied = first.applyTo(edited).require('own');
      expect(applied.name, '迁移期间改了名');
      expect(applied.prompts.ownSections, hasLength(2));
      // 重跑不重复加节。
      expect(
        first.applyTo(first.applyTo(edited)).require('own').prompts.ownSections,
        hasLength(2),
      );
      expect(first.sourcePersona, solo.personaPrompt);

      // 已迁移的角色不再处理。
      expect(
        planRoleDrawingMove(
          _role('1', persona: first.personaPrompt),
          catalog,
          roles,
        ),
        isNull,
      );
    });

    test('角色绘图专属节在快速和自动两条路线都生效', () {
      var binding = const PresetPromptBinding();
      for (final s in roleDrawingSections('绿发少女')) {
        binding = binding.upsertSection(s);
      }
      final pack = _library().resolve(
        'image',
        binding,
        format: 'novelai',
        model: 'nai',
      );
      expect(
        pack.render(PromptScopes.imageInline),
        endsWith('角色专属生图要求：\n绿发少女'),
      );
      expect(
        pack.render(PromptScopes.imageToolPrompt),
        endsWith('【角色专属生图要求】\n绿发少女'),
      );
    });
  });

  test('ComfyUI 跑自然语言模型时走自然语言包，其余走 ComfyUI 通用包', () {
    final library = _library();
    expect(
      library.autoMatch('image', 'comfyui', 'flux1-dev.safetensors').id,
      'builtin.image.natural',
    );
    expect(
      library.autoMatch('image', 'comfyui', 'sd3.5_large').id,
      'builtin.image.natural',
    );
    expect(
      library.autoMatch('image', 'comfyui', 'waiNSFWIllustrious_v14').id,
      'builtin.image.comfyui',
    );
    expect(
      library.autoMatch('image', 'comfyui', '').id,
      'builtin.image.comfyui',
    );
  });

  test('旧作用域读作合并后的节，改过的出厂节保留为自建节', () {
    expect(PromptScopes.canonical('tool.width'), PromptScopes.imageToolParams);
    expect(
      PromptScopes.canonical('tool.negative_prompt'),
      PromptScopes.imageToolPrompt,
    );
    final library = PromptPackLibrary.fromJson(
      {
        'version': 1,
        'overrides': {
          'builtin.image.natural': {
            'sections': {
              'natural.tool_prompt': {'text': '我改过的提示词'},
              'image.tool_width': {'text': '我改过的宽度'},
              'natural.inline': {'enabled': false},
            },
          },
        },
      },
      builtins: kBuiltinPromptPacks,
    );
    final pack = library.require('builtin.image.natural');
    expect(pack.section('natural.tool_prompt'), isNull);
    expect(
      pack.sections.where((s) => s.text == '我改过的提示词').single.scope,
      PromptScopes.imageToolPrompt,
    );
    expect(
      pack.sections.where((s) => s.text == '我改过的宽度').single.scope,
      PromptScopes.imageToolParams,
    );
  });
}
