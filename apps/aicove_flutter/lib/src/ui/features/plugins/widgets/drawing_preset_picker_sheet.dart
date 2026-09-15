import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/chat/domain/persona_prompt_codec.dart';
import '../../../../features/plugins/image/drawing_preset_provider.dart';
import '../../../shared/widgets/index.dart';

/// 绘图配置包快速选择弹窗。
///
/// 角色卡与聊天头部共用同一份选择逻辑：列出全部配置包，首项为「跟随默认」。
/// [personaPrompt] 用于回显当前绑定，[onSelected] 收到 null 表示改为跟随默认。
Future<void> showDrawingPresetPicker({
  required BuildContext context,
  required WidgetRef ref,
  required String personaPrompt,
  required ValueChanged<String?> onSelected,
}) {
  final parts = PersonaPromptCodec.parse(personaPrompt);
  final followsDefault = (parts.drawingPresetId?.isEmpty ?? true) &&
      (parts.drawingToolPresetName?.isEmpty ?? true) &&
      (parts.drawingArtistPresetName?.isEmpty ?? true);
  final boundId = parts.drawingPresetId ??
      ref.read(roleDrawingPresetProvider(personaPrompt)).valueOrNull?.id;
  return showMoeBottomSheet<void>(
    context: context,
    title: '选择绘图配置包',
    showCloseButton: true,
    builder: (ctx) => Consumer(builder: (ctx, sheetRef, _) {
      final catalog = sheetRef.watch(drawingPresetCatalogProvider);
      return catalog.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, stack) =>
            const MoeEmptyState(title: '配置包读取失败', description: '请返回管理页检查配置包'),
        data: (catalog) => ListView.builder(
          shrinkWrap: true,
          itemCount: catalog.presets.length + 1,
          itemBuilder: (ctx, index) {
            final preset = index == 0 ? null : catalog.presets[index - 1];
            final isSelected = preset == null
                ? followsDefault
                : !followsDefault && boundId == preset.id;
            return MoeListTile(
              title: Text(preset?.name ?? '跟随默认绘图配置包'),
              subtitle: Text(preset == null
                  ? catalog.require(catalog.defaultPresetId).name
                  : preset.config.selectedModelId ?? '待配置渠道与模型'),
              trailing: isSelected ? const Icon(Icons.check) : null,
              onTap: () {
                onSelected(preset?.id);
                Navigator.pop(ctx);
              },
            );
          },
        ),
      );
    }),
  );
}
