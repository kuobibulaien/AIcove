import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/app_logger.dart';
import '../../../core/prompts/prompt_builtin_defaults.g.dart';
import '../../../core/sync/cloud_setting_policy.dart';
import '../sticker/sticker_config.dart';
import '../time_awareness/time_awareness_config.dart';
import '../trigger/trigger_plugin.dart';
import '../web_search/web_search_plugin.dart';

/// 所有角色共用的插件提示词；语音和绘图使用独立提示词包。
enum PluginPromptSlot {
  sticker(
    pluginId: 'sticker',
    plugin: '表情包',
    title: '表情包说明',
    subtitle: '告诉角色怎么在回复里挑表情包、多久发一次',
    hint: '可用占位符：{tags}（当前开启的表情包标签列表）',
    defaultText: StickerConfig.defaultSystemPromptTemplate,
  ),
  currentTime(
    pluginId: 'time_awareness',
    plugin: '时间感知',
    title: '当前时间提醒',
    subtitle: '告诉角色现在几点、星期几的文字格式',
    hint: '可用占位符：{datetime}（当前本地时间）',
    defaultText: TimeAwarenessConfig.defaultCurrentTimePromptTemplate,
  ),
  timeContextGuide(
    pluginId: 'time_awareness',
    plugin: '时间感知',
    title: '时间背景说明',
    subtitle: '告诉角色怎么理解消息时间和上次说话隔了多久',
    hint:
        '可用占位符：{current_time_explanation}、{previous_user_message_explanation}',
    defaultText: TimeAwarenessConfig.defaultSystemGuidePromptTemplate,
  ),
  webSearchTool(
    pluginId: 'web_search',
    plugin: '联网搜索',
    title: '搜索网页说明',
    subtitle: '告诉角色什么时候去搜网页、怎么写搜索词',
    hint: '告诉角色在什么情况下应该去搜索网页，以及怎么组织搜索词',
    defaultText: WebSearchPlugin.defaultSearchToolDescription,
  ),
  webFetchTool(
    pluginId: 'web_search',
    plugin: '联网搜索',
    title: '读取网页说明',
    subtitle: '告诉角色什么时候点开链接读网页正文',
    hint: '告诉角色什么时候需要打开链接阅读网页全文',
    defaultText: WebSearchPlugin.defaultFetchToolDescription,
  ),
  createReminderTool(
    pluginId: 'auto_reply',
    plugin: '主动回复与提醒',
    title: '创建定时提醒说明',
    subtitle: '告诉角色什么时候帮你定闹钟或定时提醒',
    hint: '告诉角色在什么情况下为你设置闹钟或定时提醒',
    defaultText: TriggerPlugin.defaultCreateReminderDescription,
  ),
  deleteReminderTool(
    pluginId: 'auto_reply',
    plugin: '主动回复与提醒',
    title: '取消定时提醒说明',
    subtitle: '告诉角色怎么帮你取消定好的提醒',
    hint: '告诉角色怎么帮你取消已经定好的提醒',
    defaultText: TriggerPlugin.defaultDeleteReminderDescription,
  ),
  listRemindersTool(
    pluginId: 'auto_reply',
    plugin: '主动回复与提醒',
    title: '查看提醒列表说明',
    subtitle: '告诉角色什么时候列出当前的提醒和待办',
    hint: '告诉角色什么时候为你列出当前的提醒和待办',
    defaultText: TriggerPlugin.defaultListRemindersDescription,
  ),
  searchRemindersTool(
    pluginId: 'auto_reply',
    plugin: '主动回复与提醒',
    title: '搜索提醒说明',
    subtitle: '告诉角色怎么按关键词查找已有提醒',
    hint: '告诉角色怎么按关键词查找已有的提醒',
    defaultText: TriggerPlugin.defaultSearchRemindersDescription,
  ),
  proactiveReachOutReminder(
    pluginId: 'auto_reply',
    plugin: '主动回复与提醒',
    title: '主动发消息引导',
    subtitle: '角色主动找你说话时的开场引导语',
    hint: '可用占位符：{fire_time}（发送时间）、{gap}（距上次说话间隔）、{kind_hint}（开口方式提示）',
    defaultText: PromptBuiltinDefaults.autoReplyReachOutReminder,
  ),
  proactiveCallHint(
    pluginId: 'auto_reply',
    plugin: '主动回复与提醒',
    title: '主动打电话引导',
    subtitle: '允许主动来电时，告诉角色什么时候可以打语音电话',
    hint: '允许主动来电时，引导角色决定是发消息还是直接打电话',
    defaultText: PromptBuiltinDefaults.autoReplyReachOutCallHint,
  ),
  proactiveCallTool(
    pluginId: 'auto_reply',
    plugin: '主动回复与提醒',
    title: '拨打电话工具说明',
    subtitle: '告诉角色拨打语音电话时的性格表现与第一句话要求',
    hint: '告诉角色主动打语音电话时的性格表现和接通后第一句话的要求',
    defaultText: PromptBuiltinDefaults.autoReplyToolCallUser,
  ),
  proactiveImageHint(
    pluginId: 'auto_reply',
    plugin: '主动回复与提醒',
    title: '主动发自拍引导',
    subtitle: '开启绘图时，引导角色主动发消息可以顺手带照片',
    hint: '开启绘图时，引导角色主动发消息时自然顺手带上照片',
    defaultText: PromptBuiltinDefaults.autoReplyReachOutImageHint,
  );

  const PluginPromptSlot({
    required this.pluginId,
    required this.plugin,
    required this.title,
    required this.subtitle,
    required this.hint,
    required this.defaultText,
  });

  final String pluginId;
  final String plugin;
  final String title;
  final String subtitle;
  final String hint;
  final String defaultText;

  static List<PluginPromptSlot> forPlugin(String pluginId) => [
    for (final s in values)
      if (s.pluginId == pluginId) s,
  ];
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

  factory PluginPrompts.fromJson(Map<String, dynamic> json) {
    final slots = {for (final slot in PluginPromptSlot.values) slot.name: slot};
    final overrides = <String, String>{};
    for (final entry in json.entries) {
      final value = entry.value;
      if (value is! String || value.trim().isEmpty) continue;
      final slot = slots[entry.key];
      if (slot != null && value.trim() == slot.defaultText.trim()) continue;
      overrides[entry.key] = value;
    }
    return PluginPrompts(Map.unmodifiable(overrides));
  }
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
  Future<bool> setTextIf(PluginPromptSlot slot, String expected, String text) {
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
