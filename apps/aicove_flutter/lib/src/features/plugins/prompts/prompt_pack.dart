import '../../../core/prompts/prompt_template_renderer.dart';

/// Where a section's text goes (ADR0092). Each plugin declares its own.
abstract final class PromptScopes {
  static const ttsChat = 'chat';
  static const ttsChatOff = 'chat.off';
  static const ttsCall = 'call';
  static const imageInline = 'inline';
  static const imageToolDescription = 'tool.description';
  static const imageToolPrompt = 'tool.prompt';
  static const imageToolParams = 'tool.params';

  /// Scopes saved sections used before the image tool's fields were merged;
  /// they read as the scope they now belong to, so nothing is rewritten.
  static const _legacyAliases = {
    'tool.negative_prompt': imageToolPrompt,
    'tool.width': imageToolParams,
    'tool.height': imageToolParams,
    'tool.count': imageToolParams,
    'tool.steps': imageToolParams,
    'tool.guidance_scale': imageToolParams,
  };

  static String canonical(String scope) => _legacyAliases[scope] ?? scope;

  /// Scopes of each plugin with the label the editor shows, in display order.
  static const byPlugin = <String, Map<String, String>>{
    'tts': {ttsChat: '聊天里的 <tts> 说明', ttsChatOff: '语音频率为 0 时', ttsCall: '语音通话'},
    'image': {
      imageInline: '快速模式 <image> 说明',
      imageToolDescription: '调用模式 · 工具说明',
      imageToolPrompt: '调用模式 · 提示词参数（含负面）',
      imageToolParams: '调用模式 · 参数（宽、高、张数、步数、强度）',
    },
  };

  static Map<String, String> of(String pluginId) =>
      byPlugin[pluginId] ?? const {};
}

/// Values a section may reference as `{name}`; other braces stay literal
/// (NovelAI weights use `{tag}`).
abstract final class PromptVariables {
  static const byPlugin = <String, Map<String, String>>{
    'tts': {
      'max_chars_per_chunk': '每段最多字数（音色预设）',
      'voice_frequency': '语音频率（音色预设）',
    },
    'image': {
      'default_width': '默认宽度（绘图预设）',
      'default_height': '默认高度（绘图预设）',
      'default_count': '默认张数（绘图预设）',
      'default_steps': '默认步数（绘图预设）',
      'default_guidance_scale': '默认提示词强度（绘图预设）',
    },
  };
}

class PromptSection {
  const PromptSection({
    required this.id,
    required this.scope,
    required this.title,
    required this.text,
    this.enabled = true,
  });

  final String id;
  final String scope;
  final String title;
  final String text;
  final bool enabled;

  PromptSection copyWith({String? title, String? text, bool? enabled}) =>
      PromptSection(
        id: id,
        scope: scope,
        title: title ?? this.title,
        text: text ?? this.text,
        enabled: enabled ?? this.enabled,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'scope': scope,
    'title': title,
    'text': text,
    'enabled': enabled,
  };

  factory PromptSection.fromJson(Map<String, dynamic> json) => PromptSection(
    id: json['id'] as String,
    scope: PromptScopes.canonical(json['scope'] as String),
    title: json['title'] as String? ?? '',
    text: json['text'] as String? ?? '',
    enabled: json['enabled'] as bool? ?? true,
  );
}

/// One model family rule: every listed part must match. Model patterns are
/// case-insensitive substrings, or regular expressions written as `/…/`.
class PromptMatchRule {
  const PromptMatchRule({this.formats = const [], this.models = const []});

  final List<String> formats;
  final List<String> models;

  bool matches(String format, String model) {
    final f = format.trim().toLowerCase();
    final m = model.trim().toLowerCase();
    if (formats.isNotEmpty && !formats.any((x) => x.toLowerCase() == f)) {
      return false;
    }
    return models.isEmpty || models.any((p) => modelMatches(p, m));
  }

  static bool modelMatches(String pattern, String model) {
    final p = pattern.trim();
    if (p.length > 2 && p.startsWith('/') && p.endsWith('/')) {
      try {
        return RegExp(
          p.substring(1, p.length - 1),
          caseSensitive: false,
        ).hasMatch(model);
      } on FormatException {
        return false;
      }
    }
    return p.isNotEmpty && model.toLowerCase().contains(p.toLowerCase());
  }

  /// Null when [pattern] is a `/…/` expression that does not compile.
  static String? patternError(String pattern) {
    final p = pattern.trim();
    if (p.length > 2 && p.startsWith('/') && p.endsWith('/')) {
      try {
        RegExp(p.substring(1, p.length - 1));
      } on FormatException catch (e) {
        return e.message;
      }
    }
    return null;
  }

  Map<String, dynamic> toJson() => {'formats': formats, 'models': models};

  factory PromptMatchRule.fromJson(Map<String, dynamic> json) =>
      PromptMatchRule(
        formats: [for (final f in json['formats'] as List? ?? []) '$f'],
        models: [for (final m in json['models'] as List? ?? []) '$m'],
      );
}

/// Everything a plugin tells the model, as ordered sections (ADR0092).
class PromptPack {
  const PromptPack({
    required this.id,
    required this.pluginId,
    required this.name,
    required this.sections,
    this.description = '',
    this.match = const [],
    this.fallback = false,
  });

  static const builtinPrefix = 'builtin.';

  final String id;
  final String pluginId;
  final String name;
  final String description;
  final List<PromptMatchRule> match;

  /// The plugin's built-in pack used when no rule matches.
  final bool fallback;
  final List<PromptSection> sections;

  bool get builtIn => id.startsWith(builtinPrefix);

  bool matches(String format, String model) =>
      match.any((rule) => rule.matches(format, model));

  PromptSection? section(String id) =>
      sections.where((s) => s.id == id).firstOrNull;

  PromptPack copyWith({
    String? id,
    String? name,
    String? description,
    List<PromptMatchRule>? match,
    List<PromptSection>? sections,
  }) => PromptPack(
    id: id ?? this.id,
    pluginId: pluginId,
    name: name ?? this.name,
    description: description ?? this.description,
    match: match ?? this.match,
    fallback: id == null ? fallback : false,
    sections: sections ?? this.sections,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'pluginId': pluginId,
    'name': name,
    'description': description,
    'match': [for (final rule in match) rule.toJson()],
    'sections': [for (final s in sections) s.toJson()],
  };

  factory PromptPack.fromJson(Map<String, dynamic> json) => PromptPack(
    id: json['id'] as String,
    pluginId: json['pluginId'] as String,
    name: json['name'] as String? ?? '',
    description: json['description'] as String? ?? '',
    match: [
      for (final rule in json['match'] as List? ?? [])
        PromptMatchRule.fromJson(Map<String, dynamic>.from(rule as Map)),
    ],
    sections: [
      for (final s in json['sections'] as List? ?? [])
        PromptSection.fromJson(Map<String, dynamic>.from(s as Map)),
    ],
  );
}

/// A preset's prompt choice: the shared pack (null means matched by model)
/// and sections only this preset has.
class PresetPromptBinding {
  const PresetPromptBinding({this.packId, this.ownSections = const []});

  final String? packId;
  final List<PromptSection> ownSections;

  bool get isEmpty => packId == null && ownSections.isEmpty;

  PresetPromptBinding withPack(String? id) =>
      PresetPromptBinding(packId: id, ownSections: ownSections);

  PresetPromptBinding upsertSection(PromptSection section) =>
      PresetPromptBinding(
        packId: packId,
        ownSections: [
          for (final s in ownSections)
            if (s.id == section.id) section else s,
          if (!ownSections.any((s) => s.id == section.id)) section,
        ],
      );

  /// Adds the [sections] whose ids are not here yet; the same instance
  /// when every one is.
  PresetPromptBinding addMissing(Iterable<PromptSection> sections) {
    var next = this;
    for (final section in sections) {
      if (!next.ownSections.any((s) => s.id == section.id)) {
        next = next.upsertSection(section);
      }
    }
    return next;
  }

  PresetPromptBinding removeSection(String id) => PresetPromptBinding(
    packId: packId,
    ownSections: [
      for (final s in ownSections)
        if (s.id != id) s,
    ],
  );

  Map<String, dynamic> toJson() => {
    if (packId != null) 'packId': packId,
    if (ownSections.isNotEmpty)
      'ownSections': [for (final s in ownSections) s.toJson()],
  };

  static PresetPromptBinding fromJson(Object? json) {
    if (json is! Map) return const PresetPromptBinding();
    return PresetPromptBinding(
      packId: json['packId'] as String?,
      ownSections: [
        for (final s in json['ownSections'] as List? ?? [])
          PromptSection.fromJson(Map<String, dynamic>.from(s as Map)),
      ],
    );
  }
}

/// The pack a request uses, fixed with the preset snapshot.
class ResolvedPromptPack {
  const ResolvedPromptPack({
    required this.pack,
    this.ownSections = const [],
    this.automatic = false,
  });

  final PromptPack pack;
  final List<PromptSection> ownSections;

  /// Chosen by model matching rather than bound by the preset.
  final bool automatic;

  List<PromptSection> sectionsFor(String scope) => [
    for (final s in [...pack.sections, ...ownSections])
      if (s.scope == scope && s.enabled && s.text.trim().isNotEmpty) s,
  ];

  /// Enabled sections of [scope], blank-line joined, with [variables] filled.
  String render(String scope, [Map<String, Object?> variables = const {}]) {
    final text = sectionsFor(scope).map((s) => s.text.trim()).join('\n\n');
    return PromptTemplateRenderer.renderTrimmed(
      text,
      variables,
      collapseExtraBlankLines: true,
    );
  }

  Map<String, dynamic> toJson() => {
    'pack': pack.toJson(),
    if (ownSections.isNotEmpty)
      'ownSections': [for (final s in ownSections) s.toJson()],
    'automatic': automatic,
  };

  factory ResolvedPromptPack.fromJson(Map<String, dynamic> json) =>
      ResolvedPromptPack(
        pack: PromptPack.fromJson(
          Map<String, dynamic>.from(json['pack'] as Map),
        ),
        ownSections: [
          for (final s in json['ownSections'] as List? ?? [])
            PromptSection.fromJson(Map<String, dynamic>.from(s as Map)),
        ],
        automatic: json['automatic'] as bool? ?? false,
      );
}

class PromptPackMissingException implements Exception {
  const PromptPackMissingException(this.packId);
  final String packId;
  @override
  String toString() => '预设绑定的提示词包已不存在，请在预设里重新选择';
}

/// The user's changes to one built-in pack: edited or switched sections and
/// sections they added. Only differences are stored.
class BuiltinPackOverride {
  const BuiltinPackOverride({this.sections = const {}, this.added = const []});

  final Map<String, ({String? text, bool? enabled})> sections;
  final List<PromptSection> added;

  bool get isEmpty => sections.isEmpty && added.isEmpty;

  PromptPack apply(PromptPack base) => base.copyWith(
    sections: [
      for (final s in base.sections)
        s.copyWith(
          text: sections[s.id]?.text,
          enabled: sections[s.id]?.enabled,
        ),
      ...added,
    ],
  );

  Map<String, dynamic> toJson() => {
    if (sections.isNotEmpty)
      'sections': {
        for (final e in sections.entries)
          e.key: {
            if (e.value.text != null) 'text': e.value.text,
            if (e.value.enabled != null) 'enabled': e.value.enabled,
          },
      },
    if (added.isNotEmpty) 'added': [for (final s in added) s.toJson()],
  };

  factory BuiltinPackOverride.fromJson(Map<String, dynamic> json) =>
      BuiltinPackOverride(
        sections: {
          for (final e in (json['sections'] as Map? ?? {}).entries)
            '${e.key}': (
              text: (e.value as Map)['text'] as String?,
              enabled: (e.value as Map)['enabled'] as bool?,
            ),
        },
        added: [
          for (final s in json['added'] as List? ?? [])
            PromptSection.fromJson(Map<String, dynamic>.from(s as Map)),
        ],
      );
}

/// Built-in packs with the user's differences, plus the user's own packs.
class PromptPackLibrary {
  PromptPackLibrary({
    required List<PromptPack> builtins,
    Map<String, BuiltinPackOverride> overrides = const {},
    List<PromptPack> custom = const [],
  }) : builtins = List.unmodifiable(builtins),
       overrides = Map.unmodifiable(overrides),
       custom = List.unmodifiable(custom);

  final List<PromptPack> builtins;
  final Map<String, BuiltinPackOverride> overrides;
  final List<PromptPack> custom;

  PromptPack? builtin(String id) =>
      builtins.where((p) => p.id == id).firstOrNull;

  /// The pack as requests see it, built-in differences applied.
  PromptPack? byId(String id) {
    final base = builtin(id);
    if (base != null) return overrides[id]?.apply(base) ?? base;
    return custom.where((p) => p.id == id).firstOrNull;
  }

  PromptPack require(String id) =>
      byId(id) ?? (throw PromptPackMissingException(id));

  /// Custom packs first, then built-in ones, each in list order.
  List<PromptPack> packsFor(String pluginId) => [
    for (final p in custom)
      if (p.pluginId == pluginId) p,
    for (final p in builtins)
      if (p.pluginId == pluginId) byId(p.id)!,
  ];

  /// Custom rules → built-in rules → the built-in fallback.
  PromptPack autoMatch(String pluginId, String format, String model) {
    final packs = packsFor(pluginId);
    return packs.where((p) => p.matches(format, model)).firstOrNull ??
        packs.where((p) => p.fallback).firstOrNull ??
        (throw StateError('插件 $pluginId 没有出厂提示词包'));
  }

  ResolvedPromptPack resolve(
    String pluginId,
    PresetPromptBinding binding, {
    required String format,
    required String model,
  }) {
    final id = binding.packId;
    if (id != null && id.isNotEmpty) {
      final pack = require(id);
      if (pack.pluginId != pluginId) throw PromptPackMissingException(id);
      return ResolvedPromptPack(pack: pack, ownSections: binding.ownSections);
    }
    return ResolvedPromptPack(
      pack: autoMatch(pluginId, format, model),
      ownSections: binding.ownSections,
      automatic: true,
    );
  }

  bool isModified(String packId, String sectionId) =>
      overrides[packId]?.sections.containsKey(sectionId) ?? false;

  /// Whether [sectionId] in [packId] is one the user added (deletable).
  bool isUserSection(String packId, String sectionId) =>
      builtin(packId)?.section(sectionId) == null;

  PromptPackLibrary _withOverride(String id, BuiltinPackOverride? next) {
    final map = Map<String, BuiltinPackOverride>.of(overrides);
    if (next == null || next.isEmpty) {
      map.remove(id);
    } else {
      map[id] = next;
    }
    return PromptPackLibrary(
      builtins: builtins,
      overrides: map,
      custom: custom,
    );
  }

  PromptPackLibrary _withCustom(PromptPack pack) => PromptPackLibrary(
    builtins: builtins,
    overrides: overrides,
    custom: [
      for (final p in custom)
        if (p.id == pack.id) pack else p,
      if (!custom.any((p) => p.id == pack.id)) pack,
    ],
  );

  /// Writes a section; on a built-in section, text equal to the factory text
  /// clears the difference.
  PromptPackLibrary editSection(
    String packId,
    String sectionId, {
    String? text,
    bool? enabled,
    String? title,
  }) {
    final base = builtin(packId);
    if (base == null) {
      final pack = require(packId);
      final section =
          pack.section(sectionId) ?? (throw StateError('这个包里没有这一节'));
      return _withCustom(
        pack.copyWith(
          sections: [
            for (final s in pack.sections)
              s.id == sectionId
                  ? section.copyWith(text: text, enabled: enabled, title: title)
                  : s,
          ],
        ),
      );
    }
    final current = overrides[packId] ?? const BuiltinPackOverride();
    final added = current.added.where((s) => s.id == sectionId).firstOrNull;
    if (added != null) {
      return _withOverride(
        packId,
        BuiltinPackOverride(
          sections: current.sections,
          added: [
            for (final s in current.added)
              s.id == sectionId
                  ? s.copyWith(text: text, enabled: enabled, title: title)
                  : s,
          ],
        ),
      );
    }
    final factory = base.section(sectionId) ?? (throw StateError('这个包里没有这一节'));
    final old = current.sections[sectionId];
    final nextText = text ?? old?.text;
    final nextEnabled = enabled ?? old?.enabled;
    final sections = Map.of(current.sections);
    final keepText = nextText != null && nextText.trim() != factory.text.trim();
    final keepEnabled = nextEnabled != null && nextEnabled != factory.enabled;
    if (keepText || keepEnabled) {
      sections[sectionId] = (
        text: keepText ? nextText : null,
        enabled: keepEnabled ? nextEnabled : null,
      );
    } else {
      sections.remove(sectionId);
    }
    return _withOverride(
      packId,
      BuiltinPackOverride(sections: sections, added: current.added),
    );
  }

  PromptPackLibrary restoreSection(String packId, String sectionId) {
    final current = overrides[packId];
    if (current == null) return this;
    return _withOverride(
      packId,
      BuiltinPackOverride(
        sections: {
          for (final e in current.sections.entries)
            if (e.key != sectionId) e.key: e.value,
        },
        added: current.added,
      ),
    );
  }

  PromptPackLibrary addSection(String packId, PromptSection section) {
    final pack = require(packId);
    if (pack.section(section.id) != null) {
      throw StateError('节 ID 重复');
    }
    if (!PromptScopes.of(pack.pluginId).containsKey(section.scope)) {
      throw StateError('不支持的用途：${section.scope}');
    }
    if (builtin(packId) == null) {
      return _withCustom(pack.copyWith(sections: [...pack.sections, section]));
    }
    final current = overrides[packId] ?? const BuiltinPackOverride();
    return _withOverride(
      packId,
      BuiltinPackOverride(
        sections: current.sections,
        added: [...current.added, section],
      ),
    );
  }

  /// Removes a section the user added; factory sections can only be off.
  PromptPackLibrary removeSection(String packId, String sectionId) {
    if (builtin(packId) == null) {
      final pack = require(packId);
      return _withCustom(
        pack.copyWith(
          sections: [
            for (final s in pack.sections)
              if (s.id != sectionId) s,
          ],
        ),
      );
    }
    if (!isUserSection(packId, sectionId)) {
      throw StateError('出厂节不能删除，可以关掉');
    }
    final current = overrides[packId] ?? const BuiltinPackOverride();
    return _withOverride(
      packId,
      BuiltinPackOverride(
        sections: current.sections,
        added: [
          for (final s in current.added)
            if (s.id != sectionId) s,
        ],
      ),
    );
  }

  /// Copies [packId] as it is now into a new custom pack.
  PromptPackLibrary fork(String packId, {required String newId, String? name}) {
    if (byId(newId) != null) throw StateError('提示词包 ID 重复');
    final pack = require(packId);
    return _withCustom(
      pack.copyWith(
        id: newId,
        name: name ?? '${pack.name}（副本）',
        // A copy is bound explicitly; it must not take over the original's
        // model family.
        match: pack.builtIn ? const [] : pack.match,
      ),
    );
  }

  /// Saves a custom pack's name, description and rules.
  PromptPackLibrary saveCustom(PromptPack pack) {
    if (pack.builtIn) throw StateError('出厂包的名字和匹配规则不能改');
    for (final rule in pack.match) {
      for (final pattern in rule.models) {
        final error = PromptMatchRule.patternError(pattern);
        if (error != null) throw StateError('正则「$pattern」有误：$error');
      }
    }
    return _withCustom(pack);
  }

  PromptPackLibrary deleteCustom(String id) {
    if (builtin(id) != null) throw StateError('出厂包不能删除');
    return PromptPackLibrary(
      builtins: builtins,
      overrides: overrides,
      custom: [
        for (final p in custom)
          if (p.id != id) p,
      ],
    );
  }

  /// What undo restores of one pack: a built-in pack's differences or a
  /// custom pack as a whole, null when there is none.
  Map<String, Object?> packSnapshot(String id) => builtin(id) != null
      ? {'pack_id': id, 'override': overrides[id]?.toJson()}
      : {
          'pack_id': id,
          'custom': custom.where((p) => p.id == id).firstOrNull?.toJson(),
        };

  /// Puts a [packSnapshot] back.
  PromptPackLibrary restorePack(Map<String, Object?> snapshot) {
    final id = '${snapshot['pack_id']}';
    if (builtin(id) != null) {
      final raw = snapshot['override'];
      return _withOverride(
        id,
        raw == null
            ? null
            : BuiltinPackOverride.fromJson(
                Map<String, dynamic>.from(raw as Map),
              ),
      );
    }
    final raw = snapshot['custom'];
    if (raw == null) {
      return custom.any((p) => p.id == id) ? deleteCustom(id) : this;
    }
    return _withCustom(
      PromptPack.fromJson(Map<String, dynamic>.from(raw as Map)),
    );
  }

  Map<String, dynamic> toJson() => {
    'version': 1,
    if (overrides.isNotEmpty)
      'overrides': {for (final e in overrides.entries) e.key: e.value.toJson()},
    if (custom.isNotEmpty) 'custom': [for (final p in custom) p.toJson()],
  };

  factory PromptPackLibrary.fromJson(
    Map<String, dynamic> json, {
    required List<PromptPack> builtins,
  }) {
    if (json['version'] != 1) {
      throw const FormatException('不支持的提示词包版本');
    }
    return PromptPackLibrary(
      builtins: builtins,
      overrides: _carryRetiredSections(
        {
          for (final e in (json['overrides'] as Map? ?? {}).entries)
            '${e.key}': BuiltinPackOverride.fromJson(
              Map<String, dynamic>.from(e.value as Map),
            ),
        },
        builtins,
      ),
      custom: [
        for (final p in json['custom'] as List? ?? [])
          PromptPack.fromJson(Map<String, dynamic>.from(p as Map)),
      ],
    );
  }
}

/// Factory sections merged away or renamed, with the scope they had. Edits
/// the user made to them are kept as own sections of that scope.
const _retiredFactorySections = <String, String>{
  'image.rules': PromptScopes.imageInline,
  'novelai.style': PromptScopes.imageInline,
  'novelai.contract': PromptScopes.imageInline,
  'danbooru.style': PromptScopes.imageInline,
  'danbooru.contract': PromptScopes.imageInline,
  'natural.rules': PromptScopes.imageInline,
  'natural.style': PromptScopes.imageInline,
  'natural.contract': PromptScopes.imageInline,
  'novelai.tool_prompt': PromptScopes.imageToolPrompt,
  'danbooru.tool_prompt': PromptScopes.imageToolPrompt,
  'natural.tool_prompt': PromptScopes.imageToolPrompt,
  'novelai.tool_negative': PromptScopes.imageToolPrompt,
  'danbooru.tool_negative': PromptScopes.imageToolPrompt,
  'natural.tool_negative': PromptScopes.imageToolPrompt,
  'image.tool_width': PromptScopes.imageToolParams,
  'image.tool_height': PromptScopes.imageToolParams,
  'image.tool_count': PromptScopes.imageToolParams,
  'image.tool_steps': PromptScopes.imageToolParams,
  'image.tool_guidance_scale': PromptScopes.imageToolParams,
};

/// Moves the user's text for retired factory sections into own sections of
/// the same scope; the rest of the override is kept as it was.
Map<String, BuiltinPackOverride> _carryRetiredSections(
  Map<String, BuiltinPackOverride> overrides,
  List<PromptPack> builtins,
) {
  final result = <String, BuiltinPackOverride>{};
  for (final entry in overrides.entries) {
    final base = builtins.where((p) => p.id == entry.key).firstOrNull;
    final live = {for (final s in base?.sections ?? const <PromptSection>[]) s.id};
    final sections = <String, ({String? text, bool? enabled})>{};
    final added = [...entry.value.added];
    for (final section in entry.value.sections.entries) {
      final scope = _retiredFactorySections[section.key];
      if (live.contains(section.key) || scope == null) {
        sections[section.key] = section.value;
        continue;
      }
      final text = section.value.text?.trim();
      if (text != null && text.isNotEmpty) {
        added.add(
          PromptSection(
            id: 'carried.${section.key}',
            scope: PromptScopes.canonical(scope),
            title: '旧版自定义节',
            text: text,
          ),
        );
      }
    }
    result[entry.key] = BuiltinPackOverride(sections: sections, added: added);
  }
  return result;
}
