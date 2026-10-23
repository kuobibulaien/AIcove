// ADR0092: the assistant reads and edits plugin prompt packs and presets'
// own sections; every write goes through the journal and undoes.
import 'dart:convert';
import 'dart:io';

import 'package:aicove_flutter/src/features/agent_plugins/file_change_journal.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_prompt_pack_tools.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_review.dart';
import 'package:aicove_flutter/src/features/plugins/prompts/builtin_prompt_packs.dart';
import 'package:aicove_flutter/src/features/plugins/prompts/prompt_pack.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  late PromptPackLibrary library;
  late Map<String, AssistantPromptPreset> presets;
  late FileChangeJournal journal;
  late AssistantPromptPackTools tools;

  Future<void> change(
    PromptPackLibrary Function(PromptPackLibrary) edit,
  ) async => library = edit(library);
  Future<List<AssistantPromptPreset>> listPresets() async =>
      presets.values.toList();
  Future<bool> save(
    String plugin,
    String id,
    PresetPromptBinding binding, {
    PresetPromptBinding? expected,
  }) async {
    final p = presets[id]!;
    if (expected != null &&
        !samePromptState(p.binding.toJson(), expected.toJson())) {
      return false;
    }
    presets[id] = AssistantPromptPreset(
      pluginId: p.pluginId,
      id: p.id,
      name: p.name,
      binding: binding,
      format: p.format,
      model: p.model,
      variables: p.variables,
    );
    return true;
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('prompt_pack_tools');
    library = PromptPackLibrary(builtins: kBuiltinPromptPacks);
    presets = {
      'fish': const AssistantPromptPreset(
        pluginId: 'tts',
        id: 'fish',
        name: '纳西妲音色',
        binding: PresetPromptBinding(),
        format: 'fish_audio',
        model: 's2-pro',
        variables: {'max_chars_per_chunk': 300, 'voice_frequency': 50},
      ),
      'nai': const AssistantPromptPreset(
        pluginId: 'image',
        id: 'nai',
        name: '纳西妲绘图',
        binding: PresetPromptBinding(),
        format: 'novelai',
        model: 'nai-diffusion-4-5-full',
        variables: {'default_width': 832, 'default_height': 1216},
      ),
    };
    final packApplier = AssistantPromptPackApplier(
      library: () async => library,
      change: change,
      boundBy: (id) async => [
        for (final p in presets.values)
          if (p.binding.packId == id) (id: p.id, name: p.name),
      ],
    );
    final presetApplier = AssistantPresetPromptsApplier(
      presets: listPresets,
      save: save,
    );
    journal = FileChangeJournal(
      file: () async => File('${dir.path}/journal.json'),
      appliers: {
        assistantPromptPackChangeKind: packApplier,
        assistantPresetPromptsChangeKind: presetApplier,
        assistantPromptPackForkChangeKind: AssistantPromptPackForkApplier(
          packs: packApplier,
          presets: presetApplier,
        ),
      },
    );
    tools = AssistantPromptPackTools(
      library: () async => library,
      change: change,
      presets: listPresets,
      journal: journal,
    );
  });

  tearDown(() => dir.delete(recursive: true));

  Future<Map<String, dynamic>> run(
    String name,
    Map<String, dynamic> args,
  ) async =>
      jsonDecode(
            (await tools
                .tools()
                .singleWhere((t) => t.name == name)
                .handler(args))!,
          )
          as Map<String, dynamic>;

  Future<void> undoAll() async {
    for (final entry in await journal.recent()) {
      await journal.undo(entry.id);
    }
  }

  test('lists packs and what each preset uses on 「自动」', () async {
    final result = await run(AssistantPromptPackTools.listTool, {
      'plugin': 'tts',
    });
    final presetRows = result['presets'] as List;
    expect(presetRows.single['pack'], 'auto');
    expect(presetRows.single['using'], 'builtin.tts.fish_s2');
    expect(
      (result['packs'] as List).map((p) => p['id']),
      contains('builtin.tts.minimax'),
    );
    expect(
      tools.riskOf(AssistantPromptPackTools.listTool, const {}),
      AssistantRisk.readOnly,
    );
  });

  test('reading a preset renders the final text with its values', () async {
    final result = await run(AssistantPromptPackTools.readTool, {
      'preset_id': 'nai',
    });
    expect(result['pack']['id'], 'builtin.image.novelai');
    final rendered = result['rendered'] as Map;
    expect('${rendered['inline']}', contains('832'));
    expect('${rendered['inline']}', isNot(contains('{default_width}')));
  });

  test('editing a shared section and restoring it both undo', () async {
    final before = library
        .require('builtin.tts.fish_s2')
        .section('fish_s2.rules')!;
    final edited = await run(AssistantPromptPackTools.editTool, {
      'pack_id': 'builtin.tts.fish_s2',
      'section_id': 'fish_s2.rules',
      'text': '每句最多一个标签。',
    });
    expect(edited['ok'], isTrue);
    expect(
      library.require('builtin.tts.fish_s2').section('fish_s2.rules')!.text,
      '每句最多一个标签。',
    );
    await run(AssistantPromptPackTools.editTool, {
      'pack_id': 'builtin.tts.fish_s2',
      'section_id': 'fish_s2.nsfw_example',
      'enabled': false,
    });
    expect(
      library.isModified('builtin.tts.fish_s2', 'fish_s2.nsfw_example'),
      isTrue,
    );
    await undoAll();
    expect(
      library.require('builtin.tts.fish_s2').section('fish_s2.rules')!.text,
      before.text,
    );
    expect(library.overrides, isEmpty);
  });

  test('a preset own section is added, edited and undone', () async {
    final added = await run(AssistantPromptPackTools.addTool, {
      'preset_id': 'nai',
      'scope': 'inline',
      'title': '角色专属',
      'text': '绿色眼睛，白发。',
    });
    final id = added['section_id'] as String;
    expect(presets['nai']!.binding.ownSections.single.text, '绿色眼睛，白发。');
    await run(AssistantPromptPackTools.editTool, {
      'preset_id': 'nai',
      'section_id': id,
      'text': '绿色眼睛。',
    });
    expect(presets['nai']!.binding.ownSections.single.text, '绿色眼睛。');
    final read = await run(AssistantPromptPackTools.readTool, {
      'preset_id': 'nai',
    });
    expect('${(read['rendered'] as Map)['inline']}', contains('绿色眼睛。'));
    await undoAll();
    expect(presets['nai']!.binding.ownSections, isEmpty);
    expect(library.overrides, isEmpty);
  });

  test('fork with a preset binds the copy; undo removes both', () async {
    final result = await run(AssistantPromptPackTools.forkTool, {
      'pack_id': 'builtin.tts.fish_s2',
      'bind_preset_id': 'fish',
    });
    final id = result['pack_id'] as String;
    expect(
      library.byId(id)!.name,
      '纳西妲音色 · ${library.require('builtin.tts.fish_s2').name}',
    );
    expect(library.byId(id)!.match, isEmpty);
    expect(presets['fish']!.binding.packId, id);
    // One entry: the copy and the binding never come apart.
    expect(await journal.recent(), hasLength(1));
    await undoAll();
    expect(presets['fish']!.binding.packId, isNull);
    expect(library.byId(id), isNull);
  });

  test('undoing a copy another preset was bound to later is refused', () async {
    final result = await run(AssistantPromptPackTools.forkTool, {
      'pack_id': 'builtin.tts.fish_s2',
    });
    final id = result['pack_id'] as String;
    await save('tts', 'fish', presets['fish']!.binding.withPack(id));
    final entry = (await journal.recent()).single;
    await expectLater(journal.undo(entry.id), throwsStateError);
    expect(library.byId(id), isNotNull);
  });

  test('snapshots compare by structure, not key order', () {
    expect(
      samePromptState(
        {
          'a': 1,
          'b': {'x': 1, 'y': 2},
        },
        {
          'b': {'y': 2, 'x': 1},
          'a': 1,
        },
      ),
      isTrue,
    );
    expect(samePromptState({'a': 1}, {'a': 2}), isFalse);
  });

  test('binding checks the plugin and undoes', () async {
    final wrong = await run(AssistantPromptPackTools.bindTool, {
      'preset_id': 'fish',
      'pack_id': 'builtin.image.natural',
    });
    expect(wrong['error'], 'invalid');
    await run(AssistantPromptPackTools.bindTool, {
      'preset_id': 'fish',
      'pack_id': 'builtin.tts.minimax',
    });
    expect(presets['fish']!.binding.packId, 'builtin.tts.minimax');
    await undoAll();
    expect(presets['fish']!.binding.packId, isNull);
  });

  test('undo leaves a later edit made elsewhere alone', () async {
    await run(AssistantPromptPackTools.editTool, {
      'pack_id': 'builtin.tts.fish_s2',
      'section_id': 'fish_s2.rules',
      'text': '助手改的。',
    });
    library = library.editSection(
      'builtin.tts.fish_s2',
      'fish_s2.rules',
      text: '用户后来改的。',
    );
    final entry = (await journal.recent()).single;
    await expectLater(journal.undo(entry.id), throwsA(anything));
    expect(
      library.require('builtin.tts.fish_s2').section('fish_s2.rules')!.text,
      '用户后来改的。',
    );
  });

  test('built-in sections cannot be deleted, only switched off', () async {
    final result = await run(AssistantPromptPackTools.editTool, {
      'pack_id': 'builtin.tts.fish_s2',
      'section_id': 'fish_s2.rules',
      'delete': true,
    });
    expect(result['error'], 'invalid');
    expect(
      tools.riskOf(AssistantPromptPackTools.editTool, const {}),
      AssistantRisk.review,
    );
  });

  test(
    'a refused composite undo leaves both pack and binding as they were',
    () async {
      final result = await run(AssistantPromptPackTools.forkTool, {
        'pack_id': 'builtin.tts.fish_s2',
        'bind_preset_id': 'fish',
      });
      final id = result['pack_id'] as String;
      // Another preset binds the copy too: undoing must refuse before
      // touching the first preset.
      presets['other'] = AssistantPromptPreset(
        pluginId: 'tts',
        id: 'other',
        name: '另一个音色',
        binding: PresetPromptBinding(packId: id),
        format: 'fish_audio',
        model: 's2-pro',
      );
      final entry = (await journal.recent()).single;
      await expectLater(journal.undo(entry.id), throwsStateError);
      expect(presets['fish']!.binding.packId, id);
      expect(library.byId(id), isNotNull);
    },
  );

  test(
    'when the pack changed after the check, the unbinding is put back',
    () async {
      final result = await run(AssistantPromptPackTools.forkTool, {
        'pack_id': 'builtin.tts.fish_s2',
        'bind_preset_id': 'fish',
      });
      final id = result['pack_id'] as String;
      final entry = (await journal.recent()).single;
      // The preset step writes first; edit the pack right after it, before
      // the pack step compares.
      final original = presets['fish']!;
      var edited = false;
      presets['fish'] = original;
      final packApplier = AssistantPromptPackApplier(
        library: () async => library,
        change: change,
      );
      final presetApplier = AssistantPresetPromptsApplier(
        presets: listPresets,
        save: (plugin, presetId, binding, {expected}) async {
          final wrote = await save(
            plugin,
            presetId,
            binding,
            expected: expected,
          );
          if (wrote && !edited) {
            edited = true;
            library = library.editSection(id, 'fish_s2.rules', text: '用户刚改的');
          }
          return wrote;
        },
      );
      final applier = AssistantPromptPackForkApplier(
        packs: packApplier,
        presets: presetApplier,
      );
      final ok = await applier.applyIfCurrent(
        entry.change.after,
        entry.change.before,
      );
      expect(ok, isFalse);
      expect(presets['fish']!.binding.packId, id);
      expect(library.byId(id)!.section('fish_s2.rules')!.text, '用户刚改的');
    },
  );
}
