library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../../../../features/plugins/plugin_providers.dart';
import '../../../../features/plugins/tts/providers/tts_voice_provider.dart';
import '../../../../features/plugins/tts/tts_config.dart';
import '../../../../features/plugins/tts/tts_provider_context.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/theme/tokens.dart';
import 'tts_voice_catalog_sheet.dart';
import 'tts_voice_preset_editor_sheet.dart';

class TtsVoicePresetSection extends StatelessWidget {
  final TtsConfig config;
  final TtsPluginConfigNotifier notifier;
  final TtsProviderContext providerContext;

  const TtsVoicePresetSection({
    super.key,
    required this.config,
    required this.notifier,
    required this.providerContext,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final presets = config.voicePresets;
    final selectedId = config.selectedVoicePresetId;
    final selectedModelId = config.selectedModelId;
    return MoeSettingsGroup(
      title: '音色列表',
      margin: EdgeInsets.zero,
      children: [
        ..._buildCapabilityNotices(context, providerContext.capabilities),
        if (selectedModelId == null)
          _buildHintRow(
            context,
            icon: Icons.warning_amber_outlined,
            text: '请先选择 TTS 模型',
          )
        else if (presets.isEmpty)
          _buildHintRow(
            context,
            icon: Icons.info_outline,
            text: '暂无音色，点击「获取」导入渠道音色，或点击「自定义」创建自己的音色',
          )
        else
          ...presets.asMap().entries.map((entry) {
            final index = entry.key;
            final preset = entry.value;
            final isSelected = preset.id == selectedId;
            final isLast = index == presets.length - 1;
            final isAvailable = preset.canUseWithModel(
              selectedModelId,
              providerId: providerContext.voiceProviderId,
            );

            return MoeSettingsRow(
              icon: isSelected ? Icons.check_circle : Icons.mic,
              iconColor: isSelected
                  ? colors.primary
                  : (isAvailable ? null : colors.muted),
              label: preset.name,
              subtitle: _buildVoicePresetSubtitle(preset, isAvailable),
              trailingType: MoeSettingsRowTrailing.custom,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!preset.isBuiltIn)
                    GestureDetector(
                      onTap: () => _confirmDeleteLocalVoice(
                        context,
                        preset,
                        notifier,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Icon(
                          Icons.delete_outline,
                          size: 20,
                          color: colors.muted,
                        ),
                      ),
                    ),
                  Icon(Icons.chevron_right, size: 20, color: colors.muted),
                ],
              ),
              enabled: isAvailable,
              onTap: isAvailable
                  ? () => _onVoicePresetTap(context, preset, notifier)
                  : () => MoeToast.warning(context, '该音色不适用于当前选中的模型'),
              showDivider: !isLast,
            );
          }),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: MoeSecondaryButton(
                  label: '获取',
                  icon: Icons.cloud_download_outlined,
                  enabled: selectedModelId != null &&
                      providerContext.hasVoiceProvider,
                  onPressed: selectedModelId == null ||
                          !providerContext.hasVoiceProvider
                      ? null
                      : () => showTtsVoiceCatalogSheet(
                            context: context,
                            config: config,
                            providerContext: providerContext,
                            onVoiceSelected: (voice) async {
                              await notifier.addVoicePreset(voice);
                              await notifier.selectVoicePreset(voice.id);
                              if (!context.mounted) return;
                              MoeToast.success(context, '已添加「${voice.name}」');
                            },
                          ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: MoePrimaryButton(
                  label: '自定义',
                  icon: Icons.add,
                  enabled: selectedModelId != null,
                  onPressed: selectedModelId == null
                      ? null
                      : () => showTtsVoicePresetEditorSheet(
                            context: context,
                            notifier: notifier,
                            providerContext: providerContext,
                            colors: colors,
                          ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  List<Widget> _buildCapabilityNotices(
    BuildContext context,
    TtsCapabilities? capabilities,
  ) {
    final colors = context.moeColors;
    final widgets = <Widget>[];

    if (providerContext.hasConfiguredProvider &&
        !providerContext.hasVoiceProvider) {
      widgets.add(
        _buildBanner(
          context,
          color: colors.muted,
          icon: Icons.info_outline,
          text: '当前渠道暂未接入专门的音色适配器，暂时只能手动维护音色素材',
        ),
      );
    }

    if (capabilities?.needsApproval == true) {
      widgets.add(
        _buildBanner(
          context,
          color: Colors.orange,
          icon: Icons.schedule_outlined,
          text: '当前渠道创建音色后需要审核，审核通过后才可正式使用',
        ),
      );
    }

    if (capabilities?.hasExpirationPolicy == true &&
        capabilities?.expirationDescription != null) {
      widgets.add(
        _buildBanner(
          context,
          color: colors.primary,
          icon: Icons.timelapse_outlined,
          text: capabilities!.expirationDescription!,
        ),
      );
    }

    if (!providerContext.hasApiKey && providerContext.hasVoiceProvider) {
      widgets.add(
        _buildBanner(
          context,
          color: colors.muted,
          icon: Icons.key_off_outlined,
          text: '当前渠道还没填 API Key，暂时只能先保存本地音色素材',
        ),
      );
    }

    return widgets;
  }

  Widget _buildBanner(
    BuildContext context, {
    required Color color,
    required IconData icon,
    required String text,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: MoeG2Decoration(
          radius: 8,
          color: color.withValues(alpha: 0.08),
          border: Border.all(color: color.withValues(alpha: 0.18)),
        ),
        child: Row(
          children: [
            Icon(icon, color: color, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                style: TextStyle(color: color, fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHintRow(
    BuildContext context, {
    required IconData icon,
    required String text,
  }) {
    final colors = context.moeColors;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Icon(icon, color: colors.muted, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: colors.muted, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  String _buildVoicePresetSubtitle(VoicePreset preset, bool isAvailable) {
    final parts = <String>[];
    switch (preset.sourceType) {
      case VoiceSourceType.local:
        parts.add('本地文件');
        break;
      case VoiceSourceType.url:
        parts.add('直链');
        break;
      case VoiceSourceType.preset:
        parts.add('预置');
        break;
    }
    if (preset.isBuiltIn) {
      parts.add('推荐');
    }
    if (preset.aliyunVoiceStatus != null &&
        preset.aliyunVoiceStatus!.isNotEmpty &&
        preset.aliyunVoiceStatus != 'OK') {
      parts.add(preset.aliyunVoiceStatus!);
    }
    if (!isAvailable) {
      parts.add('不可用');
    }
    return parts.join(' · ');
  }

  void _onVoicePresetTap(
    BuildContext context,
    VoicePreset preset,
    TtsPluginConfigNotifier notifier,
  ) {
    final isSelected = preset.id == config.selectedVoicePresetId;
    if (isSelected) {
      _showVoicePresetActions(context, preset, notifier);
      return;
    }
    notifier.selectVoicePreset(preset.id);
    MoeToast.success(context, '已选择「${preset.name}」');
  }

  void _showVoicePresetActions(
    BuildContext context,
    VoicePreset preset,
    TtsPluginConfigNotifier notifier,
  ) {
    final colors = context.moeColors;
    final isSelected = preset.id == config.selectedVoicePresetId;

    showMoeActionSheet(
      context: context,
      title: preset.name,
      description: preset.source,
      actions: [
        if (!isSelected)
          MoeSheetAction(
            icon: Icons.check_circle_outline,
            label: '使用此音色',
            onTap: () {
              notifier.selectVoicePreset(preset.id);
              MoeToast.success(context, '已选择 ${preset.name}');
            },
          ),
        if (isSelected)
          MoeSheetAction(
            icon: Icons.cancel_outlined,
            label: '取消选择',
            onTap: () {
              notifier.selectVoicePreset(null);
              MoeToast.info(context, '已取消选择');
            },
          ),
        MoeSheetAction(
          icon: Icons.visibility,
          label: '查看详情',
          onTap: () => showTtsVoicePresetEditorSheet(
            context: context,
            notifier: notifier,
            providerContext: providerContext,
            colors: colors,
            preset: preset,
          ),
        ),
        if (!preset.isBuiltIn)
          MoeSheetAction(
            icon: Icons.delete_outline,
            label: '删除',
            isDestructive: true,
            onTap: () => _confirmDeleteLocalVoice(context, preset, notifier),
          ),
      ],
    );
  }

  void _confirmDeleteLocalVoice(
    BuildContext context,
    VoicePreset preset,
    TtsPluginConfigNotifier notifier,
  ) {
    if (preset.isBuiltIn) {
      MoeToast.warning(context, '内置音色不能删除');
      return;
    }

    showMeoTalkDialog(
      context: context,
      title: '删除音色',
      content: Text('确定要删除「${preset.name}」吗？'),
      confirmText: '删除',
      isDanger: true,
    ).then((confirmed) async {
      if (confirmed != true) return;
      if (preset.localAudioPath != null && preset.localAudioPath!.isNotEmpty) {
        try {
          File(preset.localAudioPath!).deleteSync();
        } catch (_) {}
      }
      await notifier.deleteVoicePreset(preset.id);
      if (!context.mounted) return;
      MoeToast.success(context, '已删除');
    });
  }
}
