/// PluginVoiceSection - 角色编辑页：插件选择 + 音色绑定卡
///
/// 从 ContactEditPage 拆分，负责插件启停切换和音色绑定选择。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/plugins/plugin_providers.dart';
import '../../../../features/plugins/tts/tts_config.dart';
import '../../../../features/settings/app_settings.dart';
import '../../../../ui/features/settings/pages/chat_plugin_settings_page.dart';
import '../../../../ui/shared/effects/frosted_glass_card.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/theme/tokens.dart';
import 'edit_section_title.dart';

class PluginVoiceSection extends ConsumerWidget {
  final Set<String> selectedPluginIds;
  final String? boundVoiceId;
  final List<VoicePreset> voicePresets;
  final ValueChanged<Set<String>> onPluginIdsChanged;
  final ValueChanged<String?> onVoiceChanged;

  const PluginVoiceSection({
    super.key,
    required this.selectedPluginIds,
    required this.boundVoiceId,
    required this.voicePresets,
    required this.onPluginIdsChanged,
    required this.onVoiceChanged,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.moeColors;

    return FrostedGlassContainer(
      borderRadius: 16,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ---- 插件区域 ----
          EditSectionTitle(
            icon: Icons.extension_outlined,
            title: '插件',
            subtitle: '默认全部开启，可按角色单独调整',
          ),
          const SizedBox(height: 8),
          MoeG2ClipRRect(
            radius: 12,
            child: Material(
              color: colors.surfaceAlt.withValues(alpha: 0.35),
              child: InkWell(
                onTap: () => _showPluginPicker(context, ref),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  child: Row(
                    children: [
                      Icon(Icons.extension_outlined,
                          color: colors.primary, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _pluginSummaryText(),
                          style: TextStyle(fontSize: 14, color: colors.text),
                        ),
                      ),
                      Icon(Icons.chevron_right, color: colors.muted),
                    ],
                  ),
                ),
              ),
            ),
          ),

          const SizedBox(height: 16),
          Divider(height: 1, color: colors.borderLight.withValues(alpha: 0.35)),
          const SizedBox(height: 16),

          // ---- 音色区域 ----
          EditSectionTitle(
            icon: Icons.record_voice_over_outlined,
            title: '绑定音色',
            subtitle: '可为当前角色绑定独立音色',
          ),
          const SizedBox(height: 8),
          MoeG2ClipRRect(
            radius: 12,
            child: Material(
              color: colors.surfaceAlt.withValues(alpha: 0.35),
              child: InkWell(
                onTap: () => _showVoicePicker(context),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  child: Row(
                    children: [
                      Icon(Icons.graphic_eq, color: colors.primary, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _voiceDisplayName(),
                          style: TextStyle(fontSize: 14, color: colors.text),
                        ),
                      ),
                      if (boundVoiceId != null)
                        IconButton(
                          icon:
                              Icon(Icons.close, size: 18, color: colors.muted),
                          onPressed: () => onVoiceChanged(null),
                          tooltip: '清除绑定',
                        ),
                      Icon(Icons.chevron_right, color: colors.muted),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ==================== 插件摘要 ====================

  String _pluginSummaryText() {
    final total = conversationScopedChatPluginItems.length;
    final selected = selectedPluginIds
        .where((id) => conversationScopedChatPluginItems.any((p) => p.id == id))
        .length;
    if (selected == total) return '已启用全部 $total 个插件';
    if (selected == 0) return '未启用任何插件';
    return '已启用 $selected / $total 个插件';
  }

  // ==================== 插件选择弹窗 ====================

  Future<void> _showPluginPicker(BuildContext context, WidgetRef ref) async {
    final sheetSelectedPluginIds = Set<String>.from(selectedPluginIds);

    void updateSheetSelection(
      StateSetter setSheetState,
      String pluginId,
      bool value,
    ) {
      setSheetState(() {
        if (value) {
          sheetSelectedPluginIds.add(pluginId);
        } else {
          sheetSelectedPluginIds.remove(pluginId);
        }
      });
      onPluginIdsChanged(Set<String>.from(sheetSelectedPluginIds));
    }

    await showMoeBottomSheet(
      context: context,
      title: '选择插件',
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            final colors = ctx.moeColors;
            return ListView.builder(
              shrinkWrap: true,
              itemCount: conversationScopedChatPluginItems.length,
              itemBuilder: (_, index) {
                final item = conversationScopedChatPluginItems[index];
                final selected = sheetSelectedPluginIds.contains(item.id);
                final globallyEnabled = _isPluginGloballyEnabled(ref, item.id);

                return ListTile(
                  leading: Icon(
                    item.icon,
                    size: 20,
                    color: globallyEnabled ? colors.primary : colors.muted,
                  ),
                  title: Text(
                    item.name,
                    style: TextStyle(
                      color: globallyEnabled ? colors.text : colors.muted,
                    ),
                  ),
                  trailing: Switch.adaptive(
                    value: selected,
                    activeColor: colors.primary,
                    onChanged: globallyEnabled
                        ? (value) {
                            updateSheetSelection(
                              setSheetState,
                              item.id,
                              value,
                            );
                          }
                        : null,
                  ),
                  onTap: globallyEnabled
                      ? () {
                          updateSheetSelection(
                            setSheetState,
                            item.id,
                            !selected,
                          );
                        }
                      : null,
                );
              },
            );
          },
        );
      },
    );
  }

  bool _isPluginGloballyEnabled(WidgetRef ref, String pluginId) {
    switch (pluginId) {
      case 'memory':
        return ref.read(memoryPluginConfigProvider).enabled;
      case 'tts':
        return ref.read(ttsPluginConfigProvider).enabled;
      case 'trigger':
        return ref.read(appSettingsProvider).value?.autoReplySettings.enabled ??
            false;
      case 'sticker':
        return ref.read(stickerPluginConfigProvider).enabled;
      case 'image':
        return ref.read(appSettingsProvider).value?.imageGenerationEnabled ??
            true;
      case 'time_awareness':
        return ref.read(timeAwarenessPluginConfigProvider).enabled;
      default:
        return true;
    }
  }

  // ==================== 音色选择弹窗 ====================

  Future<void> _showVoicePicker(BuildContext context) async {
    const followGlobalToken = '__follow_global__';

    final selected = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        final colors = context.moeColors;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(Icons.sync, color: colors.primary),
                title: const Text('跟随全局音色'),
                subtitle: const Text('使用当前聊天插件里选择的音色'),
                trailing: boundVoiceId == null
                    ? Icon(Icons.check, color: colors.primary)
                    : null,
                onTap: () => Navigator.of(context).pop(followGlobalToken),
              ),
              const Divider(height: 1),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: voicePresets.length,
                  itemBuilder: (context, index) {
                    final preset = voicePresets[index];
                    final isSelected = boundVoiceId == preset.id;
                    return ListTile(
                      leading: const Icon(Icons.graphic_eq),
                      title: Text(preset.name),
                      subtitle: Text(preset.providerDisplayName),
                      trailing: isSelected
                          ? Icon(Icons.check, color: colors.primary)
                          : null,
                      onTap: () => Navigator.of(context).pop(preset.id),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );

    if (selected == null) return;
    if (selected == followGlobalToken) {
      onVoiceChanged(null);
    } else {
      onVoiceChanged(selected);
    }
  }

  String _voiceDisplayName() {
    final id = boundVoiceId;
    if (id == null || id.isEmpty) return '跟随全局音色';

    for (final preset in voicePresets) {
      if (preset.id == id) return preset.name;
    }

    return '已绑定自定义音色';
  }
}
