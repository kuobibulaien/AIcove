import '../../content_tags/domain/tag_presentation.dart';
import 'silly_tavern_preset.dart';

/// 一套酒馆插件预设沿用 recipeId，内含 prompt、regex 和世界书；不复制角色数据。
class TavernPluginSettings {
  final bool enabled;
  final String? defaultPresetId;
  const TavernPluginSettings({this.enabled = true, this.defaultPresetId});

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'defaultPresetId': defaultPresetId,
  };
}

abstract interface class TavernCompatibilityPort {
  Future<TavernPluginSettings> loadPluginSettings();
  Future<void> savePluginSettings(TavernPluginSettings settings);
  Future<SillyTavernPreset?> resolvePreset(String? explicitId);
  Future<void> setPromptEnabled(String presetId, String promptId, bool enabled);
  Future<void> setRegexEnabled(String presetId, String scriptId, bool enabled);
  Future<void> importRegex(String presetId, String source);
  Future<void> importWorldBook(String presetId, String source, String fileName);
  Future<void> setWorldBookEnabled(
    String presetId,
    String bookId,
    bool enabled,
  );
  Future<void> setWorldEntryEnabled(
    String presetId,
    String bookId,
    String entryId,
    bool enabled,
  );

  /// 用户指定某个语义标签的界面呈现；[presentation] 为 null 时恢复自动推断。
  Future<void> setTagPresentation(
    String presetId,
    String tagName,
    TagPresentation? presentation,
  );
}
