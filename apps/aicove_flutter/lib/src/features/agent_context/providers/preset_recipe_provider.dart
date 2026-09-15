/// 预设 Recipe 提供者
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/silly_tavern_preset_store.dart';
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
      description:
          '${preset.enabledPromptCount} 个启用节点 · 顺序组 ${preset.selectedOrder.sourceIndex + 1}'
          '${preset.regexScriptCount > 0 ? ' · regex ${preset.regexAuthorized ? '已授权' : '未授权'}' : ''}',
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
