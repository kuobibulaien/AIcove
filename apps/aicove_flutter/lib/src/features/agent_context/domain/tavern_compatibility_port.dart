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

/// 用户在 AIcove 里自己添加的提示词条目的标识前缀；只有这类条目可以删除。
const String kUserPromptIdPrefix = 'aicove_';

abstract interface class TavernCompatibilityPort {
  Future<TavernPluginSettings> loadPluginSettings();
  Future<void> savePluginSettings(TavernPluginSettings settings);
  Future<SillyTavernPreset?> resolvePreset(String? explicitId);
  Future<void> setPromptEnabled(String presetId, String promptId, bool enabled);

  /// 新增或修改一条普通提示词（占位条目不可改）。新条目排在聊天记录之前并默认开启。
  Future<void> savePrompt(
    String presetId, {
    required String identifier,
    required String name,
    required String role,
    required String content,
  });

  /// 删除一条用户自己添加的提示词（标识以 [kUserPromptIdPrefix] 开头），
  /// 连同它在各组顺序里的位置和开关；导入来的条目只能关掉，不能删。
  Future<void> deletePrompt(String presetId, String identifier);
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

  /// 设置这套预设的 {{user}} 是否替换为用户名称。
  Future<void> setUserNameMacroEnabled(String presetId, bool enabled);

  /// 设置这套预设是否启用 MVU 变量（ADR0071）。
  Future<void> setMvuEnabled(String presetId, bool enabled);

  /// 改写预设原文里的 temperature；null 时删除该字段，改用模型自己的设置。
  Future<void> setTemperature(String presetId, double? value);

  /// 改写预设原文里的 top_p；null 时删除该字段，改用模型自己的设置。
  Future<void> setTopP(String presetId, double? value);

  /// 用户指定某个语义标签的界面呈现；[presentation] 为 null 时恢复自动推断。
  Future<void> setTagPresentation(
    String presetId,
    String tagName,
    TagPresentation? presentation,
  );
}
