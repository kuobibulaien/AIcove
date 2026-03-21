/// TtsSettingsForm - TTS 设置表单组件
///
/// 从 tts_plugin_detail_page.dart 提取，处理 TTS 配置的各项设置。
///
/// 更新记录：
/// - 2025-12-31: 从 tts_plugin_detail_page.dart 提取
/// - 2026-01-15: 重构 - 删除 API 配置，改用统一模型管理的渠道选择
/// - 2026-01-25: 用公共组件重构界面，添加音色列表功能
/// - 2026-01-27: 重构音色管理 - 统一获取逻辑，添加自定义入口，添加 CosyVoice 提示
/// - 2026-03-21: 按厂商适配器拆分音色管理 UI
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/plugins/plugin_providers.dart';
import '../../../../features/plugins/tts/tts_config.dart';
import '../../../../features/plugins/tts/tts_provider_context.dart';
import '../../../../features/settings/app_settings.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/theme/tokens.dart';
import 'tts_voice_preset_section.dart';

/// TTS 设置表单组件
class TtsSettingsForm extends ConsumerWidget {
  const TtsSettingsForm({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(ttsPluginConfigProvider);
    final notifier = ref.read(ttsPluginConfigProvider.notifier);
    final colors = context.moeColors;
    final settings = ref.watch(appSettingsProvider).valueOrNull;
    final providerContext = TtsProviderContext.resolve(
      config: config,
      settings: settings,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildModelSection(context, config, notifier, settings),
        const SizedBox(height: 16),
        TtsVoicePresetSection(
          config: config,
          notifier: notifier,
          providerContext: providerContext,
        ),
        const SizedBox(height: 16),
        _buildVoiceFrequencySection(context, config, notifier),
        const SizedBox(height: 16),
        _buildGeneralSettings(context, config, notifier, colors),
      ],
    );
  }

  Widget _buildModelSection(
    BuildContext context,
    TtsConfig config,
    TtsPluginConfigNotifier notifier,
    AppSettings? settings,
  ) {
    final ttsModels = <_TtsModelEntry>[];
    if (settings != null) {
      for (final provider in settings.providers) {
        if (!provider.enabled) continue;
        for (final modelId in settings.getProviderVisibleModelsByType(
          provider.id,
          type: ModelType.tts,
        )) {
          final modelRef = settings.buildModelRef(provider.id, modelId);
          ttsModels.add(
            _TtsModelEntry(
              modelId: modelId,
              providerId: provider.id,
              providerName: provider.displayName ?? provider.id,
              displayName: settings.getModelDisplayName(modelRef),
            ),
          );
        }
      }
    }

    final selectedModelId = config.selectedModelId;
    final selectedProviderId = config.selectedProviderId;
    final hasStoredSelection =
        selectedModelId != null && selectedModelId.isNotEmpty;
    final selectedEntry = ttsModels
            .where(
              (entry) =>
                  entry.modelId == selectedModelId &&
                  (selectedProviderId == null ||
                      selectedProviderId.isEmpty ||
                      entry.providerId == selectedProviderId),
            )
            .firstOrNull ??
        ttsModels
            .where((entry) => entry.modelId == selectedModelId)
            .firstOrNull;

    return MoeSettingsGroup(
      title: 'TTS 模型',
      margin: EdgeInsets.zero,
      children: [
        MoeSettingsRow(
          icon: Icons.graphic_eq,
          label: '选择模型',
          trailingType: MoeSettingsRowTrailing.text,
          detailText: selectedEntry != null
              ? selectedEntry.displayName
              : (ttsModels.isEmpty
                  ? '无可用模型'
                  : (hasStoredSelection ? '当前模型已不可用' : '未选择')),
          onTap: ttsModels.isEmpty
              ? () {
                  MoeToast.warning(
                    context,
                    '暂无语音模型，请先在渠道管理里显示并标记语音标签',
                  );
                }
              : () => _showTtsModelSelector(
                    context,
                    models: ttsModels,
                    config: config,
                    notifier: notifier,
                  ),
          showDivider: selectedEntry != null,
        ),
        if (selectedEntry != null)
          MoeSettingsRow(
            icon: Icons.cloud_outlined,
            label: '所属渠道',
            trailingType: MoeSettingsRowTrailing.text,
            detailText: selectedEntry.providerName,
            showDivider: false,
          ),
      ],
    );
  }

  void _showTtsModelSelector(
    BuildContext context, {
    required List<_TtsModelEntry> models,
    required TtsConfig config,
    required TtsPluginConfigNotifier notifier,
  }) {
    showMoeActionSheet(
      context: context,
      title: '选择 TTS 模型',
      description: '从已配置的语音合成模型中选择',
      actions: models.map((entry) {
        final isSelected = entry.modelId == config.selectedModelId &&
            entry.providerId == config.selectedProviderId;
        return MoeSheetAction(
          icon: isSelected ? Icons.check_circle : Icons.graphic_eq,
          label: entry.displayName,
          subtitle: entry.providerName,
          onTap: () {
            notifier.setSelectedProvider(entry.providerId);
            notifier.setSelectedModel(entry.modelId);
            MoeToast.success(context, '已选择 ${entry.displayName}');
          },
        );
      }).toList(),
    );
  }

  Widget _buildVoiceFrequencySection(
    BuildContext context,
    TtsConfig config,
    TtsPluginConfigNotifier notifier,
  ) {
    final colors = context.moeColors;
    final frequency = config.voiceFrequency;
    final levels = [
      (0, '关闭', 'AI 不会使用语音'),
      (20, '极少', '只在非常重要时使用'),
      (40, '偶尔', '重点内容时使用'),
      (60, '正常', '一轮 1-2 句语音'),
      (80, '较多', '积极使用语音'),
      (100, '频繁', '尽可能多地使用'),
    ];

    int currentLevel = 0;
    for (int index = levels.length - 1; index >= 0; index--) {
      if (frequency >= levels[index].$1) {
        currentLevel = index;
        break;
      }
    }

    return MoeSettingsGroup(
      title: '语音频率',
      margin: EdgeInsets.zero,
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.tune, color: colors.primary, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    levels[currentLevel].$2,
                    style: TextStyle(
                      color: colors.text,
                      fontSize: 16,
                      fontWeight: MoeFontWeights.emphasis,
                    ),
                  ),
                  if (currentLevel == 3) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: colors.primary.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '推荐',
                        style: TextStyle(
                          color: colors.primary,
                          fontSize: 11,
                          fontWeight: MoeFontWeights.emphasis,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 4),
              Text(
                levels[currentLevel].$3,
                style: TextStyle(color: colors.muted, fontSize: 12),
              ),
              const SizedBox(height: 16),
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: colors.primary,
                  inactiveTrackColor: colors.border,
                  thumbColor: colors.primary,
                  overlayColor: colors.primary.withValues(alpha: 0.2),
                  trackHeight: 4,
                ),
                child: Slider(
                  value: frequency.toDouble(),
                  min: 0,
                  max: 100,
                  divisions: 5,
                  onChanged: (value) {
                    notifier.setVoiceFrequency(value.toInt());
                  },
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: levels.map((level) {
                  final isRecommended = level.$1 == 60;
                  return Text(
                    level.$2,
                    style: TextStyle(
                      color: isRecommended ? colors.primary : colors.muted,
                      fontSize: 11,
                      fontWeight: isRecommended
                          ? MoeFontWeights.emphasis
                          : MoeFontWeights.normal,
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildGeneralSettings(
    BuildContext context,
    TtsConfig config,
    TtsPluginConfigNotifier notifier,
    MoeColors colors,
  ) {
    return MoeSettingsGroup(
      title: '通用设置',
      margin: EdgeInsets.zero,
      children: [
        MoeSettingsRow(
          icon: Icons.speed,
          label: '语速',
          subtitle: '0.5 ~ 2.0，默认 1.0',
          trailingType: MoeSettingsRowTrailing.text,
          detailText: config.speed?.toString() ?? '1.0',
          onTap: () => _showSpeedInputDialog(context, config, notifier, colors),
        ),
        MoeSettingsRow(
          icon: Icons.text_fields,
          label: '每段最大字数',
          subtitle: '超过会自动拆分',
          trailingType: MoeSettingsRowTrailing.text,
          detailText: config.maxCharsPerChunk.toString(),
          onTap: () =>
              _showMaxCharsInputDialog(context, config, notifier, colors),
          showDivider: false,
        ),
      ],
    );
  }

  void _showSpeedInputDialog(
    BuildContext context,
    TtsConfig config,
    TtsPluginConfigNotifier notifier,
    MoeColors colors,
  ) {
    final controller = TextEditingController(
      text: config.speed?.toString() ?? '1.0',
    );

    showMeoTalkDialog(
      context: context,
      title: '设置语速',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '语速范围 0.5 ~ 2.0',
            style: TextStyle(color: colors.muted, fontSize: 13),
          ),
          const SizedBox(height: 16),
          MoeTextField(
            controller: controller,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            hint: '1.0',
            autofocus: true,
          ),
        ],
      ),
      confirmText: '确定',
    ).then((confirmed) {
      if (confirmed != true) return;
      final speed = double.tryParse(controller.text);
      if (speed != null && speed >= 0.5 && speed <= 2.0) {
        notifier.setSpeed(speed);
      } else {
        if (!context.mounted) return;
        MoeToast.warning(context, '请输入 0.5 ~ 2.0 之间的数字');
      }
    });
  }

  void _showMaxCharsInputDialog(
    BuildContext context,
    TtsConfig config,
    TtsPluginConfigNotifier notifier,
    MoeColors colors,
  ) {
    final controller = TextEditingController(
      text: config.maxCharsPerChunk.toString(),
    );

    showMeoTalkDialog(
      context: context,
      title: '设置每段最大字数',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '超过此字数会自动拆分为多段语音',
            style: TextStyle(color: colors.muted, fontSize: 13),
          ),
          const SizedBox(height: 16),
          MoeTextField(
            controller: controller,
            keyboardType: TextInputType.number,
            hint: '20',
            autofocus: true,
          ),
        ],
      ),
      confirmText: '确定',
    ).then((confirmed) {
      if (confirmed != true) return;
      final maxChars = int.tryParse(controller.text);
      if (maxChars != null && maxChars > 0) {
        notifier.setMaxCharsPerChunk(maxChars);
      } else {
        if (!context.mounted) return;
        MoeToast.warning(context, '请输入大于 0 的整数');
      }
    });
  }
}

class _TtsModelEntry {
  final String modelId;
  final String providerId;
  final String providerName;
  final String displayName;

  const _TtsModelEntry({
    required this.modelId,
    required this.providerId,
    required this.providerName,
    required this.displayName,
  });
}
