/// DrawingPromptSection - 角色编辑页：专属绘图提示区块
///
/// 三部分组成：
/// 1) 工具预设提示词（来自绘图插件预设列表，可角色绑定）
/// 2) 画风（画师串，来自绘图插件预设列表，可角色绑定）
/// 3) 个性化提示（角色自定义补充）
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/plugins/plugin_providers.dart';
import '../../../../ui/shared/effects/frosted_glass_card.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/theme/tokens.dart';
import 'edit_section_title.dart';

class DrawingPromptSection extends ConsumerWidget {
  final TextEditingController customDrawingPromptCtrl;
  final bool followsGlobalArtistPreset;
  final String selectedToolPresetName;
  final String? selectedArtistPresetName;
  final ValueChanged<String> onToolPresetChanged;
  final VoidCallback onArtistPresetFollowGlobal;
  final VoidCallback onArtistPresetDisable;
  final ValueChanged<String> onArtistPresetSelected;
  final VoidCallback onEdit;

  const DrawingPromptSection({
    super.key,
    required this.customDrawingPromptCtrl,
    required this.followsGlobalArtistPreset,
    required this.selectedToolPresetName,
    required this.selectedArtistPresetName,
    required this.onToolPresetChanged,
    required this.onArtistPresetFollowGlobal,
    required this.onArtistPresetDisable,
    required this.onArtistPresetSelected,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.moeColors;
    final imageConfig = ref.watch(imagePluginConfigProvider);
    final toolPresets = imageConfig.systemPromptPresets;
    final artistPresets = imageConfig.artistPresets;
    final selectedToolPreset = toolPresets
        .where((preset) => preset.name == selectedToolPresetName)
        .firstOrNull;
    final selectedArtistPreset = artistPresets
        .where((preset) => preset.name == selectedArtistPresetName)
        .firstOrNull;
    final globalArtistPreset = imageConfig.selectedArtistPreset;
    final personalPrompt = customDrawingPromptCtrl.text.trim();
    final hasPersonalPrompt = personalPrompt.isNotEmpty;
    final artistPresetDisabled =
        !followsGlobalArtistPreset && selectedArtistPresetName == null;
    final artistSummary = () {
      if (followsGlobalArtistPreset) {
        final globalName = globalArtistPreset?.name ?? '全局未使用画师串';
        return '当前：跟随全局（$globalName）';
      }
      if (artistPresetDisabled) {
        return '当前：角色专属不使用画师串';
      }
      return '当前：角色专属 ${selectedArtistPreset?.name ?? '未命名画师串'}';
    }();

    return FrostedGlassContainer(
      borderRadius: 16,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Expanded(
                child: EditSectionTitle(
                  icon: Icons.draw_outlined,
                  title: '专属绘图提示',
                  subtitle: '工具预设 + 画风 + 个性化补充',
                ),
              ),
              const SizedBox(width: 12),
              GestureDetector(
                onTap: onEdit,
                child: Container(
                  width: 32,
                  height: 32,
                  decoration: MoeG2Decoration(
                    radius: 8,
                    color: colors.primary.withValues(alpha: 0.1),
                  ),
                  child: Icon(
                    Icons.edit_outlined,
                    size: 16,
                    color: colors.primary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _InfoBlock(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.settings_outlined,
                        size: 14, color: colors.muted),
                    const SizedBox(width: 6),
                    Text(
                      '工具预设提示词：',
                      style: TextStyle(
                        fontSize: 13,
                        color: colors.muted,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (toolPresets.isEmpty)
                  Text(
                    '暂无可用预设',
                    style: TextStyle(
                      fontSize: 13,
                      color: colors.muted,
                    ),
                  )
                else
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final preset in toolPresets)
                        _SelectChip(
                          label: preset.name,
                          selected: preset.name == selectedToolPresetName,
                          onTap: () => onToolPresetChanged(preset.name),
                        ),
                    ],
                  ),
                if (selectedToolPreset != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    '当前：${selectedToolPreset.name}',
                    style: TextStyle(
                      fontSize: 12,
                      color: colors.text.withValues(alpha: 0.8),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    imageConfig.buildPresetPreview(selectedToolPreset, max: 52),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: colors.text.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 10),
          _InfoBlock(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.palette_outlined, size: 14, color: colors.muted),
                    const SizedBox(width: 6),
                    Text(
                      '画风（画师串）：',
                      style: TextStyle(
                        fontSize: 13,
                        color: colors.muted,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _SelectChip(
                      label: '跟随全局',
                      selected: followsGlobalArtistPreset,
                      onTap: onArtistPresetFollowGlobal,
                    ),
                    _SelectChip(
                      label: '不使用',
                      selected: artistPresetDisabled,
                      onTap: onArtistPresetDisable,
                    ),
                    for (final preset in artistPresets)
                      _SelectChip(
                        label: preset.name,
                        selected: !followsGlobalArtistPreset &&
                            preset.name == selectedArtistPresetName,
                        onTap: () => onArtistPresetSelected(preset.name),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  artistSummary,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.text.withValues(alpha: 0.8),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          _InfoBlock(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.person_outline, size: 14, color: colors.muted),
                    const SizedBox(width: 6),
                    Text(
                      '个性化提示：',
                      style: TextStyle(
                        fontSize: 13,
                        color: colors.muted,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  hasPersonalPrompt ? personalPrompt : '暂无个性化绘图提示',
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.4,
                    color: hasPersonalPrompt
                        ? colors.text.withValues(alpha: 0.9)
                        : colors.muted,
                  ),
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoBlock extends StatelessWidget {
  final Widget child;

  const _InfoBlock({required this.child});

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    return MoeG2ClipRRect(
      radius: 12,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        color: colors.surfaceAlt.withValues(alpha: 0.35),
        child: child,
      ),
    );
  }
}

class _SelectChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _SelectChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    return GestureDetector(
      onTap: onTap,
      child: MoeG2ClipRRect(
        radius: 10,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          color: selected
              ? colors.primary.withValues(alpha: 0.16)
              : colors.surfaceAlt.withValues(alpha: 0.45),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight:
                  selected ? MoeFontWeights.emphasis : MoeFontWeights.normal,
              color: selected
                  ? colors.primary
                  : colors.text.withValues(alpha: 0.85),
            ),
          ),
        ),
      ),
    );
  }
}
