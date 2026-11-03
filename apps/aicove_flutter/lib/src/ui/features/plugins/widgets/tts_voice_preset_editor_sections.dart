part of 'tts_voice_preset_editor_sheet.dart';

extension _TtsVoicePresetEditorSections
    on _TtsVoicePresetEditorSheetContentState {
  Widget _buildBindingsSection(MoeColors colors) {
    if (_bindings.isEmpty) {
      return _buildInfoCard(
        text: '当前还没有渠道音色绑定。你可以先保存基础素材，之后再回来补渠道 ID。',
        color: colors.muted,
      );
    }

    return Column(
      children: _bindings.map((binding) {
        final status = binding.status?.trim();
        final sourceKind = describeVoiceBindingSource(binding.sourceKind);
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: MoeG2Decoration(
              radius: 8,
              color: colors.primary.withValues(alpha: 0.08),
              border: Border.all(color: colors.primary.withValues(alpha: 0.16)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        binding.providerName,
                        style: TextStyle(
                          color: colors.text,
                          fontSize: 14,
                          fontWeight: MoeFontWeights.emphasis,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '模型: ${binding.modelId ?? '未指定'}',
                        style: TextStyle(color: colors.muted, fontSize: 12),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '音色 ID: ${binding.remoteVoiceId}',
                        style: TextStyle(color: colors.muted, fontSize: 12),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '来源: $sourceKind',
                        style: TextStyle(color: colors.muted, fontSize: 12),
                      ),
                      if (status != null && status.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          '状态: $status',
                          style: TextStyle(color: colors.muted, fontSize: 12),
                        ),
                      ],
                    ],
                  ),
                ),
                if (!_isBuiltIn)
                  MoeIconButton(
                    icon: Icons.delete_outline,
                    size: 18,
                    padding: const EdgeInsets.all(4),
                    minTouchTarget: 28,
                    color: colors.muted,
                    enabled: !_submitting,
                    onTap: _submitting ? null : () => _removeBinding(binding),
                  ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildSectionTitle(String text, MoeColors colors) {
    return Text(
      text,
      style: TextStyle(
        color: colors.text,
        fontSize: 14,
        fontWeight: MoeFontWeights.emphasis,
      ),
    );
  }

  Widget _buildInfoCard({required String text, required Color color}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: MoeG2Decoration(
        radius: 8,
        color: color.withValues(alpha: 0.08),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(text, style: TextStyle(color: color, fontSize: 12)),
          ),
        ],
      ),
    );
  }
}
