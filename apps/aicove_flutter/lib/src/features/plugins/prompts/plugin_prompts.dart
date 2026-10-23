import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/app_logger.dart';
import '../../../core/sync/cloud_setting_policy.dart';
import '../sticker/sticker_config.dart';
import '../time_awareness/time_awareness_config.dart';

/// 插件提示词：所有角色共用的一份标签说明（ADR0054）。
///
/// 语音、绘图已改为按模型的提示词包，由预设绑定（ADR0092）；这里只剩
/// 尚未改造的插件，全部迁走后整页退役。
enum PluginPromptSlot {
  sticker(
    plugin: '表情包',
    title: '表情包说明',
    hint: '可用占位符：{tags}',
    defaultText: StickerConfig.defaultSystemPromptTemplate,
  ),
  currentTime(
    plugin: '时间感知',
    title: '当前时间提醒',
    hint: '可用占位符：{datetime}',
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

  /// [setText] only while [slot] still reads [expected], checked in the same
  /// turn of the write queue; false when it does not.
  Future<bool> setTextIf(
    PluginPromptSlot slot,
    String expected,
    String text,
  ) {
    final operation = _writes.then((_) async {
      final current = await future;
      if (current.of(slot) != expected) return false;
      final next = current.withText(slot, text);
      await ref.read(pluginPromptStoreProvider).save(next);
      state = AsyncData(next);
      return true;
    });
    _writes = operation.then((_) {}, onError: (Object _, StackTrace __) {});
    return operation;
  }

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
