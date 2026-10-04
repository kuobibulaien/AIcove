import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/app_logger.dart';
import '../../../core/sync/cloud_setting_policy.dart';
import '../image/drawing_preset.dart';
import '../image/drawing_preset_provider.dart';
import '../image/image_config.dart';
import '../sticker/sticker_config.dart';
import '../time_awareness/time_awareness_config.dart';
import '../tts/tts_config.dart';

/// 插件提示词：所有角色共用的一份标签／工具说明。
///
/// 角色只能改自己的专属提示词（人设、角色专属绘图提示词），
/// 不能改这里的通用说明；预设也不再携带这些文本。
enum PluginPromptSlot {
  image(
    plugin: '绘图',
    title: '<image> 标签说明',
    hint: '告诉模型何时、怎样输出 <image>英文提示词</image>。角色专属绘图要求在角色设置里填写，会追加在这段之后。',
    defaultText: ImageConfig.defaultInlinePromptTemplate,
  ),
  tts(
    plugin: '语音',
    title: '<tts> 标签说明',
    hint: '可用占位符：{max_chars_per_chunk}、{voice_frequency}；MiniMax／Fish Audio 的补充指引会自动追加。',
    defaultText: TtsConfig.defaultSystemPromptTemplate,
  ),
  sticker(
    plugin: '表情包',
    title: '表情包说明',
    hint: '{tags} 会替换为当前可用的表情包标签；没有表情包时不注入。',
    defaultText: StickerConfig.defaultSystemPromptTemplate,
  ),
  currentTime(
    plugin: '时间感知',
    title: '当前时间提醒',
    hint: '放在 <system-reminder> 里，{datetime} 会替换为发送时间。',
    defaultText: TimeAwarenessConfig.defaultCurrentTimePromptTemplate,
  );

  const PluginPromptSlot({
    required this.plugin,
    required this.title,
    required this.hint,
    required this.defaultText,
  });

  final String plugin;
  final String title;
  final String hint;
  final String defaultText;
}

class PluginPrompts {
  const PluginPrompts([this.overrides = const {}]);

  /// 只保存与出厂默认不同的槽位，键为 [PluginPromptSlot.name]。
  final Map<String, String> overrides;

  String of(PluginPromptSlot slot) => overrides[slot.name] ?? slot.defaultText;

  bool isDefault(PluginPromptSlot slot) => !overrides.containsKey(slot.name);

  PluginPrompts withText(PluginPromptSlot slot, String text) {
    final next = Map<String, String>.of(overrides);
    if (text.trim().isEmpty || text.trim() == slot.defaultText.trim()) {
      next.remove(slot.name);
    } else {
      next[slot.name] = text;
    }
    return PluginPrompts(Map.unmodifiable(next));
  }

  Map<String, String> toJson() => overrides;

  factory PluginPrompts.fromJson(Map<String, dynamic> json) => PluginPrompts(
    Map.unmodifiable({
      for (final slot in PluginPromptSlot.values)
        if (json[slot.name] is String) slot.name: json[slot.name] as String,
    }),
  );
}

abstract interface class PluginPromptStore {
  Future<PluginPrompts> load();
  Future<void> save(PluginPrompts prompts);
}

class PreferencesPluginPromptStore implements PluginPromptStore {
  static const storageKey = 'aicove.plugins.prompts.v1';

  @override
  Future<PluginPrompts> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(storageKey);
    if (raw != null) {
      return PluginPrompts.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    }
    final migrated = migrateLegacy(prefs);
    // 旧键原样保留，回滚代码即可恢复旧行为。
    await save(migrated);
    return migrated;
  }

  @override
  Future<void> save(PluginPrompts prompts) async {
    final prefs = await SharedPreferences.getInstance();
    if (!await saveCloudPreference(
      prefs,
      storageKey,
      jsonEncode(prompts.toJson()),
    )) {
      throw StateError('插件提示词未能保存，请重试');
    }
  }

  /// 从旧的插件配置与默认预设收拢出全局一份（2026-10-03）。
  static PluginPrompts migrateLegacy(SharedPreferences prefs) {
    var prompts = const PluginPrompts();
    Map<String, dynamic>? read(String key) {
      final raw = prefs.getString(key);
      if (raw == null || raw.isEmpty) return null;
      try {
        return jsonDecode(raw) as Map<String, dynamic>;
      } catch (error) {
        AppLogger.warning(
          'PluginPrompts',
          '旧插件提示词读取失败，使用默认值',
          metadata: {'key': key, 'errorType': error.runtimeType.toString()},
        );
        return null;
      }
    }

    void take(PluginPromptSlot slot, String? Function() value) {
      try {
        final text = value();
        if (text != null) prompts = prompts.withText(slot, text);
      } catch (error) {
        AppLogger.warning(
          'PluginPrompts',
          '旧插件提示词迁移失败，使用默认值',
          metadata: {
            'slot': slot.name,
            'errorType': error.runtimeType.toString(),
          },
        );
      }
    }

    take(PluginPromptSlot.image, () {
      final catalogJson = read(PreferencesDrawingPresetStore.storageKey);
      final ImageConfig config;
      if (catalogJson != null) {
        final catalog = DrawingPresetCatalog.fromJson(catalogJson);
        config = catalog.require(catalog.defaultPresetId).config;
      } else {
        final legacy = read(PreferencesDrawingPresetStore.legacyKey);
        if (legacy == null) return null;
        config = ImageConfig.fromJson(legacy);
      }
      final text = config.effectiveInlinePromptTemplate;
      return text.trim() ==
              ImageConfig.runtimeDefaultInlinePromptTemplate.trim()
          ? null
          : text;
    });
    take(PluginPromptSlot.tts, () {
      final json = read('aicove.plugins.tts.config');
      if (json == null) return null;
      final config = TtsConfig.fromJson(json);
      final preset = config.voicePresets
          .where((p) => p.id == config.defaultVoicePresetId)
          .firstOrNull;
      return preset?.synthesis?.systemPromptTemplate ??
          config.systemPromptTemplate;
    });
    take(PluginPromptSlot.sticker, () {
      final json = read('aicove.plugins.sticker.config');
      return json == null
          ? null
          : StickerConfig.fromJson(json).systemPromptTemplate;
    });
    take(PluginPromptSlot.currentTime, () {
      final json = read('aicove.plugins.time_awareness.config');
      return json == null
          ? null
          : TimeAwarenessConfig.fromJson(json).currentTimePromptTemplate;
    });
    return prompts;
  }
}

final pluginPromptStoreProvider = Provider<PluginPromptStore>(
  (ref) => PreferencesPluginPromptStore(),
);

final pluginPromptsProvider =
    AsyncNotifierProvider<PluginPromptsNotifier, PluginPrompts>(
      PluginPromptsNotifier.new,
    );

class PluginPromptsNotifier extends AsyncNotifier<PluginPrompts> {
  Future<void> _writes = Future.value();

  @override
  Future<PluginPrompts> build() => ref.read(pluginPromptStoreProvider).load();

  /// 空文本或与默认相同视为恢复默认。
  Future<void> setText(PluginPromptSlot slot, String text) {
    final operation = _writes.then((_) async {
      final next = (await future).withText(slot, text);
      await ref.read(pluginPromptStoreProvider).save(next);
      state = AsyncData(next);
    });
    _writes = operation.then((_) {}, onError: (Object _, StackTrace __) {});
    return operation;
  }
}
