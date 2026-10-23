import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/chat/domain/persona_prompt_codec.dart';
import '../../../../features/plugins/image/drawing_preset_provider.dart';
import '../../../../features/chat/id_gen.dart';
import '../../../shared/animations/parallax_slide_page_route.dart';
import '../../../shared/widgets/index.dart';
import '../pages/drawing_preset_editor_page.dart';

/// 绘图配置包快速选择弹窗。
///
/// 角色卡与聊天头部共用同一份选择逻辑：列出全部配置包，首项为「跟随默认」。
/// [personaPrompt] 用于回显当前绑定，[onSelected] 收到 null 表示改为跟随默认。
/// 给了 [roleName] 时多一项「为这个角色新建」：复制当前生效的配置包（含提示词
/// 绑定与专属节），只绑给这个角色，并打开编辑页（ADR0092：预设默认一对一）。
Future<void> showDrawingPresetPicker({
  required BuildContext context,
  required WidgetRef ref,
  required String personaPrompt,
  required ValueChanged<String?> onSelected,
  String? roleName,
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
          itemCount: catalog.presets.length + (roleName == null ? 1 : 2),
          itemBuilder: (ctx, index) {
            if (roleName != null) {
              if (index == 0) {
                return MoeListTile(
                  leading: const Icon(Icons.add),
                  title: const Text('为这个角色新建'),
                  subtitle: const Text('复制当前配置包，只给这个角色用'),
                  onTap: () async {
                    Navigator.pop(ctx);
                    await _createForRole(
                      context,
                      ref,
                      personaPrompt,
                      roleName,
                      onSelected,
                    );
                  },
                );
              }
              index -= 1;
            }
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

Future<void> _createForRole(
  BuildContext context,
  WidgetRef ref,
  String personaPrompt,
  String roleName,
  ValueChanged<String?> onSelected,
) async {
  try {
    final notifier = ref.read(drawingPresetCatalogProvider.notifier);
    final current = await notifier.resolveForPersona(personaPrompt);
    final name = roleName.trim().isEmpty ? '新角色' : roleName.trim();
    final copy = current.copyWith(
      id: genId('drawing'),
      name: '$name · ${current.name}',
    );
    await notifier.savePreset(copy);
    onSelected(copy.id);
    if (!context.mounted) return;
    await Navigator.of(context).push(
      ParallaxSlidePageRoute(page: DrawingPresetEditorPage(preset: copy)),
    );
  } catch (e) {
    if (context.mounted) MoeToast.error(context, '新建失败：$e');
  }
}
