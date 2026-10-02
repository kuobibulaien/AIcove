import '../../../core/sync/cloud_setting_policy.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../chat/conversation_providers.dart';
import '../../chat/domain/persona_prompt_codec.dart';
import 'drawing_preset.dart';
import 'image_config.dart';
import 'image_plugin.dart';

abstract interface class DrawingPresetTestPort {
  Future<String?> generate(String prompt);
}

class PluginDrawingPresetTestAdapter implements DrawingPresetTestPort {
  final ImagePlugin _plugin;
  PluginDrawingPresetTestAdapter(this._plugin);
  @override
  Future<String?> generate(String prompt) =>
      _plugin.runDrawImageToolForDebug(prompt: prompt);
}

final drawingPresetTestProvider = Provider.autoDispose
    .family<DrawingPresetTestPort, ImageConfig>(
      (ref, config) => PluginDrawingPresetTestAdapter(
        ImagePlugin(config, ref, isRequestSnapshot: true),
      ),
    );

abstract interface class DrawingPresetStore {
  Future<DrawingPresetCatalog> load();
  Future<void> save(DrawingPresetCatalog catalog);
}

class PreferencesDrawingPresetStore implements DrawingPresetStore {
  static const storageKey = 'aicove.plugins.image.drawing_presets.v1';
  static const legacyKey = 'aicove.plugins.image.config';

  @override
  Future<DrawingPresetCatalog> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(storageKey);
    if (raw != null) {
      return DrawingPresetCatalog.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    }
    final legacy = prefs.getString(legacyKey);
    final catalog = DrawingPresetCatalog.migrate(
      legacy == null
          ? const ImageConfig()
          : ImageConfig.fromJson(jsonDecode(legacy) as Map<String, dynamic>),
    );
    await save(catalog); // 不删除或改写旧键，迁移失败不发布成功状态。
    return catalog;
  }

  @override
  Future<void> save(DrawingPresetCatalog catalog) async {
    final prefs = await SharedPreferences.getInstance();
    if (!await saveCloudPreference(
      prefs,
      storageKey,
      jsonEncode(catalog.toJson()),
    )) {
      throw StateError('绘图预设未能保存，请重试');
    }
  }
}

final drawingPresetStoreProvider = Provider<DrawingPresetStore>(
  (ref) => PreferencesDrawingPresetStore(),
);
final drawingPresetCatalogProvider =
    AsyncNotifierProvider<DrawingPresetCatalogNotifier, DrawingPresetCatalog>(
      DrawingPresetCatalogNotifier.new,
    );

class DrawingPresetCatalogNotifier extends AsyncNotifier<DrawingPresetCatalog> {
  Future<void> _writes = Future.value();

  @override
  Future<DrawingPresetCatalog> build() =>
      ref.read(drawingPresetStoreProvider).load();

  Future<void> _update(
    FutureOr<DrawingPresetCatalog> Function(DrawingPresetCatalog) change,
  ) {
    final operation = _writes.then((_) async {
      final current = await future;
      final next = await change(current);
      await ref.read(drawingPresetStoreProvider).save(next);
      state = AsyncData(next);
    });
    _writes = operation.then((_) {}, onError: (Object _, StackTrace __) {});
    return operation;
  }

  Future<void> savePreset(DrawingPreset preset) =>
      _update((catalog) => catalog.upsert(preset));
  Future<void> setDefault(String id) =>
      _update((catalog) => catalog.withDefault(id));

  Future<void> deletePreset(String id) => _update((catalog) async {
    catalog.require(id);
    if (id == catalog.defaultPresetId) {
      throw StateError('这是默认绘图预设，请先将其他预设设为默认');
    }
    final roles = await ref.read(conversationsProvider.future);
    final references = <String>[];
    for (final role in roles) {
      final parts = PersonaPromptCodec.parse(role.personaPrompt);
      // 使用同一解析规则识别旧组合绑定，但不触发懒迁移写入。
      try {
        if (catalog.resolve(parts).id == id) {
          references.add(role.displayName);
        }
      } on StateError {
        // 已失效的其他绑定不引用当前有效预设。
      }
    }
    if (references.isNotEmpty) {
      throw StateError('角色「${references.join('、')}」仍在使用此预设，请先在角色卡更换绘图配置包');
    }
    return DrawingPresetCatalog(
      presets: catalog.presets.where((preset) => preset.id != id).toList(),
      defaultPresetId: catalog.defaultPresetId,
      legacyConfig: catalog.legacyConfig,
    );
  });

  Future<DrawingPreset> resolveForPersona(String persona) async {
    final parts = PersonaPromptCodec.parse(persona);
    final catalog = await future;
    final preset = catalog.resolve(parts);
    if (!catalog.presets.any((p) => p.id == preset.id)) {
      await _update(
        (current) => current.presets.any((p) => p.id == preset.id)
            ? current
            : current.upsert(preset),
      );
    }
    return (await future).require(preset.id);
  }
}

final roleDrawingPresetProvider = FutureProvider.autoDispose
    .family<DrawingPreset, String>((ref, persona) async {
      // 订阅目录变化；迁移写入去重，重建不会反复写盘。
      await ref.watch(drawingPresetCatalogProvider.future);
      return ref
          .read(drawingPresetCatalogProvider.notifier)
          .resolveForPersona(persona);
    });
