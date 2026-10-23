import 'dart:convert';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart'
    show ReversibleChange, ToolEffect;

import '../../agent_plugins/file_change_journal.dart';
import '../../plugins/domain/handlers/ai_tool.dart';
import '../../plugins/prompts/prompt_pack.dart';
import '../../plugins/prompts/prompt_pack_store.dart'
    show newPromptPackId, newPromptSectionId;
import 'assistant_review.dart';
import 'assistant_tool_group.dart';

const assistantPromptPackChangeKind = 'assistant.prompt_pack';
const assistantPresetPromptsChangeKind = 'assistant.preset_prompts';

/// A pack copy and the preset bound to it, undone as one change.
const assistantPromptPackForkChangeKind = 'assistant.prompt_pack_fork';

/// A voice or drawing preset as the prompt-pack tools see it: its binding
/// and what 「自动」 matches on.
class AssistantPromptPreset {
  const AssistantPromptPreset({
    required this.pluginId,
    required this.id,
    required this.name,
    required this.binding,
    required this.format,
    required this.model,
    this.variables = const {},
  });

  final String pluginId;
  final String id;
  final String name;
  final PresetPromptBinding binding;
  final String format;
  final String model;
  final Map<String, Object?> variables;
}

/// The assistant's hands on plugin prompt packs (ADR0092): reading what a
/// preset sends, editing shared pack sections or a preset's own ones,
/// copying packs and binding them. Every write is undoable.
class AssistantPromptPackTools extends AssistantToolGroup {
  AssistantPromptPackTools({
    required this.library,
    required this.change,
    required this.presets,
    required this.journal,
    this.onChanged,
  });

  final Future<PromptPackLibrary> Function() library;

  /// Writes the library under the store's lock.
  final Future<void> Function(PromptPackLibrary Function(PromptPackLibrary))
  change;
  final Future<List<AssistantPromptPreset>> Function() presets;
  final FileChangeJournal journal;
  final void Function()? onChanged;

  static const listTool = 'aicove_list_prompt_packs';
  static const readTool = 'aicove_read_prompt_pack';
  static const editTool = 'aicove_edit_prompt_section';
  static const addTool = 'aicove_add_prompt_section';
  static const forkTool = 'aicove_fork_prompt_pack';
  static const bindTool = 'aicove_bind_prompt_pack';

  static const _plugin = {
    'type': 'string',
    'enum': ['tts', 'image'],
    'description': 'tts＝语音（音色预设），image＝绘图（绘图预设）',
  };
  static const _packId = {
    'type': 'string',
    'description': 'aicove_list_prompt_packs 给出的提示词包 id',
  };
  static const _presetId = {
    'type': 'string',
    'description': '音色预设或绘图预设的 id（aicove_list_prompt_packs 里的 presets）',
  };

  @override
  List<AITool> tools() => [
    assistantTool(
      listTool,
      '列出语音或绘图的提示词包（按模型家族分的出厂包＋用户自建包，含匹配规则和被哪些预设绑定），'
      '以及每个预设当前用的包（「自动」时显示按模型匹配到的包）。',
      {'plugin': _plugin},
      ['plugin'],
      ToolEffect.readPrivate,
      _list,
    ),
    assistantTool(
      readTool,
      '读一个提示词包的全部节（id、发到哪里、标题、开关、正文、是否改过）；'
      '给 preset_id 时读这个预设实际用的包、它的专属节，以及按预设参数渲染后发给模型的最终全文。',
      {'pack_id': _packId, 'preset_id': _presetId},
      const [],
      ToolEffect.readPrivate,
      _read,
    ),
    assistantTool(
      editTool,
      '改一节提示词。给 pack_id 改共享包里的节（会影响所有用这个包的预设）；给 preset_id 改这个预设的专属节。'
      '只传要改的：text、title、enabled；restore=true 把出厂节恢复默认；delete=true 删除这一节'
      '（出厂节不能删，只能关掉）。正文里 {变量} 见 aicove_read_prompt_pack 的 variables，其它花括号原样发送。',
      {
        'pack_id': _packId,
        'preset_id': _presetId,
        'section_id': {'type': 'string'},
        'text': {'type': 'string'},
        'title': {'type': 'string'},
        'enabled': {'type': 'boolean'},
        'restore': {'type': 'boolean'},
        'delete': {'type': 'boolean'},
      },
      ['section_id'],
      ToolEffect.write,
      _edit,
    ),
    assistantTool(
      addTool,
      '加一节提示词：给 preset_id 加到这个预设的专属节（只影响它，最常用）；给 pack_id 加到共享包。'
      'scope 是发到哪里（语音：chat 聊天开启、chat.off 频率为 0 时、call 语音通话；'
      '绘图：inline 聊天里的 <image> 说明、tool.description／tool.prompt／tool.params 是调用模式 draw_image 工具的说明）。',
      {
        'pack_id': _packId,
        'preset_id': _presetId,
        'scope': {'type': 'string'},
        'title': {'type': 'string'},
        'text': {'type': 'string'},
      },
      ['scope', 'title', 'text'],
      ToolEffect.write,
      _add,
    ),
    assistantTool(
      forkTool,
      '把一个提示词包另存为新的自建包（复制当前内容；出厂包的副本不参与自动匹配）。'
      '给 bind_preset_id 时同时绑到这个预设——只想改一个预设又不想影响别人时用它。',
      {
        'pack_id': _packId,
        'name': {'type': 'string', 'description': '新包名字，可省略'},
        'bind_preset_id': _presetId,
      },
      ['pack_id'],
      ToolEffect.write,
      _fork,
    ),
    assistantTool(
      bindTool,
      '让一个预设改用某个提示词包；pack_id 传空字符串表示「自动」（按渠道格式和模型匹配）。'
      '只换包，不动预设的专属节。',
      {'preset_id': _presetId, 'pack_id': _packId},
      ['preset_id', 'pack_id'],
      ToolEffect.write,
      _bind,
    ),
  ];

  @override
  AssistantRisk riskOf(String toolName, Map<String, dynamic> args) =>
      switch (toolName) {
        listTool || readTool => AssistantRisk.readOnly,
        _ => AssistantRisk.review,
      };

  @override
  ApprovalPrompt describe(String toolName, Map<String, dynamic> args) {
    final target = args['preset_id'] != null
        ? '预设 ${args['preset_id']} 的专属节'
        : '提示词包 ${args['pack_id'] ?? ''}';
    return switch (toolName) {
      editTool => ApprovalPrompt(
        title: '修改$target「${args['section_id'] ?? ''}」',
        detail: args['delete'] == true
            ? '删除这一节'
            : args['restore'] == true
            ? '恢复出厂默认'
            : '${args['text'] ?? (args['enabled'] == false ? '关闭这一节' : jsonEncode(args))}',
      ),
      addTool => ApprovalPrompt(
        title: '给$target加一节「${args['title'] ?? ''}」',
        detail: '${args['text'] ?? ''}',
      ),
      forkTool => ApprovalPrompt(
        title: '另存提示词包 ${args['pack_id'] ?? ''}',
        detail: args['bind_preset_id'] == null
            ? '复制成新的自建包'
            : '复制成新包并绑到预设 ${args['bind_preset_id']}',
      ),
      bindTool => ApprovalPrompt(
        title: '换预设 ${args['preset_id'] ?? ''} 的提示词包',
        detail: '${args['pack_id'] ?? ''}'.isEmpty
            ? '改为自动匹配'
            : '改用 ${args['pack_id']}',
      ),
      _ => ApprovalPrompt(title: '读取提示词包', detail: jsonEncode(args)),
    };
  }

  Future<Map<String, Object?>> _guard(
    Future<Map<String, Object?>> Function() body,
  ) async {
    try {
      return await body();
    } on FormatException catch (error) {
      return assistantToolError(error.message);
    } on StateError catch (error) {
      return assistantToolError(error.message);
    } on PromptPackMissingException catch (error) {
      return assistantToolError('$error');
    }
  }

  String _pluginOf(Map<String, dynamic> args) {
    final plugin = '${args['plugin'] ?? ''}';
    if (plugin != 'tts' && plugin != 'image') {
      throw const FormatException('plugin 只能是 tts 或 image');
    }
    return plugin;
  }

  Future<AssistantPromptPreset> _preset(Object? id) async =>
      (await presets()).where((p) => p.id == '$id').firstOrNull ??
      (throw StateError('没有 id 为「$id」的音色或绘图预设'));

  Map<String, Object?> _section(
    PromptPackLibrary lib,
    String? packId,
    PromptSection s,
  ) => {
    'id': s.id,
    'scope': s.scope,
    'title': s.title,
    'enabled': s.enabled,
    'text': s.text,
    if (packId != null && lib.isModified(packId, s.id)) 'modified': true,
    if (packId != null &&
        lib.builtin(packId) != null &&
        lib.isUserSection(packId, s.id))
      'user_added': true,
  };

  Future<Map<String, Object?>> _list(Map<String, dynamic> args) => _guard(
    () async {
      final plugin = _pluginOf(args);
      final lib = await library();
      final all = [
        for (final p in await presets())
          if (p.pluginId == plugin) p,
      ];
      return {
        'packs': [
          for (final pack in lib.packsFor(plugin))
            {
              'id': pack.id,
              'name': pack.name,
              'built_in': pack.builtIn,
              if (pack.fallback) 'fallback': true,
              if (pack.description.isNotEmpty) 'description': pack.description,
              'match': [
                for (final rule in pack.match)
                  {'formats': rule.formats, 'models': rule.models},
              ],
              'sections': pack.sections.length,
              'bound_presets': [
                for (final p in all)
                  if (p.binding.packId == pack.id) p.id,
              ],
            },
        ],
        'presets': [for (final p in all) _presetSummary(lib, p)],
        'scopes': PromptScopes.of(plugin),
      };
    },
  );

  Map<String, Object?> _presetSummary(
    PromptPackLibrary lib,
    AssistantPromptPreset p,
  ) {
    String? using;
    String? error;
    try {
      using = lib
          .resolve(p.pluginId, p.binding, format: p.format, model: p.model)
          .pack
          .id;
    } on PromptPackMissingException catch (e) {
      error = '$e';
    }
    return {
      'id': p.id,
      'name': p.name,
      'pack': p.binding.packId ?? 'auto',
      if (using != null) 'using': using,
      if (error != null) 'error': error,
      'format': p.format,
      'model': p.model,
      'own_sections': p.binding.ownSections.length,
    };
  }

  Future<Map<String, Object?>> _read(Map<String, dynamic> args) => _guard(
    () async {
      final lib = await library();
      final presetId = args['preset_id'];
      if (presetId != null && '$presetId'.isNotEmpty) {
        final preset = await _preset(presetId);
        final resolved = lib.resolve(
          preset.pluginId,
          preset.binding,
          format: preset.format,
          model: preset.model,
        );
        return {
          'preset': _presetSummary(lib, preset),
          'pack': {
            'id': resolved.pack.id,
            'name': resolved.pack.name,
            'automatic': resolved.automatic,
            'sections': [
              for (final s in resolved.pack.sections)
                _section(lib, resolved.pack.id, s),
            ],
          },
          'own_sections': [
            for (final s in preset.binding.ownSections) _section(lib, null, s),
          ],
          'variables': PromptVariables.byPlugin[preset.pluginId] ?? const {},
          'rendered': {
            for (final scope in PromptScopes.of(preset.pluginId).keys)
              scope: resolved.render(scope, preset.variables),
          },
        };
      }
      final pack = lib.require('${args['pack_id'] ?? ''}');
      return {
        'id': pack.id,
        'name': pack.name,
        'plugin': pack.pluginId,
        'built_in': pack.builtIn,
        'sections': [for (final s in pack.sections) _section(lib, pack.id, s)],
        'variables': PromptVariables.byPlugin[pack.pluginId] ?? const {},
      };
    },
  );

  Future<Map<String, Object?>> _edit(Map<String, dynamic> args) => _guard(
    () async {
      final sectionId = '${args['section_id'] ?? ''}';
      final text = args['text'] is String ? args['text'] as String : null;
      final title = args['title'] is String ? args['title'] as String : null;
      final enabled = args['enabled'] is bool ? args['enabled'] as bool : null;
      final restore = args['restore'] == true;
      final delete = args['delete'] == true;
      if (!restore &&
          !delete &&
          text == null &&
          title == null &&
          enabled == null) {
        throw const FormatException('没有要改的内容');
      }
      if (args['preset_id'] != null && '${args['preset_id']}'.isNotEmpty) {
        final preset = await _preset(args['preset_id']);
        final section = preset.binding.ownSections
            .where((s) => s.id == sectionId)
            .firstOrNull;
        if (section == null) {
          throw StateError(
            '预设「${preset.name}」没有专属节「$sectionId」；共享包里的节请用 pack_id',
          );
        }
        if (restore) throw const FormatException('专属节没有出厂默认');
        final next = delete
            ? preset.binding.removeSection(sectionId)
            : preset.binding.upsertSection(
                section.copyWith(text: text, title: title, enabled: enabled),
              );
        return _commitBinding(
          editTool,
          preset,
          next,
          '${delete ? '删除' : '修改'}了预设「${preset.name}」的专属节「${section.title}」',
        );
      }
      final packId = '${args['pack_id'] ?? ''}';
      final lib = await library();
      final pack = lib.require(packId);
      final section =
          pack.section(sectionId) ??
          (throw StateError('提示词包「${pack.name}」没有节「$sectionId」'));
      return _commitPack(
        editTool,
        packId,
        (l) {
          if (delete) return l.removeSection(packId, sectionId);
          if (restore) return l.restoreSection(packId, sectionId);
          return l.editSection(
            packId,
            sectionId,
            text: text,
            title: title,
            enabled: enabled,
          );
        },
        '${delete
            ? '删除'
            : restore
            ? '恢复'
            : '修改'}了提示词包「${pack.name}」的「${section.title}」',
      );
    },
  );

  void _checkScope(String pluginId, String scope) {
    if (!PromptScopes.of(pluginId).containsKey(scope)) {
      throw FormatException(
        'scope 只能是 ${PromptScopes.of(pluginId).keys.join('、')}',
      );
    }
  }

  Future<Map<String, Object?>> _add(Map<String, dynamic> args) =>
      _guard(() async {
        final scope = '${args['scope'] ?? ''}';
        final title = '${args['title'] ?? ''}'.trim();
        final text = '${args['text'] ?? ''}';
        if (text.trim().isEmpty) throw const FormatException('正文不能为空');
        final section = PromptSection(
          id: newPromptSectionId(),
          scope: scope,
          title: title.isEmpty ? '补充要求' : title,
          text: text,
        );
        if (args['preset_id'] != null && '${args['preset_id']}'.isNotEmpty) {
          final preset = await _preset(args['preset_id']);
          _checkScope(preset.pluginId, scope);
          final result = await _commitBinding(
            addTool,
            preset,
            preset.binding.upsertSection(section),
            '给预设「${preset.name}」加了专属节「${section.title}」',
          );
          return {...result, 'section_id': section.id};
        }
        final packId = '${args['pack_id'] ?? ''}';
        final pack = (await library()).require(packId);
        _checkScope(pack.pluginId, scope);
        final result = await _commitPack(
          addTool,
          packId,
          (l) => l.addSection(packId, section),
          '给提示词包「${pack.name}」加了「${section.title}」',
        );
        return {...result, 'section_id': section.id};
      });

  Future<Map<String, Object?>> _fork(Map<String, dynamic> args) =>
      _guard(() async {
        final source = (await library()).require('${args['pack_id'] ?? ''}');
        final bindId = '${args['bind_preset_id'] ?? ''}';
        final preset = bindId.isEmpty ? null : await _preset(bindId);
        if (preset != null && preset.pluginId != source.pluginId) {
          throw StateError('预设「${preset.name}」和这个包不是同一个插件');
        }
        final name = '${args['name'] ?? ''}'.trim();
        final newId = newPromptPackId();
        final lib = await library();
        final forked = lib.fork(
          source.id,
          newId: newId,
          name: name.isNotEmpty
              ? name
              : preset == null
              ? null
              : '${preset.name} · ${source.name}',
        );
        final description = '把「${source.name}」另存为新包';
        if (preset == null) {
          final result = await _commitPack(
            forkTool,
            newId,
            (_) => forked,
            description,
          );
          return {...result, 'pack_id': newId};
        }
        await journal.commit(
          forkTool,
          ReversibleChange(
            kind: assistantPromptPackForkChangeKind,
            description: '$description，并让预设「${preset.name}」改用它',
            before: {
              'pack': lib.packSnapshot(newId),
              'preset': presetPromptsSnapshot(
                preset.pluginId,
                preset.id,
                preset.binding,
              ),
            },
            after: {
              'pack': forked.packSnapshot(newId),
              'preset': presetPromptsSnapshot(
                preset.pluginId,
                preset.id,
                preset.binding.withPack(newId),
              ),
            },
          ),
        );
        onChanged?.call();
        return {
          'ok': true,
          'pack_id': newId,
          'change': '$description，并让预设「${preset.name}」改用它',
          'undo': '用户可以在聊天页撤销这次修改（新包和绑定一起撤销）',
        };
      });

  Future<Map<String, Object?>> _bind(Map<String, dynamic> args) =>
      _guard(() async {
        final preset = await _preset(args['preset_id']);
        final packId = '${args['pack_id'] ?? ''}'.trim();
        String label = '自动';
        if (packId.isNotEmpty) {
          final pack = (await library()).require(packId);
          if (pack.pluginId != preset.pluginId) {
            throw StateError(
              '「${pack.name}」不是${preset.pluginId == 'tts' ? '语音' : '绘图'}的提示词包',
            );
          }
          label = '「${pack.name}」';
        }
        return _commitBinding(
          bindTool,
          preset,
          preset.binding.withPack(packId.isEmpty ? null : packId),
          '预设「${preset.name}」的提示词包改为$label',
        );
      });

  Future<Map<String, Object?>> _commitPack(
    String toolName,
    String packId,
    PromptPackLibrary Function(PromptPackLibrary) edit,
    String description,
  ) async {
    final lib = await library();
    final before = lib.packSnapshot(packId);
    final after = edit(lib).packSnapshot(packId);
    if (samePromptState(before, after)) {
      return {'ok': true, 'change': '没有变化'};
    }
    await journal.commit(
      toolName,
      ReversibleChange(
        kind: assistantPromptPackChangeKind,
        description: description,
        before: before,
        after: after,
      ),
    );
    onChanged?.call();
    return {'ok': true, 'change': description, 'undo': '用户可以在聊天页撤销这次修改'};
  }

  Future<Map<String, Object?>> _commitBinding(
    String toolName,
    AssistantPromptPreset preset,
    PresetPromptBinding next,
    String description,
  ) async {
    final before = presetPromptsSnapshot(
      preset.pluginId,
      preset.id,
      preset.binding,
    );
    final after = presetPromptsSnapshot(preset.pluginId, preset.id, next);
    if (samePromptState(before, after)) {
      return {'ok': true, 'change': '没有变化'};
    }
    await journal.commit(
      toolName,
      ReversibleChange(
        kind: assistantPresetPromptsChangeKind,
        description: description,
        before: before,
        after: after,
      ),
    );
    onChanged?.call();
    return {'ok': true, 'change': description, 'undo': '用户可以在聊天页撤销这次修改'};
  }
}

Map<String, Object?> presetPromptsSnapshot(
  String pluginId,
  String presetId,
  PresetPromptBinding binding,
) => {'plugin': pluginId, 'preset_id': presetId, 'prompts': binding.toJson()};

/// Structural equality of two snapshots, whatever the key order.
bool samePromptState(Object? a, Object? b) =>
    jsonEncode(_canonical(a)) == jsonEncode(_canonical(b));

Object? _canonical(Object? value) => switch (value) {
  final Map map => {
    for (final key in (map.keys.map((k) => '$k').toList()..sort()))
      key: _canonical(map[key]),
  },
  final List list => [for (final item in list) _canonical(item)],
  _ => value,
};

/// Writes a pack snapshot back, only while the expected one is in effect.
/// Removing a custom pack is refused while a preset still binds it.
class AssistantPromptPackApplier extends CheckedChangeApplier {
  AssistantPromptPackApplier({
    required this.library,
    required this.change,
    this.boundBy,
  });

  final Future<PromptPackLibrary> Function() library;
  final Future<void> Function(PromptPackLibrary Function(PromptPackLibrary))
  change;

  /// Presets explicitly bound to a pack.
  final Future<List<({String id, String name})>> Function(String packId)?
  boundBy;

  /// Throws while [state] would remove a pack that a preset (other than
  /// [except]) still binds.
  Future<void> checkRemoval(
    Map<String, Object?> state, {
    String? except,
  }) async {
    final id = '${state['pack_id']}';
    if (!state.containsKey('custom') || state['custom'] != null) return;
    if ((await library()).byId(id) == null) return;
    final names = [
      for (final preset
          in await boundBy?.call(id) ?? const <({String id, String name})>[])
        if (preset.id != except) preset.name,
    ];
    if (names.isNotEmpty) {
      throw StateError('预设「${names.join('、')}」还在用这个包，先给它们换包再撤销');
    }
  }

  @override
  Future<bool> isCurrent(Map<String, Object?> state) async => samePromptState(
    (await library()).packSnapshot('${state['pack_id']}'),
    state,
  );

  @override
  Future<void> apply(Map<String, Object?> state) async {
    await checkRemoval(state);
    await change((l) => l.restorePack(state));
  }

  /// Compares and writes in one turn of the store's queue.
  @override
  Future<bool> applyIfCurrent(
    Map<String, Object?> expected,
    Map<String, Object?> state,
  ) async {
    await checkRemoval(state);
    var current = false;
    await change((l) {
      current = samePromptState(
        l.packSnapshot('${expected['pack_id']}'),
        expected,
      );
      return current ? l.restorePack(state) : l;
    });
    return current;
  }
}

/// Writes a preset's prompt binding back, comparing in the preset store's
/// write queue.
class AssistantPresetPromptsApplier extends CheckedChangeApplier {
  AssistantPresetPromptsApplier({required this.presets, required this.save});

  final Future<List<AssistantPromptPreset>> Function() presets;

  /// Writes [binding]; with `expected`, only while the stored binding still
  /// equals it. Returns whether it wrote.
  final Future<bool> Function(
    String pluginId,
    String presetId,
    PresetPromptBinding binding, {
    PresetPromptBinding? expected,
  })
  save;

  PresetPromptBinding _binding(Map<String, Object?> state) =>
      PresetPromptBinding.fromJson(state['prompts']);

  @override
  Future<bool> isCurrent(Map<String, Object?> state) async {
    final preset = (await presets())
        .where(
          (p) => p.pluginId == state['plugin'] && p.id == state['preset_id'],
        )
        .firstOrNull;
    return preset != null &&
        samePromptState(
          presetPromptsSnapshot(preset.pluginId, preset.id, preset.binding),
          state,
        );
  }

  @override
  Future<void> apply(Map<String, Object?> state) =>
      save('${state['plugin']}', '${state['preset_id']}', _binding(state));

  @override
  Future<bool> applyIfCurrent(
    Map<String, Object?> expected,
    Map<String, Object?> state,
  ) => save(
    '${state['plugin']}',
    '${state['preset_id']}',
    _binding(state),
    expected: _binding(expected),
  );
}

/// A pack copy plus the preset bound to it. Creating writes the pack
/// first; undoing unbinds the preset first, so no binding is left pointing
/// at a pack that is gone. Each step compares in its own store's queue;
/// when the second step is refused, the first is put back, so a refused
/// undo leaves both as they were.
class AssistantPromptPackForkApplier extends CheckedChangeApplier {
  AssistantPromptPackForkApplier({required this.packs, required this.presets});

  final AssistantPromptPackApplier packs;
  final AssistantPresetPromptsApplier presets;

  Map<String, Object?> _part(Map<String, Object?> state, String key) =>
      Map<String, Object?>.from(state[key] as Map? ?? const {});

  @override
  Future<bool> isCurrent(Map<String, Object?> state) async =>
      await packs.isCurrent(_part(state, 'pack')) &&
      await presets.isCurrent(_part(state, 'preset'));

  @override
  Future<void> apply(Map<String, Object?> state) =>
      _applyIfCurrent(null, state).then((_) {});

  @override
  Future<bool> applyIfCurrent(
    Map<String, Object?> expected,
    Map<String, Object?> state,
  ) => _applyIfCurrent(expected, state);

  Future<bool> _applyIfCurrent(
    Map<String, Object?>? expected,
    Map<String, Object?> state,
  ) async {
    final pack = _part(state, 'pack');
    final preset = _part(state, 'preset');
    final expectedPack = expected == null ? null : _part(expected, 'pack');
    final expectedPreset = expected == null ? null : _part(expected, 'preset');
    // Everything that can refuse is checked before anything is written.
    if (expectedPack != null && !await packs.isCurrent(expectedPack)) {
      return false;
    }
    await packs.checkRemoval(pack, except: '${preset['preset_id']}');

    Future<bool> writePack() => expectedPack == null
        ? packs.apply(pack).then((_) => true)
        : packs.applyIfCurrent(expectedPack, pack);
    Future<bool> writePreset() => expectedPreset == null
        ? presets.apply(preset).then((_) => true)
        : presets.applyIfCurrent(expectedPreset, preset);
    final removing = pack['custom'] == null;
    final first = removing ? writePreset : writePack;
    final second = removing ? writePack : writePreset;
    if (!await first()) return false;
    try {
      if (await second()) return true;
    } catch (_) {
      await _undoFirst(removing, expectedPack, expectedPreset, pack, preset);
      rethrow;
    }
    await _undoFirst(removing, expectedPack, expectedPreset, pack, preset);
    return false;
  }

  Future<void> _undoFirst(
    bool removing,
    Map<String, Object?>? expectedPack,
    Map<String, Object?>? expectedPreset,
    Map<String, Object?> pack,
    Map<String, Object?> preset,
  ) async {
    if (removing) {
      if (expectedPreset != null) {
        await presets.applyIfCurrent(preset, expectedPreset);
      }
    } else if (expectedPack != null) {
      await packs.applyIfCurrent(pack, expectedPack);
    }
  }
}
