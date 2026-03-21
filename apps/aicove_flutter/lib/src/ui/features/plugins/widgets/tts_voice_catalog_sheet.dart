library;

import 'package:flutter/material.dart';

import '../../../../features/plugins/tts/providers/tts_voice_provider.dart';
import '../../../../features/plugins/tts/tts_config.dart';
import '../../../../features/plugins/tts/tts_provider_context.dart';
import '../../../../features/plugins/tts/tts_voice_catalog_service.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/theme/tokens.dart';

Future<void> showTtsVoiceCatalogSheet({
  required BuildContext context,
  required TtsConfig config,
  required TtsProviderContext providerContext,
  required void Function(VoicePreset voice) onVoiceSelected,
}) {
  final title = providerContext.providerDisplayName == null
      ? '获取音色'
      : '获取 ${providerContext.providerDisplayName} 音色';

  return showMoeBottomSheet(
    context: context,
    title: title,
    builder: (sheetContext) => _TtsVoiceCatalogSheetContent(
      parentContext: context,
      config: config,
      providerContext: providerContext,
      onVoiceSelected: onVoiceSelected,
    ),
  );
}

class _TtsVoiceCatalogSheetContent extends StatefulWidget {
  final BuildContext parentContext;
  final TtsConfig config;
  final TtsProviderContext providerContext;
  final void Function(VoicePreset voice) onVoiceSelected;

  const _TtsVoiceCatalogSheetContent({
    required this.parentContext,
    required this.config,
    required this.providerContext,
    required this.onVoiceSelected,
  });

  @override
  State<_TtsVoiceCatalogSheetContent> createState() =>
      _TtsVoiceCatalogSheetContentState();
}

class _TtsVoiceCatalogSheetContentState
    extends State<_TtsVoiceCatalogSheetContent> {
  bool _loading = true;
  String? _error;
  VoiceListResult? _result;
  String? _deletingVoiceId;

  @override
  void initState() {
    super.initState();
    _loadVoices();
  }

  Future<void> _loadVoices() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final result = await TtsVoiceCatalogService.listVoices(
        widget.providerContext,
      );
      if (!mounted) return;
      setState(() {
        _result = result;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is TtsProviderException ? e.message : '加载失败: $e';
        _loading = false;
      });
    }
  }

  bool _isAlreadyAdded(VoicePreset voice) {
    for (final preset in widget.config.voicePresets) {
      if (preset.id == voice.id) return true;
      if (voice.aliyunVoiceId != null &&
          voice.aliyunVoiceId!.isNotEmpty &&
          preset.aliyunVoiceId == voice.aliyunVoiceId) {
        return true;
      }
      if (voice.siliconFlowVoiceUri != null &&
          voice.siliconFlowVoiceUri!.isNotEmpty &&
          preset.siliconFlowVoiceUri == voice.siliconFlowVoiceUri) {
        return true;
      }
    }
    return false;
  }

  bool _canDeleteRemoteVoice(VoicePreset voice) {
    if (voice.isBuiltIn) return false;
    if (voice.id.startsWith('siliconflow_preset_')) return false;
    if (voice.id.startsWith('minimax_system_')) return false;
    return true;
  }

  Future<void> _confirmDeleteVoice(VoicePreset voice) async {
    final confirmed = await showMeoTalkDialog(
      context: context,
      title: '删除远端音色',
      content: Text('确定要从渠道删除「${voice.name}」吗？'),
      confirmText: '删除',
      isDanger: true,
    );
    if (confirmed != true) return;

    setState(() {
      _deletingVoiceId = voice.id;
    });

    try {
      await TtsVoiceCatalogService.deleteVoice(
        context: widget.providerContext,
        voiceId: voice.id,
        voice: voice,
      );
      if (!mounted) return;

      final current = _result;
      if (current != null) {
        setState(() {
          _result = VoiceListResult(
            presetVoices: current.presetVoices
                .where((item) => item.id != voice.id)
                .toList(),
            userVoices: current.userVoices
                .where((item) => item.id != voice.id)
                .toList(),
          );
          _deletingVoiceId = null;
        });
      }
      final parentContext = widget.parentContext;
      if (!parentContext.mounted) return;
      MoeToast.success(parentContext, '已删除「${voice.name}」');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _deletingVoiceId = null;
      });
      final message = e is TtsProviderException ? e.message : '删除失败: $e';
      final parentContext = widget.parentContext;
      if (!parentContext.mounted) return;
      MoeToast.error(parentContext, message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final providerName = widget.providerContext.providerDisplayName ?? '当前渠道';
    final result = _result;

    if (_loading) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: colors.primary,
                ),
              ),
              const SizedBox(height: 12),
              Text('正在加载音色...', style: TextStyle(color: colors.muted)),
            ],
          ),
        ),
      );
    }

    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: MoeG2Decoration(
            radius: 12,
            color: colors.accent.withValues(alpha: 0.08),
          ),
          child: Row(
            children: [
              Icon(Icons.error_outline, color: colors.accent, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _error!,
                  style: TextStyle(color: colors.accent, fontSize: 13),
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (result == null ||
        (result.presetVoices.isEmpty && result.userVoices.isEmpty)) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: MoeG2Decoration(
            radius: 12,
            color: colors.muted.withValues(alpha: 0.08),
          ),
          child: Row(
            children: [
              Icon(Icons.info_outline, color: colors.muted, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '$providerName 暂无可用音色',
                  style: TextStyle(color: colors.muted, fontSize: 13),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (result.presetVoices.isNotEmpty) ...[
            _buildSectionHeader('$providerName 预置音色', colors),
            ...result.presetVoices
                .map((voice) => _buildVoiceItem(voice, colors)),
          ],
          if (result.userVoices.isNotEmpty) ...[
            _buildSectionHeader('$providerName 已创建音色', colors),
            ...result.userVoices.map((voice) => _buildVoiceItem(voice, colors)),
          ],
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title, MoeColors colors) {
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 8),
      child: Text(
        title,
        style: TextStyle(
          color: colors.textSecondary,
          fontSize: 13,
          fontWeight: MoeFontWeights.emphasis,
        ),
      ),
    );
  }

  Widget _buildVoiceItem(VoicePreset voice, MoeColors colors) {
    final alreadyAdded = _isAlreadyAdded(voice);
    final isDeleting = _deletingVoiceId == voice.id;
    final canDelete = _canDeleteRemoteVoice(voice);

    return MoeSettingsRow(
      icon: alreadyAdded ? Icons.check_circle : Icons.mic,
      iconColor: alreadyAdded ? colors.primary : colors.textSecondary,
      label: voice.name,
      subtitle: voice.source ??
          (voice.sourceType == VoiceSourceType.preset ? '预置音色' : '远端音色'),
      trailingType: canDelete || !alreadyAdded
          ? MoeSettingsRowTrailing.custom
          : MoeSettingsRowTrailing.none,
      trailing: canDelete || !alreadyAdded
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (canDelete)
                  GestureDetector(
                    onTap: isDeleting ? null : () => _confirmDeleteVoice(voice),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: isDeleting
                          ? SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: colors.muted,
                              ),
                            )
                          : Icon(
                              Icons.delete_outline,
                              size: 20,
                              color: colors.muted,
                            ),
                    ),
                  ),
                if (!alreadyAdded)
                  GestureDetector(
                    onTap: () {
                      Navigator.of(context).pop();
                      widget.onVoiceSelected(voice);
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Icon(
                        Icons.add_circle_outline,
                        size: 20,
                        color: colors.primary,
                      ),
                    ),
                  ),
              ],
            )
          : null,
      enabled: !alreadyAdded,
      onTap: alreadyAdded
          ? null
          : () {
              Navigator.of(context).pop();
              widget.onVoiceSelected(voice);
            },
    );
  }
}
