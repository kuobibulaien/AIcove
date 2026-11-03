/// RolePromptSection - 角色编辑页：提示词
///
/// 两行入口：
/// 1. 角色提示词（AIcove酱显示为只读的「系统提示词」）
/// 2. 附加提示词（补充设定与生图偏好，进入独立页面编辑）
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/plugins/image/drawing_preset_provider.dart';
import '../../../../features/plugins/prompts/plugin_prompt_resolution.dart';
import '../../../../features/plugins/prompts/prompt_pack.dart';
import '../../../../features/settings/app_settings.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/theme/tokens.dart';

class RolePromptSection extends StatelessWidget {
  final VoidCallback onEditRolePrompt;
  final VoidCallback onEditExtraPrompt;

  /// 非空时首行显示灰色的「系统提示词（只读）」。
  final VoidCallback? onViewSystemPrompt;

  const RolePromptSection({
    super.key,
    required this.onEditRolePrompt,
    required this.onEditExtraPrompt,
    this.onViewSystemPrompt,
  });

  @override
  Widget build(BuildContext context) {
    final onViewSystem = onViewSystemPrompt;
    return MoeSettingsGroup(
      margin: EdgeInsets.zero,
      children: [
        if (onViewSystem != null)
          MoeSettingsRow(
            label: '系统提示词',
            labelColor: context.moeColors.muted,
            onTap: onViewSystem,
          )
        else
          MoeSettingsRow(
            label: '角色提示词',
            onTap: onEditRolePrompt,
          ),
        MoeSettingsRow(
          label: '附加提示词',
          showDivider: false,
          onTap: onEditExtraPrompt,
        ),
      ],
    );
  }
}

/// 解析角色当前绘图预设对应的渠道格式（`novelai` / `comfyui` / `openai`）。
String resolveRoleDrawingFormat({
  required WidgetRef ref,
  required String drawingPersonaPrompt,
}) {
  final preset =
      ref.watch(roleDrawingPresetProvider(drawingPersonaPrompt)).valueOrNull ??
      ref.watch(drawingPresetCatalogProvider).valueOrNull?.let(
            (c) => c.presets.where((p) => p.id == c.defaultPresetId).firstOrNull,
          );
  final settings = ref.watch(appSettingsProvider).valueOrNull;
  final selectedProviderId = preset?.config.selectedProviderId?.trim() ?? '';
  final provider = settings?.providers
      .where((p) => p.id == selectedProviderId)
      .firstOrNull;
  return selectedProviderId.isEmpty
      ? 'openai'
      : imagePromptFormat(
          provider?.id ?? selectedProviderId,
          provider?.customConfig ?? const {},
        );
}

/// 角色未指定生图方案时，按角色当前绘图预设自动匹配的默认方案。
PromptPack resolveDefaultRoleDrawingPack({
  required WidgetRef ref,
  required PromptPackLibrary library,
  required String drawingPersonaPrompt,
}) {
  final preset =
      ref.watch(roleDrawingPresetProvider(drawingPersonaPrompt)).valueOrNull ??
      ref.watch(drawingPresetCatalogProvider).valueOrNull?.let(
            (c) => c.presets.where((p) => p.id == c.defaultPresetId).firstOrNull,
          );
  final presetPackId = preset?.prompts.packId?.trim();
  if (presetPackId != null && presetPackId.isNotEmpty) {
    final presetPack = library.byId(presetPackId);
    if (presetPack != null) return presetPack;
  }
  final settings = ref.watch(appSettingsProvider).valueOrNull;
  final format = resolveRoleDrawingFormat(
    ref: ref,
    drawingPersonaPrompt: drawingPersonaPrompt,
  );
  final selectedModelId = preset?.config.selectedModelId;
  final model = selectedModelId == null
      ? ''
      : (settings != null
            ? settings.getRawModelId(selectedModelId)
            : selectedModelId);
  return library.autoMatch('image', format, model);
}

extension _LetExt<T extends Object> on T {
  R let<R>(R Function(T) block) => block(this);
}
