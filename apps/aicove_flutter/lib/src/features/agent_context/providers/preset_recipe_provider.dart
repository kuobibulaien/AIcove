/// 预设 Recipe 提供者
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../chat/conversation_providers.dart';
import '../../content_tags/domain/tag_presentation.dart';
import '../data/silly_tavern_preset_store.dart';
import '../domain/preset_tag_mapping.dart';
import '../domain/silly_tavern_preset.dart';
import '../domain/tavern_compatibility_port.dart';

/// 预设摘要
class PresetRecipeSummary {
  final String id;
  final String name;
  final String description;
  final int warningCount;
  final int regexScriptCount;
  final bool regexAuthorized;

  const PresetRecipeSummary({
    required this.id,
    required this.name,
    required this.description,
    this.warningCount = 0,
    this.regexScriptCount = 0,
    this.regexAuthorized = false,
  });

  factory PresetRecipeSummary.fromPreset(SillyTavernPreset preset) {
    return PresetRecipeSummary(
      id: preset.id,
      name: preset.name,
      description: [
        '${preset.enabledPromptCount} 条提示词',
        if (preset.regexScriptCount > 0)
          '${preset.regexScriptCount} 条正则${preset.regexAuthorized ? '' : '（未开启）'}',
        if (preset.worldBooks.isNotEmpty) '${preset.worldBooks.length} 本世界书',
      ].join(' · '),
      warningCount: preset.warnings.length,
      regexScriptCount: preset.regexScriptCount,
      regexAuthorized: preset.regexAuthorized,
    );
  }
}

final sillyTavernPresetStoreProvider = Provider<SillyTavernPresetStore>((ref) {
  return SillyTavernPresetStore();
});

final tavernCompatibilityPortProvider = Provider<TavernCompatibilityPort>(
  (ref) => ref.watch(sillyTavernPresetStoreProvider),
);
final tavernPluginSettingsProvider = FutureProvider<TavernPluginSettings>(
  (ref) => ref.watch(tavernCompatibilityPortProvider).loadPluginSettings(),
);

/// 已导入酒馆预设列表。
final presetRecipeListProvider = FutureProvider<List<PresetRecipeSummary>>((
  ref,
) async {
  final presets = await ref.read(sillyTavernPresetStoreProvider).list();
  return presets.map(PresetRecipeSummary.fromPreset).toList(growable: false);
});

/// 单个预设提供者
final presetRecipeProvider = FutureProvider.family<SillyTavernPreset?, String>((
  ref,
  recipeId,
) async {
  return ref.read(sillyTavernPresetStoreProvider).get(recipeId);
});

/// 聊天中发现、映射里还没有的标签（ADR0048）：按会话绑定的 recipeId 分组，
/// 空字符串表示“使用默认预设”。只存内存、不写预设，用户在标签页归类后
/// 才写入 `tagDisplay` 覆盖。
final observedUnknownTagsProvider = StateProvider<Map<String, Set<String>>>(
  (ref) => const {},
);

String observedTagsKey(String? recipeId) => recipeId?.trim() ?? '';

/// 聊天显示用的标签呈现映射（ADR0046）：会话绑定预设（未绑定时用默认预设）
/// 的推断与用户覆盖，内置常用名打底。插件关闭或读取失败时只用内置常用名。
final tagPresentationForRecipeProvider =
    FutureProvider.family<TagPresentationMap, String?>((ref, recipeId) async {
      final builtin = builtinPresetTagMapping.presentationMap;
      final settings = await ref.watch(tavernPluginSettingsProvider.future);
      if (!settings.enabled) return builtin;
      final trimmed = recipeId?.trim();
      final id = trimmed != null && trimmed.isNotEmpty
          ? trimmed
          : settings.defaultPresetId;
      if (id == null) return builtin;
      final preset = await ref.watch(presetRecipeProvider(id).future);
      return preset == null
          ? builtin
          : inferPresetTagMapping(preset).presentationMap;
    });

final presetRecipeImportControllerProvider =
    AsyncNotifierProvider<PresetRecipeImportController, void>(
      PresetRecipeImportController.new,
    );

/// UI 与具体文件仓库之间的应用层入口。
class PresetRecipeImportController extends AsyncNotifier<void> {
  @override
  Future<void> build() async {}

  SillyTavernPreset previewSource(
    String source, {
    required String sourceFileName,
  }) {
    return ref
        .read(sillyTavernPresetStoreProvider)
        .previewSource(source, sourceFileName: sourceFileName);
  }

  Future<SillyTavernPreset> importSource(
    String source, {
    required String sourceFileName,
    bool regexAuthorized = false,
  }) async {
    state = const AsyncLoading();
    try {
      final preset = await ref
          .read(sillyTavernPresetStoreProvider)
          .importSource(
            source,
            sourceFileName: sourceFileName,
            regexAuthorized: regexAuthorized,
          );
      ref.invalidate(presetRecipeListProvider);
      ref.invalidate(presetRecipeProvider(preset.id));
      state = const AsyncData(null);
      return preset;
    } catch (error, stackTrace) {
      state = AsyncError(error, stackTrace);
      rethrow;
    }
  }

  Future<void> change(
    String? presetId,
    Future<void> Function(TavernCompatibilityPort port) action,
  ) async {
    state = const AsyncLoading();
    try {
      await action(ref.read(tavernCompatibilityPortProvider));
      ref.invalidate(presetRecipeListProvider);
      ref.invalidate(tavernPluginSettingsProvider);
      if (presetId != null) ref.invalidate(presetRecipeProvider(presetId));
      state = const AsyncData(null);
    } catch (error, stackTrace) {
      state = AsyncError(error, stackTrace);
      rethrow;
    }
  }

  /// 没有外部提示词预设时，也可建立一套仅使用正则／世界书的组合。
  Future<SillyTavernPreset> createBasicPreset() => importSource(
    '''{"name":"基础上下文","prompts":[
      {"identifier":"worldInfoBefore","name":"世界书：角色定义前","marker":true},
      {"identifier":"charDescription","name":"角色定义","marker":true},
      {"identifier":"scenario","name":"场景","marker":true},
      {"identifier":"worldInfoAfter","name":"世界书：角色定义后","marker":true},
      {"identifier":"chatHistory","name":"聊天记录","marker":true}],
      "prompt_order":[{"identifier":"worldInfoBefore","enabled":true},
      {"identifier":"charDescription","enabled":true},
      {"identifier":"scenario","enabled":true},
      {"identifier":"worldInfoAfter","enabled":true},
      {"identifier":"chatHistory","enabled":true}]}''',
    sourceFileName: '基础上下文.json',
  );

  /// 删除预设。仍有角色明确绑定时拒绝，避免这些角色请求时报“预设丢失”。
  Future<void> deletePreset(String presetId) async {
    state = const AsyncLoading();
    try {
      final roles = await ref.read(conversationsProvider.future);
      final references = [
        for (final role in roles)
          if (role.recipeId?.trim() == presetId) role.displayName,
      ];
      if (references.isNotEmpty) {
        throw StateError('角色「${references.join('、')}」仍在使用此预设，请先在角色卡更换酒馆预设');
      }
      await ref.read(sillyTavernPresetStoreProvider).deletePreset(presetId);
      ref.invalidate(presetRecipeListProvider);
      ref.invalidate(tavernPluginSettingsProvider);
      ref.invalidate(presetRecipeProvider(presetId));
      state = const AsyncData(null);
    } catch (error, stackTrace) {
      state = AsyncError(error, stackTrace);
      rethrow;
    }
  }

  Future<void> setRegexAuthorization(String presetId, bool authorized) async {
    state = const AsyncLoading();
    try {
      final updated = await ref
          .read(sillyTavernPresetStoreProvider)
          .setRegexAuthorization(presetId, authorized);
      if (!updated) throw StateError('预设不存在或无法更新');
      ref.invalidate(presetRecipeListProvider);
      ref.invalidate(presetRecipeProvider(presetId));
      state = const AsyncData(null);
    } catch (error, stackTrace) {
      state = AsyncError(error, stackTrace);
      rethrow;
    }
  }
}
