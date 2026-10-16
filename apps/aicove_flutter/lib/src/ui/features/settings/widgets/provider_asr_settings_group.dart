import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../features/settings/app_settings.dart';
import '../../../../features/voice_call/domain/asr_request_format.dart';
import '../../../shared/widgets/form/moe_input_decoration.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';

/// 渠道详情里的「语音识别」分组：识别格式切换＋该格式要的额外凭证（AppID、SecretId 等）。
///
/// 只在渠道有识别格式时出现；改动写进渠道 customConfig，由 [onSave] 合并保存。
class ProviderAsrSettingsGroup extends StatefulWidget {
  const ProviderAsrSettingsGroup({
    super.key,
    required this.provider,
    required this.onSave,
  });

  final ProviderAuth provider;

  /// 要合并进 customConfig 的键值；值为 null 表示删除该键。
  final Future<void> Function(Map<String, String?> values) onSave;

  @override
  State<ProviderAsrSettingsGroup> createState() =>
      _ProviderAsrSettingsGroupState();
}

class _ProviderAsrSettingsGroupState extends State<ProviderAsrSettingsGroup> {
  final _controllers = <String, TextEditingController>{};
  final _pending = <String, String?>{};
  Timer? _debounce;

  AsrRequestFormat? get _format =>
      AsrRequestFormat.ofConfig(widget.provider.customConfig);

  TextEditingController _controller(String key) => _controllers.putIfAbsent(
    key,
    () => TextEditingController(
      text: widget.provider.customConfig[key]?.toString() ?? '',
    ),
  );

  void _changed(String key, String value) {
    _pending[key] = value.trim().isEmpty ? null : value.trim();
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), _flush);
  }

  Future<void> _flush() async {
    if (_pending.isEmpty) return;
    final values = Map<String, String?>.of(_pending);
    _pending.clear();
    try {
      await widget.onSave(values);
    } catch (e) {
      if (mounted) MoeToast.error(context, '保存失败：$e');
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    unawaited(_flush());
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _pickFormat() async {
    final current = _format;
    final picked = await showMoeBottomSheet<AsrRequestFormat>(
      context: context,
      title: '语音识别格式',
      showCloseButton: true,
      builder: (context) {
        final colors = context.moeColors;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          child: MoeSettingsGroup(
            margin: EdgeInsets.zero,
            children: [
              for (final (index, format) in AsrRequestFormat.all.indexed)
                MoeSettingsRow(
                  label: format.label,
                  showDivider: index != AsrRequestFormat.all.length - 1,
                  trailingType: MoeSettingsRowTrailing.custom,
                  trailing: format == current
                      ? Icon(Icons.check, color: colors.primary, size: 18)
                      : const SizedBox.shrink(),
                  onTap: () => Navigator.of(context).pop(format),
                ),
            ],
          ),
        );
      },
    );
    if (picked == null || picked == current) return;
    await _flush();
    try {
      await widget.onSave({AsrRequestFormat.configKey: picked.value});
    } catch (e) {
      if (mounted) MoeToast.error(context, '保存失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final format = _format;
    if (format == null) return const SizedBox.shrink();
    final colors = context.moeColors;
    final fields = format.credentialFields;
    return MoeSettingsGroup(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      title: '语音识别',
      children: [
        MoeSettingsRow(
          label: '识别格式',
          detailText: format.label,
          trailingType: MoeSettingsRowTrailing.text,
          showDivider: fields.isNotEmpty || format.apiKeyLabel != 'API Key',
          onTap: _pickFormat,
        ),
        for (final (index, field) in fields.indexed)
          MoeSettingsRow(
            label: field.label,
            subtitle: field.hint,
            showDivider:
                index != fields.length - 1 || format.apiKeyLabel != 'API Key',
            trailingType: MoeSettingsRowTrailing.custom,
            expandTrailing: true,
            trailing: TextField(
              controller: _controller(field.key),
              style: TextStyle(fontSize: 14, color: colors.text),
              textAlign: TextAlign.end,
              decoration: MoeInputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.zero,
                hintText: field.optional ? '可选' : '未设置',
              ),
              onChanged: (value) => _changed(field.key, value),
            ),
          ),
        if (format.apiKeyLabel != 'API Key')
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              '上方「API Key」一栏填 ${format.apiKeyLabel}。',
              style: TextStyle(fontSize: 13, color: colors.textSecondary),
            ),
          ),
      ],
    );
  }
}
