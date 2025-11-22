import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'character_preset.dart';

/// 角色预设的本地存储（用 SharedPreferences 保存 JSON）。
class PresetStore {
  static const _storageKey = 'mygril.presets.v1';

  Future<List<CharacterPreset>> loadPresets() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey);

    if (raw == null || raw.isEmpty) {
      final defaults = _defaultPresets();
      await _writePresets(prefs, defaults);
      return defaults;
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        final list = <CharacterPreset>[];
        for (final item in decoded) {
          if (item is Map<String, dynamic>) {
            list.add(CharacterPreset.fromJson(item));
          } else if (item is Map) {
            list.add(CharacterPreset.fromJson(Map<String, dynamic>.from(item)));
          }
        }
        if (decoded.isNotEmpty && list.isEmpty) {
          final defaults = _defaultPresets();
          await _writePresets(prefs, defaults);
          return defaults;
        }
        if (list.length != decoded.length) {
          await _writePresets(prefs, list);
        }
        return list;
      }
    } catch (_) {
      // 解析失败时回退到默认预设。
    }

    final defaults = _defaultPresets();
    await _writePresets(prefs, defaults);
    return defaults;
  }

  Future<CharacterPreset?> getPreset(String id) async {
    final presets = await loadPresets();
    for (final preset in presets) {
      if (preset.id == id) {
        return preset;
      }
    }
    return null;
  }

  Future<CharacterPreset> createPreset({
    required String name,
    required String displayName,
    String? avatarUrl,
    String? characterImage,
    String? organization,
    String personaPrompt = '',
  }) async {
    final presets = await loadPresets();
    final now = DateTime.now();
    final preset = CharacterPreset(
      id: _generateId(),
      name: name,
      displayName: displayName,
      avatarUrl: avatarUrl,
      characterImage: characterImage,
      organization: organization,
      personaPrompt: personaPrompt,
      createdAt: now,
    );
    final next = List<CharacterPreset>.from(presets)..add(preset);
    final prefs = await SharedPreferences.getInstance();
    await _writePresets(prefs, next);
    return preset;
  }

  Future<CharacterPreset> updatePreset(
    String id, {
    String? name,
    String? displayName,
    String? avatarUrl,
    String? characterImage,
    String? organization,
    String? personaPrompt,
  }) async {
    final presets = await loadPresets();
    final index = presets.indexWhere((preset) => preset.id == id);
    if (index < 0) {
      throw Exception('Preset not found');
    }

    final target = presets[index];
    final updated = target.copyWith(
      name: name ?? target.name,
      displayName: displayName ?? target.displayName,
      avatarUrl: avatarUrl ?? target.avatarUrl,
      characterImage: characterImage ?? target.characterImage,
      organization: organization ?? target.organization,
      personaPrompt: personaPrompt ?? target.personaPrompt,
    );

    final next = List<CharacterPreset>.from(presets)..[index] = updated;
    final prefs = await SharedPreferences.getInstance();
    await _writePresets(prefs, next);
    return updated;
  }

  Future<void> deletePreset(String id) async {
    final presets = await loadPresets();
    final next = presets.where((preset) => preset.id != id).toList();
    if (next.length == presets.length) {
      throw Exception('Preset not found');
    }
    final prefs = await SharedPreferences.getInstance();
    await _writePresets(prefs, next);
  }

  Future<void> _writePresets(
    SharedPreferences prefs,
    List<CharacterPreset> presets,
  ) async {
    final payload = jsonEncode(
      presets.map((preset) => preset.toJson()).toList(),
    );
    await prefs.setString(_storageKey, payload);
  }

  List<CharacterPreset> _defaultPresets() {
    final now = DateTime.now();
    return [
      CharacterPreset(
        id: 'preset_arona',
        name: 'Arona 预设',
        displayName: 'Arona',
        avatarUrl: null,
        characterImage: 'assets/characters/Arona.webp',
        organization: '联邦学生会',
        personaPrompt: '你是联邦学生会的成员Arona，充满活力和好奇心。',
        createdAt: now,
      ),
      CharacterPreset(
        id: 'preset_aru',
        name: 'Aru 预设',
        displayName: 'Aru',
        avatarUrl: null,
        characterImage: 'assets/characters/Aru.webp',
        organization: '便利屋68',
        personaPrompt: '你是便利屋68的成员Aru，性格开朗，乐于助人。',
        createdAt: now,
      ),
      CharacterPreset(
        id: 'preset_hoshino',
        name: 'Hoshino 预设',
        displayName: 'Hoshino',
        avatarUrl: null,
        characterImage: 'assets/characters/Hoshino.webp',
        organization: '对策委员会',
        personaPrompt: '你是对策委员会的成员Hoshino，冷静理智，擅长分析。',
        createdAt: now,
      ),
      CharacterPreset(
        id: 'preset_shiroko',
        name: 'Shiroko 预设',
        displayName: 'Shiroko',
        avatarUrl: null,
        characterImage: 'assets/characters/Shiroko.webp',
        organization: '对策委员会',
        personaPrompt: '你是对策委员会的成员Shiroko，温柔体贴，善解人意。',
        createdAt: now,
      ),
      CharacterPreset(
        id: 'preset_hina',
        name: 'Hina 预设',
        displayName: 'Hina',
        avatarUrl: null,
        characterImage: 'assets/characters/Hina.webp',
        organization: '风纪委员会',
        personaPrompt: '你是风纪委员会的成员Hina，严格认真，注重规则。',
        createdAt: now,
      ),
    ];
  }

  String _generateId() => 'preset_${DateTime.now().microsecondsSinceEpoch}';
}

