/// TtsSettingsForm - TTS 设置表单组件
///
/// 从 tts_plugin_detail_page.dart 提取，处理 TTS 配置的各项设置。
///
/// 更新记录：
/// - 2025-12-31: 从 tts_plugin_detail_page.dart 提取
/// - 2026-01-15: 重构 - 删除 API 配置，改用统一模型管理的渠道选择
/// - 2026-01-25: 用公共组件重构界面，添加音色列表功能
/// - 2026-01-27: 重构音色管理 - 统一获取逻辑，添加自定义入口，添加 CosyVoice 提示
library;

import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../../../core/app_logger.dart';
import '../../../../features/plugins/plugin_providers.dart';
import '../../../../features/plugins/tts/aliyun_voice_clone_service.dart';
import '../../../../features/plugins/tts/tts_config.dart';
import '../../../../features/plugins/tts/voice_manager_service.dart';
import '../../../../features/plugins/tts/siliconflow_tts_service.dart';
import '../../../../features/settings/app_settings.dart';
import '../../../../features/settings/settings_models.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/shared/widgets/index.dart';

/// TTS 设置表单组件
class TtsSettingsForm extends ConsumerStatefulWidget {
  const TtsSettingsForm({super.key});

  @override
  ConsumerState<TtsSettingsForm> createState() => _TtsSettingsFormState();
}

class _TtsSettingsFormState extends ConsumerState<TtsSettingsForm> {
  final _speedController = TextEditingController();
  final _maxCharsController = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadConfig();
    });
  }

  void _loadConfig() {
    final config = ref.read(ttsPluginConfigProvider);
    _speedController.text = config.speed?.toString() ?? '';
    _maxCharsController.text = config.maxCharsPerChunk.toString();
  }

  @override
  void dispose() {
    _speedController.dispose();
    _maxCharsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(ttsPluginConfigProvider);
    final notifier = ref.read(ttsPluginConfigProvider.notifier);
    final colors = context.moeColors;

    // 从所有渠道中收集带 tts 类型标签的模型
    final appSettingsAsync = ref.watch(appSettingsProvider);
    final settings = appSettingsAsync.valueOrNull;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // TTS 模型选择（一步到位）
        _buildModelSection(config, notifier, settings, colors),
        const SizedBox(height: 16),

        // 音色列表（紧跟模型选择）
        _buildVoicePresetsSection(config, notifier, colors),
        const SizedBox(height: 16),

        // 语音频率设置
        _buildVoiceFrequencySection(config, notifier, colors),
        const SizedBox(height: 16),

        // 通用设置
        _buildGeneralSettings(config, notifier, colors),
      ],
    );
  }

  /// 构建 TTS 模型选择区（直接从渠道管理获取所有 tts 类型模型）
  Widget _buildModelSection(
    TtsConfig config,
    TtsPluginConfigNotifier notifier,
    AppSettings? settings,
    MoeColors colors,
  ) {
    // 收集所有 tts 类型的模型（通过 modelTypes 标签筛选）
    final ttsModels = <_TtsModelEntry>[];
    if (settings != null) {
      for (final provider in settings.providers) {
        if (!provider.enabled) continue;
        for (final modelId in provider.visibleModels) {
          final type = settings.getModelType(modelId);
          if (type == ModelType.tts) {
            ttsModels.add(_TtsModelEntry(
              modelId: modelId,
              providerId: provider.id,
              providerName: provider.displayName ?? provider.id,
              displayName: settings.getModelDisplayName(modelId),
            ));
          }
        }
      }
    }

    // 当前选中的模型
    final selectedModelId = config.selectedModelId;
    final selectedEntry = ttsModels
        .where((e) => e.modelId == selectedModelId)
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
              : (ttsModels.isEmpty ? '无可用模型' : '未选择'),
          onTap: ttsModels.isEmpty
              ? () {
                  MoeToast.warning(context, '暂无语音合成模型，请先在「模型管理」中添加并标记为语音合成类型');
                }
              : () => _showTtsModelSelector(ttsModels, config, notifier),
          showDivider: selectedEntry != null,
        ),
        // 显示当前渠道信息（只读）
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

  /// 显示 TTS 模型选择弹窗
  void _showTtsModelSelector(
    List<_TtsModelEntry> models,
    TtsConfig config,
    TtsPluginConfigNotifier notifier,
  ) {
    showMoeActionSheet(
      context: context,
      title: '选择 TTS 模型',
      description: '从已配置的语音合成模型中选择',
      actions: models.map((entry) {
        final isSelected = entry.modelId == config.selectedModelId;
        return MoeSheetAction(
          icon: isSelected ? Icons.check_circle : Icons.graphic_eq,
          label: entry.displayName,
          subtitle: entry.providerName,
          onTap: () {
            // 同时设置模型和对应的渠道
            notifier.setSelectedProvider(entry.providerId);
            notifier.setSelectedModel(entry.modelId);
            MoeToast.success(context, '已选择 ${entry.displayName}');
          },
        );
      }).toList(),
    );
  }

  /// 构建语音频率设置区
  Widget _buildVoiceFrequencySection(
    TtsConfig config,
    TtsPluginConfigNotifier notifier,
    MoeColors colors,
  ) {
    final frequency = config.voiceFrequency;

    // 频率档位定义
    final levels = [
      (0, '关闭', 'AI 不会使用语音'),
      (20, '极少', '只在非常重要时使用'),
      (40, '偶尔', '重点内容时使用'),
      (60, '正常', '一轮 1-2 句语音'), // 推荐
      (80, '较多', '积极使用语音'),
      (100, '频繁', '尽可能多地使用'),
    ];

    // 找到当前档位
    int currentLevel = 0;
    for (int i = levels.length - 1; i >= 0; i--) {
      if (frequency >= levels[i].$1) {
        currentLevel = i;
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
              // 当前档位显示
              Row(
                children: [
                  Icon(Icons.tune, color: colors.primary, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    levels[currentLevel].$2,
                    style: TextStyle(
                      color: colors.text,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  // 推荐标识
                  if (currentLevel == 3) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: MoeG2Decoration(
                        radius: 10,
                        color: colors.primary.withValues(alpha: 0.15),
                      ),
                      child: Text(
                        '推荐',
                        style: TextStyle(
                          color: colors.primary,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
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

              // 滑块
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

              // 档位标签
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: levels.map((level) {
                  final isRecommended = level.$1 == 60;
                  return Text(
                    level.$2,
                    style: TextStyle(
                      color: isRecommended ? colors.primary : colors.muted,
                      fontSize: 11,
                      fontWeight:
                          isRecommended ? FontWeight.w600 : FontWeight.normal,
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

  /// 构建通用设置区
  Widget _buildGeneralSettings(
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
          onTap: () => _showSpeedInputDialog(config, notifier, colors),
        ),
        MoeSettingsRow(
          icon: Icons.text_fields,
          label: '每段最大字数',
          subtitle: '超过会自动拆分',
          trailingType: MoeSettingsRowTrailing.text,
          detailText: config.maxCharsPerChunk.toString(),
          onTap: () => _showMaxCharsInputDialog(config, notifier, colors),
          showDivider: false,
        ),
      ],
    );
  }

  /// 显示语速输入弹窗
  void _showSpeedInputDialog(
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
      if (confirmed == true) {
        final speed = double.tryParse(controller.text);
        if (speed != null && speed >= 0.5 && speed <= 2.0) {
          notifier.setSpeed(speed);
        } else {
          MoeToast.warning(context, '请输入 0.5 ~ 2.0 之间的数字');
        }
      }
    });
  }

  /// 显示最大字数输入弹窗
  void _showMaxCharsInputDialog(
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
      if (confirmed == true) {
        final maxChars = int.tryParse(controller.text);
        if (maxChars != null && maxChars > 0) {
          notifier.setMaxCharsPerChunk(maxChars);
        } else {
          MoeToast.warning(context, '请输入大于 0 的整数');
        }
      }
    });
  }

  /// 构建音色列表区
  Widget _buildVoicePresetsSection(
    TtsConfig config,
    TtsPluginConfigNotifier notifier,
    MoeColors colors,
  ) {
    final presets = config.voicePresets;
    final selectedId = config.selectedVoicePresetId;
    final selectedModelId = config.selectedModelId;

    // 判断当前模型类型
    final isCosyVoice = selectedModelId?.toLowerCase().contains('cosyvoice') ?? false;
    final isQwenTts = selectedModelId?.toLowerCase().contains('qwen') ?? false;
    final isSiliconFlow = _isCurrentProviderSiliconFlow(config);
    final isAliyun = _isCurrentProviderAliyun(config);

    return MoeSettingsGroup(
      title: '音色列表',
      margin: EdgeInsets.zero,
      children: [
        // CosyVoice 特殊提示
        if (isCosyVoice)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: MoeG2Decoration(
                radius: 8,
                color: Colors.orange.withValues(alpha: 0.1),
                border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline, color: Colors.orange, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'CosyVoice 仅支持公网直链，不支持本地文件上传',
                      style: TextStyle(
                        color: Colors.orange.shade700,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

        // 未选择模型时的提示
        if (selectedModelId == null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(Icons.warning_amber_outlined, color: colors.muted, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '请先选择 TTS 模型',
                    style: TextStyle(color: colors.muted, fontSize: 13),
                  ),
                ),
              ],
            ),
          )
        // 音色列表为空时的提示
        else if (presets.isEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(Icons.info_outline, color: colors.muted, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '暂无音色，点击「获取」添加预置音色，或点击「自定义」上传音频',
                    style: TextStyle(color: colors.muted, fontSize: 13),
                  ),
                ),
              ],
            ),
          )
        else
          ...presets.asMap().entries.map((entry) {
            final index = entry.key;
            final preset = entry.value;
            final isSelected = preset.id == selectedId;
            final isLast = index == presets.length - 1;

            // 判断音色是否可用于当前选中的模型
            final isAvailable = selectedModelId == null ||
                preset.canUseWithModel(selectedModelId);

            // 构建副标题：显示音色来源和状态
            String subtitle = _buildVoicePresetSubtitle(preset, isAvailable, isAliyun, isSiliconFlow);

            return MoeSettingsRow(
              icon: isSelected ? Icons.check_circle : Icons.mic,
              iconColor: isSelected
                  ? colors.primary
                  : (isAvailable ? null : colors.muted),
              label: preset.name,
              subtitle: subtitle,
              trailingType: MoeSettingsRowTrailing.custom,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 删除按钮（内置音色不显示）
                  if (!preset.isBuiltIn)
                    GestureDetector(
                      onTap: () => _confirmDeleteVoice(preset, notifier, colors),
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Icon(
                          Icons.delete_outline,
                          size: 20,
                          color: colors.muted,
                        ),
                      ),
                    ),
                  // 进入详情
                  Icon(
                    Icons.chevron_right,
                    size: 20,
                    color: colors.muted,
                  ),
                ],
              ),
              enabled: isAvailable,
              onTap: isAvailable
                  ? () => _onVoicePresetTap(preset, notifier, colors)
                  : () => MoeToast.warning(context, '该音色不适用于当前选中的模型'),
              showDivider: !isLast,
            );
          }),

        // 底部操作按钮
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              // 获取按钮
              Expanded(
                child: MoeSecondaryButton(
                  label: '获取',
                  icon: Icons.cloud_download_outlined,
                  enabled: selectedModelId != null,
                  onPressed: selectedModelId == null
                      ? null
                      : () => _showFetchVoicesSheet(config, notifier, colors),
                ),
              ),
              const SizedBox(width: 12),
              // 自定义按钮（原"添加"）
              Expanded(
                child: MoePrimaryButton(
                  label: '自定义',
                  icon: Icons.add,
                  enabled: selectedModelId != null,
                  onPressed: selectedModelId == null
                      ? null
                      : () => _showVoicePresetEditor(null, notifier, colors),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 判断当前渠道是否是硅基流动
  bool _isCurrentProviderSiliconFlow(TtsConfig config) {
    final appSettings = ref.read(appSettingsProvider).valueOrNull;
    if (appSettings == null || config.selectedProviderId == null) return false;
    final provider = appSettings.providers
        .where((p) => p.id == config.selectedProviderId)
        .firstOrNull;
    return provider != null && VoiceManagerService.isSiliconFlowProvider(provider);
  }

  /// 判断当前渠道是否是阿里云
  bool _isCurrentProviderAliyun(TtsConfig config) {
    final appSettings = ref.read(appSettingsProvider).valueOrNull;
    if (appSettings == null || config.selectedProviderId == null) return false;
    final provider = appSettings.providers
        .where((p) => p.id == config.selectedProviderId)
        .firstOrNull;
    return provider != null && VoiceManagerService.isAliyunProvider(provider);
  }

  /// 构建音色预设的副标题（简化版：只显示推荐和不可用）
  String _buildVoicePresetSubtitle(VoicePreset preset, bool isAvailable, bool isAliyun, bool isSiliconFlow) {
    final parts = <String>[];

    // 显示音色类型（调试用）
    if (preset.sourceType == VoiceSourceType.local) {
      parts.add('本地文件');
    } else if (preset.sourceType == VoiceSourceType.url) {
      parts.add('直链');
    } else if (preset.sourceType == VoiceSourceType.preset) {
      parts.add('预置');
    }

    // 推荐标识（内置音色视为推荐）
    if (preset.isBuiltIn) {
      parts.add('推荐');
    }

    // 不可用标识（只有真正不可用时才显示）
    if (!isAvailable) {
      parts.add('不可用');
    }

    return parts.isEmpty ? '' : parts.join(' · ');
  }

  /// 显示获取音色弹窗（统一入口）
  ///
  /// 展示：内置公网直链 + 本地已保存音频 + 渠道预置音色
  void _showFetchVoicesSheet(
    TtsConfig config,
    TtsPluginConfigNotifier notifier,
    MoeColors colors,
  ) {
    final isSiliconFlow = _isCurrentProviderSiliconFlow(config);
    final isAliyun = _isCurrentProviderAliyun(config);

    // 获取渠道的 API Key
    final appSettings = ref.read(appSettingsProvider).valueOrNull;
    final provider = appSettings?.providers
        .where((p) => p.id == config.selectedProviderId)
        .firstOrNull;
    final apiKey = provider?.apiKeys.isNotEmpty == true ? provider!.apiKeys.first : null;

    showMoeBottomSheet(
      context: context,
      title: '获取音色',
      builder: (context) => _FetchVoicesSheetContent(
        config: config,
        notifier: notifier,
        isSiliconFlow: isSiliconFlow,
        isAliyun: isAliyun,
        apiKey: apiKey,
        onVoiceSelected: (voice) {
          Navigator.pop(context);
          notifier.addVoicePreset(voice);
          notifier.selectVoicePreset(voice.id);
          MoeToast.success(this.context, '已添加「${voice.name}」');
        },
      ),
    );
  }

  /// 点击音色预设：选择该音色
  void _onVoicePresetTap(
    VoicePreset preset,
    TtsPluginConfigNotifier notifier,
    MoeColors colors,
  ) {
    final config = ref.read(ttsPluginConfigProvider);
    final isSelected = preset.id == config.selectedVoicePresetId;

    if (isSelected) {
      // 已选中，显示操作菜单（编辑/取消选择）
      _showVoicePresetActions(preset, notifier, colors);
    } else {
      // 未选中，直接选择
      notifier.selectVoicePreset(preset.id);
      MoeToast.success(context, '已选择「${preset.name}」');
    }
  }

  /// 确认删除音色
  void _confirmDeleteVoice(
    VoicePreset preset,
    TtsPluginConfigNotifier notifier,
    MoeColors colors,
  ) {
    // 内置音色不能删除
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
    ).then((confirmed) {
      if (confirmed == true) {
        // 如果有本地文件，一并删除
        if (preset.localAudioPath != null) {
          try {
            File(preset.localAudioPath!).deleteSync();
          } catch (_) {}
        }
        notifier.deleteVoicePreset(preset.id);
        MoeToast.success(context, '已删除');
      }
    });
  }

  /// 显示音色编辑器（编辑/新建共用）
  ///
  /// 支持：
  /// - 音色名称
  /// - 参考音频（直链或本地文件，互斥）
  /// - 参考文本
  /// - 查看已绑定的音色ID（只读）
  void _showVoicePresetEditor(
    VoicePreset? preset,
    TtsPluginConfigNotifier notifier,
    MoeColors colors, {
    VoiceSourceType sourceType = VoiceSourceType.url,
    String? prefillName,
    String? prefillUrl,
    String? prefillPromptText,
    String? prefillSource,
    String? prefillLocalPath,
  }) {
    final isEdit = preset != null;
    final isBuiltIn = preset?.isBuiltIn ?? false;

    final nameController = TextEditingController(text: preset?.name ?? prefillName ?? '');
    final audioUrlController =
        TextEditingController(text: preset?.promptAudioUrl ?? prefillUrl ?? '');
    final promptTextController =
        TextEditingController(text: preset?.promptText ?? prefillPromptText ?? '');
    // source 字段由内置直链或用户上传时自动设置，不由用户手动填写
    final effectiveSource = preset?.source ?? prefillSource;

    // 本地文件路径（互斥于直链）
    String? localAudioPath = preset?.localAudioPath ?? prefillLocalPath;
    String? localAudioFileName; // 用于显示的文件名
    if (localAudioPath != null) {
      localAudioFileName = localAudioPath.split('/').last.split('\\').last;
    }

    showMoeBottomSheet(
      context: context,
      title: isEdit ? '编辑音色' : '自定义音色',
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) {
          // 判断当前是直链模式还是本地文件模式
          final hasUrl = audioUrlController.text.trim().isNotEmpty;
          final hasLocalFile = localAudioPath != null && localAudioPath!.isNotEmpty;

          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 音色名称
                Text(
                  '音色名称',
                  style: TextStyle(
                    color: colors.text,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 8),
                MoeTextField(
                  controller: nameController,
                  hint: '如：温柔女声',
                  enabled: !isBuiltIn,
                ),
                const SizedBox(height: 16),

                // 参考音频（直链或本地文件，互斥）
                Text(
                  '参考音频',
                  style: TextStyle(
                    color: colors.text,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '支持公网直链或本地文件（二选一）',
                  style: TextStyle(color: colors.muted, fontSize: 12),
                ),
                const SizedBox(height: 8),

                // 直链输入框
                MoeTextField(
                  controller: audioUrlController,
                  hint: 'https://example.com/voice.mp3',
                  enabled: !isBuiltIn && !hasLocalFile,
                  onChanged: (value) {
                    setSheetState(() {});
                  },
                ),
                const SizedBox(height: 8),

                // 或者选择本地文件
                if (!hasUrl && !isBuiltIn)
                  GestureDetector(
                    onTap: () async {
                      try {
                        final result = await FilePicker.platform.pickFiles(
                          type: FileType.audio,
                          allowMultiple: false,
                        );
                        if (result == null || result.files.isEmpty) return;

                        final file = result.files.first;
                        if (file.path == null) {
                          MoeToast.warning(context, '无法读取文件');
                          return;
                        }

                        // 读取并保存到应用目录
                        final sourceFile = File(file.path!);
                        final bytes = await sourceFile.readAsBytes();

                        final appDir = await getApplicationDocumentsDirectory();
                        final voicesDir = Directory('${appDir.path}/voices');
                        if (!await voicesDir.exists()) {
                          await voicesDir.create(recursive: true);
                        }

                        final fileName = '${DateTime.now().millisecondsSinceEpoch}_${file.name}';
                        final savedFile = File('${voicesDir.path}/$fileName');
                        await savedFile.writeAsBytes(bytes);

                        setSheetState(() {
                          localAudioPath = savedFile.path;
                          localAudioFileName = file.name;
                        });
                      } catch (e) {
                        MoeToast.error(context, '文件选择失败: $e');
                      }
                    },
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: MoeG2Decoration(
                        radius: 8,
                        color: colors.muted.withValues(alpha: 0.1),
                        border: Border.all(color: colors.muted.withValues(alpha: 0.2)),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.upload_file, color: colors.muted, size: 20),
                          const SizedBox(width: 8),
                          Text(
                            '选择本地音频文件',
                            style: TextStyle(color: colors.textSecondary, fontSize: 14),
                          ),
                        ],
                      ),
                    ),
                  ),

                // 已选择的本地文件
                if (hasLocalFile) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: MoeG2Decoration(
                      radius: 8,
                      color: colors.primary.withValues(alpha: 0.1),
                      border: Border.all(color: colors.primary.withValues(alpha: 0.3)),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.audio_file, color: colors.primary, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            localAudioFileName ?? '本地文件',
                            style: TextStyle(color: colors.text, fontSize: 14),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (!isBuiltIn)
                          GestureDetector(
                            onTap: () {
                              setSheetState(() {
                                // 删除文件
                                if (localAudioPath != null) {
                                  try {
                                    File(localAudioPath!).deleteSync();
                                  } catch (_) {}
                                }
                                localAudioPath = null;
                                localAudioFileName = null;
                              });
                            },
                            child: Padding(
                              padding: const EdgeInsets.all(4),
                              child: Icon(Icons.close, color: colors.muted, size: 18),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],

                const SizedBox(height: 16),

                // 参考文本
                Text(
                  '参考文本（选填）',
                  style: TextStyle(
                    color: colors.text,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '与参考音频对应的文本，可提升复刻效果',
                  style: TextStyle(color: colors.muted, fontSize: 12),
                ),
                const SizedBox(height: 8),
                MoeTextField(
                  controller: promptTextController,
                  hint: '输入音频中说的话...',
                  maxLines: 2,
                  enabled: !isBuiltIn,
                ),

                // 已绑定的音色ID信息（只读）
                if (preset?.hasAliyunVoice == true) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: MoeG2Decoration(
                      radius: 8,
                      color: colors.primary.withValues(alpha: 0.1),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.cloud_done, color: colors.primary, size: 16),
                            const SizedBox(width: 8),
                            Text(
                              '阿里云音色 ID',
                              style: TextStyle(
                                color: colors.primary,
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'ID: ${preset!.aliyunVoiceId ?? "未知"}',
                          style: TextStyle(color: colors.muted, fontSize: 11),
                        ),
                        if (preset.aliyunTargetModel != null)
                          Text(
                            '模型: ${preset.aliyunTargetModel}',
                            style: TextStyle(color: colors.muted, fontSize: 11),
                          ),
                        if (preset.aliyunVoiceStatus != null)
                          Text(
                            '状态: ${preset.aliyunVoiceStatus}',
                            style: TextStyle(color: colors.muted, fontSize: 11),
                          ),
                      ],
                    ),
                  ),
                ] else if (preset != null && !preset.isBuiltIn && (hasUrl || hasLocalFile)) ...[
                  // 有音频但还没有音色ID，显示等待生成提示
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: MoeG2Decoration(
                      radius: 8,
                      color: colors.muted.withValues(alpha: 0.1),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.hourglass_empty, color: colors.muted, size: 16),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '阿里云音色 ID 将在首次使用时自动创建',
                            style: TextStyle(
                              color: colors.muted,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                // 硅基流动音色ID信息（只读）
                if (preset?.hasSiliconFlowVoice == true) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: MoeG2Decoration(
                      radius: 8,
                      color: colors.primary.withValues(alpha: 0.1),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.cloud_done, color: colors.primary, size: 16),
                            const SizedBox(width: 8),
                            Text(
                              '硅基流动音色 URI',
                              style: TextStyle(
                                color: colors.primary,
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'URI: ${preset!.siliconFlowVoiceUri ?? "未知"}',
                          style: TextStyle(color: colors.muted, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                ],

                const SizedBox(height: 24),

                // 操作按钮
                if (isBuiltIn)
                  // 内置音色只能关闭
                  MoePrimaryButton(
                    label: '关闭',
                    onPressed: () => Navigator.pop(context),
                  )
                else
                  Row(
                    children: [
                      Expanded(
                        child: MoeSecondaryButton(
                          label: '取消',
                          onPressed: () {
                            // 如果是新建且选择了本地文件，取消时删除
                            if (!isEdit && localAudioPath != null) {
                              try {
                                File(localAudioPath!).deleteSync();
                              } catch (_) {}
                            }
                            Navigator.pop(context);
                          },
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: MoePrimaryButton(
                          label: isEdit ? '保存' : '添加',
                          onPressed: () {
                            final name = nameController.text.trim();
                            if (name.isEmpty) {
                              MoeToast.warning(context, '请输入音色名称');
                              return;
                            }

                            final audioUrl = audioUrlController.text.trim();
                            final hasUrlInput = audioUrl.isNotEmpty;
                            final hasFileInput = localAudioPath != null && localAudioPath!.isNotEmpty;

                            // 校验：必须有音频来源
                            if (!hasUrlInput && !hasFileInput) {
                              MoeToast.warning(context, '请输入直链或选择本地文件');
                              return;
                            }

                            // 确定 sourceType
                            final finalSourceType = hasFileInput
                                ? VoiceSourceType.local
                                : VoiceSourceType.url;

                            final newPreset = VoicePreset(
                              id: preset?.id,
                              name: name,
                              sourceType: finalSourceType,
                              promptAudioUrl: hasUrlInput ? audioUrl : null,
                              localAudioPath: hasFileInput ? localAudioPath : null,
                              promptText: promptTextController.text.trim().isEmpty
                                  ? null
                                  : promptTextController.text.trim(),
                              source: effectiveSource,
                              // 保留已有的渠道音色信息
                              aliyunVoiceId: preset?.aliyunVoiceId,
                              aliyunTargetModel: preset?.aliyunTargetModel,
                              aliyunVoiceStatus: preset?.aliyunVoiceStatus,
                              siliconFlowVoiceUri: preset?.siliconFlowVoiceUri,
                              siliconFlowModel: preset?.siliconFlowModel,
                            );

                            if (isEdit) {
                              notifier.updateVoicePreset(newPreset);
                              MoeToast.success(context, '已保存');
                            } else {
                              notifier.addVoicePreset(newPreset);
                              // 自动选中新添加的音色
                              notifier.selectVoicePreset(newPreset.id);
                              MoeToast.success(context, '已添加');
                            }
                            Navigator.pop(context);
                          },
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// 显示音色操作菜单
  void _showVoicePresetActions(
    VoicePreset preset,
    TtsPluginConfigNotifier notifier,
    MoeColors colors,
  ) {
    final config = ref.read(ttsPluginConfigProvider);
    final isSelected = preset.id == config.selectedVoicePresetId;

    showMoeActionSheet(
      context: context,
      title: preset.name,
      description: preset.source, // 显示来源
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
          onTap: () => _showVoicePresetEditor(preset, notifier, colors),
        ),
        // 内置音色不能删除
        if (!preset.isBuiltIn)
          MoeSheetAction(
            icon: Icons.delete_outline,
            label: '删除',
            isDestructive: true,
            onTap: () {
              showMeoTalkDialog(
                context: context,
                title: '删除音色',
                content: Text('确定要删除「${preset.name}」吗？'),
                confirmText: '删除',
                isDanger: true,
              ).then((confirmed) {
                if (confirmed == true) {
                  notifier.deleteVoicePreset(preset.id);
                  MoeToast.success(context, '已删除');
                }
              });
            },
          ),
      ],
    );
  }

  /// 显示创建阿里云音色对话框
  void _showCreateAliyunVoiceDialog(
    VoicePreset preset,
    TtsPluginConfigNotifier notifier,
    MoeColors colors,
  ) {
    // 获取阿里云渠道的 API Key（不再依赖 tts capability，通过 requestFormat 或 id 识别）
    final appSettings = ref.read(appSettingsProvider).valueOrNull;
    final aliyunProvider = appSettings?.providers
        .where((p) => p.enabled)
        .where((p) {
          final format = p.customConfig['requestFormat'] as String?;
          return format == 'aliyun_cosyvoice' || format == 'aliyun_qwen_tts' ||
                 p.id == 'aliyun';
        })
        .firstOrNull;

    if (aliyunProvider == null || aliyunProvider.apiKeys.isEmpty) {
      MoeToast.warning(context, '请先在模型管理中配置阿里云 API Key');
      return;
    }

    // 选择要创建的模型类型
    showMoeActionSheet(
      context: context,
      title: '创建阿里云音色',
      description: '选择要使用的 TTS 模型',
      actions: [
        MoeSheetAction(
          icon: Icons.speed,
          label: 'CosyVoice v3-plus',
          subtitle: '最佳音质，推荐使用',
          onTap: () => _createAliyunVoice(
            preset: preset,
            notifier: notifier,
            apiKey: aliyunProvider.apiKeys.first,
            targetModel: 'cosyvoice-v3-plus',
            isCosyVoice: true,
          ),
        ),
        MoeSheetAction(
          icon: Icons.flash_on,
          label: 'CosyVoice v3-flash',
          subtitle: '平衡效果与成本',
          onTap: () => _createAliyunVoice(
            preset: preset,
            notifier: notifier,
            apiKey: aliyunProvider.apiKeys.first,
            targetModel: 'cosyvoice-v3-flash',
            isCosyVoice: true,
          ),
        ),
        MoeSheetAction(
          icon: Icons.bolt,
          label: 'Qwen-TTS',
          subtitle: '实时语音合成，即时可用',
          onTap: () => _createAliyunVoice(
            preset: preset,
            notifier: notifier,
            apiKey: aliyunProvider.apiKeys.first,
            targetModel: 'qwen3-tts-vc-realtime-2026-01-15',
            isCosyVoice: false,
          ),
        ),
      ],
    );
  }

  /// 创建阿里云音色
  Future<void> _createAliyunVoice({
    required VoicePreset preset,
    required TtsPluginConfigNotifier notifier,
    required String apiKey,
    required String targetModel,
    required bool isCosyVoice,
  }) async {
    final audioUrl = preset.promptAudioUrl;
    if (audioUrl == null || audioUrl.isEmpty) {
      MoeToast.warning(context, '音色缺少参考音频 URL');
      return;
    }

    // 显示加载提示
    MoeToast.info(context, '正在创建音色，请稍候...');

    try {
      final service = AliyunVoiceCloneService(apiKey: apiKey);
      String voiceId;
      String? voiceStatus;

      if (isCosyVoice) {
        // CosyVoice 需要轮询等待
        final result = await service.createCosyVoice(
          audioUrl: audioUrl,
          prefix: _sanitizeVoiceName(preset.name),
          targetModel: targetModel,
        );
        voiceId = result.voiceId;
        voiceStatus = result.status;

        // 提示用户需要等待审核
        if (mounted) {
          MoeToast.info(context, 'CosyVoice 音色已提交，等待审核中...');
        }
      } else {
        // Qwen-TTS 即时可用
        final result = await service.createQwenVoiceFromUrl(
          audioUrl: audioUrl,
          preferredName: _sanitizeVoiceName(preset.name),
          targetModel: targetModel,
          promptText: preset.promptText,
        );
        voiceId = result.voiceId;
        voiceStatus = 'OK';
      }

      // 更新音色预设
      final updatedPreset = preset.copyWith(
        aliyunVoiceId: voiceId,
        aliyunTargetModel: targetModel,
        aliyunVoiceStatus: voiceStatus,
      );
      notifier.updateVoicePreset(updatedPreset);

      if (mounted) {
        MoeToast.success(context, '阿里云音色创建成功！');
      }
    } catch (e) {
      if (mounted) {
        MoeToast.show(context, '创建失败: $e', type: ToastType.error);
      }
    }
  }

  /// 清理音色名称（用于阿里云 API）
  String _sanitizeVoiceName(String name) {
    // 只保留字母数字下划线，最多 10 个字符
    var sanitized = name.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '');
    if (sanitized.isEmpty) sanitized = 'voice';
    if (sanitized.length > 10) sanitized = sanitized.substring(0, 10);
    return sanitized.toLowerCase();
  }
}

/// TTS 模型列表条目（模型 ID + 所属渠道信息）
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

/// 获取音色弹窗内容
///
/// 展示渠道预置音色（硅基流动等平台的系统音色）
class _FetchVoicesSheetContent extends StatefulWidget {
  final TtsConfig config;
  final TtsPluginConfigNotifier notifier;
  final bool isSiliconFlow;
  final bool isAliyun;
  final String? apiKey;
  final void Function(VoicePreset voice) onVoiceSelected;

  const _FetchVoicesSheetContent({
    required this.config,
    required this.notifier,
    required this.isSiliconFlow,
    required this.isAliyun,
    required this.apiKey,
    required this.onVoiceSelected,
  });

  @override
  State<_FetchVoicesSheetContent> createState() => _FetchVoicesSheetContentState();
}

class _FetchVoicesSheetContentState extends State<_FetchVoicesSheetContent> {
  bool _loading = false;
  List<VoicePreset> _providerVoices = [];
  List<VoicePreset> _aliyunVoices = []; // 阿里云已创建的音色
  String? _error;
  String? _aliyunError;

  @override
  void initState() {
    super.initState();
    _loadProviderVoices();
    if (widget.isAliyun) {
      _loadAliyunVoices();
    }
  }

  /// 加载阿里云已创建的音色列表
  Future<void> _loadAliyunVoices() async {
    if (widget.apiKey == null || widget.apiKey!.isEmpty) {
      setState(() {
        _aliyunError = '未配置 API Key';
      });
      return;
    }

    setState(() {
      _loading = true;
      _aliyunError = null;
    });

    try {
      final service = AliyunVoiceCloneService(apiKey: widget.apiKey!);

      // 获取 Qwen-TTS 音色列表
      final qwenVoices = await service.listQwenVoices(pageSize: 100);

      final voices = qwenVoices.map((v) => VoicePreset(
        id: 'aliyun_${v.voiceId}', // 使用特殊前缀避免ID冲突
        name: _extractVoiceName(v.voiceId),
        sourceType: VoiceSourceType.preset,
        providerType: VoiceProviderType.aliyun,
        aliyunVoiceId: v.voiceId,
        aliyunTargetModel: v.targetModel,
        aliyunVoiceStatus: 'OK', // Qwen-TTS 音色创建后即可用
        source: '阿里云已创建 · ${v.gmtCreate ?? ""}',
      )).toList();

      if (!mounted) return;

      setState(() {
        _aliyunVoices = voices;
        _loading = false;
      });

      AppLogger.info('TTS', '获取阿里云音色列表成功', metadata: {
        'count': voices.length,
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _aliyunError = '获取失败: $e';
        _loading = false;
      });
      AppLogger.warning('TTS', '获取阿里云音色列表失败', metadata: {'error': e.toString()});
    }
  }

  /// 从音色ID中提取可读名称
  /// 例如：qwen-tts-vc-guanyu-voice-20250812105009984-838b -> guanyu
  String _extractVoiceName(String voiceId) {
    // 尝试提取 preferred_name 部分
    final parts = voiceId.split('-');
    if (parts.length >= 5) {
      // 格式：qwen-tts-vc-{name}-voice-{timestamp}-{suffix}
      final nameIndex = parts.indexOf('vc');
      if (nameIndex >= 0 && nameIndex + 1 < parts.length) {
        final name = parts[nameIndex + 1];
        if (name != 'voice') {
          return name;
        }
      }
    }
    // 如果无法提取，返回截断的ID
    return voiceId.length > 20 ? '${voiceId.substring(0, 20)}...' : voiceId;
  }

  Future<void> _loadProviderVoices() async {
    if (!widget.isSiliconFlow) return; // 目前只有硅基流动支持获取预置音色

    if (widget.apiKey == null || widget.apiKey!.isEmpty) {
      setState(() {
        _error = '该渠道未配置 API Key';
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      // 获取硅基流动预置音色
      final presetVoices = VoiceManagerService.getSiliconFlowPresetVoices();

      // 获取用户已上传的音色
      List<VoicePreset> userVoices = [];
      try {
        userVoices = await VoiceManagerService.getSiliconFlowUserVoices(widget.apiKey!);
      } catch (e) {
        AppLogger.warning('TTS', '获取用户音色失败', metadata: {'error': e.toString()});
      }

      if (!mounted) return;

      setState(() {
        _providerVoices = [...presetVoices, ...userVoices];
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '加载失败: $e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final existingIds = widget.config.voicePresets.map((p) => p.id).toSet();

    // 分组渠道音色
    final presetVoices = _providerVoices
        .where((v) => v.sourceType == VoiceSourceType.preset)
        .toList();
    final userUploadedVoices = _providerVoices
        .where((v) => v.sourceType != VoiceSourceType.preset)
        .toList();

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 渠道预置音色（硅基流动）
          if (widget.isSiliconFlow) ...[
            _buildSectionHeader('硅基流动预置音色', colors),
            if (_loading)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: colors.primary,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text('加载中...', style: TextStyle(color: colors.muted)),
                    ],
                  ),
                ),
              )
            else if (_error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(_error!, style: TextStyle(color: colors.accent, fontSize: 13)),
              )
            else if (presetVoices.isEmpty && userUploadedVoices.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text('暂无可用音色', style: TextStyle(color: colors.muted)),
              )
            else ...[
              ...presetVoices.map((voice) => _buildProviderVoiceItem(voice, existingIds, colors)),
              if (userUploadedVoices.isNotEmpty) ...[
                _buildSectionHeader('硅基流动已上传 (${userUploadedVoices.length})', colors),
                ...userUploadedVoices.map((voice) => _buildProviderVoiceItem(voice, existingIds, colors)),
              ],
            ],
          ],

          // 阿里云已创建的音色
          if (widget.isAliyun) ...[
            _buildSectionHeader('阿里云已创建音色', colors),
            if (_loading && _aliyunVoices.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: colors.primary,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text('正在获取...', style: TextStyle(color: colors.muted)),
                    ],
                  ),
                ),
              )
            else if (_aliyunError != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(_aliyunError!, style: TextStyle(color: colors.accent, fontSize: 13)),
              )
            else if (_aliyunVoices.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: MoeG2Decoration(
                    radius: 8,
                    color: colors.muted.withValues(alpha: 0.1),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline, color: colors.muted, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '暂无已创建的音色。请先添加音频并使用一次 TTS，系统会自动创建音色。',
                          style: TextStyle(color: colors.muted, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else
              ..._aliyunVoices.map((voice) => _buildAliyunVoiceItem(voice, existingIds, colors)),
          ],

          const SizedBox(height: 24),
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
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildProviderVoiceItem(
    VoicePreset voice,
    Set<String> existingIds,
    MoeColors colors,
  ) {
    final alreadyAdded = existingIds.contains(voice.id);

    return MoeSettingsRow(
      icon: alreadyAdded ? Icons.check : Icons.add_circle_outline,
      iconColor: alreadyAdded ? colors.primary : null,
      label: voice.name,
      subtitle: voice.source ?? (voice.sourceType == VoiceSourceType.preset ? '预置音色' : '用户上传'),
      trailingType: MoeSettingsRowTrailing.none,
      enabled: !alreadyAdded,
      onTap: alreadyAdded ? null : () => widget.onVoiceSelected(voice),
    );
  }

  /// 构建阿里云音色列表项
  Widget _buildAliyunVoiceItem(
    VoicePreset voice,
    Set<String> existingIds,
    MoeColors colors,
  ) {
    // 检查是否已经添加（通过 aliyunVoiceId 匹配）
    final alreadyAdded = widget.config.voicePresets.any(
      (p) => p.aliyunVoiceId == voice.aliyunVoiceId,
    );

    return MoeSettingsRow(
      icon: alreadyAdded ? Icons.check : Icons.cloud_done,
      iconColor: alreadyAdded ? colors.primary : colors.textSecondary,
      label: voice.name,
      subtitle: voice.aliyunTargetModel ?? '阿里云音色',
      trailingType: MoeSettingsRowTrailing.custom,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 删除按钮
          GestureDetector(
            onTap: () => _confirmDeleteAliyunVoice(voice, colors),
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Icon(
                Icons.delete_outline,
                size: 20,
                color: colors.muted,
              ),
            ),
          ),
          // 添加按钮（如果未添加）
          if (!alreadyAdded)
            GestureDetector(
              onTap: () => widget.onVoiceSelected(voice),
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
      ),
      enabled: true,
      onTap: alreadyAdded ? null : () => widget.onVoiceSelected(voice),
    );
  }

  /// 确认删除阿里云音色
  Future<void> _confirmDeleteAliyunVoice(VoicePreset voice, MoeColors colors) async {
    final confirmed = await showMeoTalkDialog(
      context: context,
      title: '删除阿里云音色',
      content: Text('确定要从阿里云删除「${voice.name}」吗？\n\n删除后将释放音色额度，此操作不可恢复。'),
      confirmText: '删除',
      isDanger: true,
    );

    if (confirmed != true) return;

    // 显示加载提示
    MoeToast.info(context, '正在删除...');

    try {
      final service = AliyunVoiceCloneService(apiKey: widget.apiKey!);

      // 根据音色ID格式判断是 Qwen-TTS 还是 CosyVoice
      final voiceId = voice.aliyunVoiceId!;
      if (voiceId.contains('qwen') || voiceId.contains('tts-vc')) {
        await service.deleteQwenVoice(voiceId);
      } else {
        await service.deleteCosyVoice(voiceId);
      }

      // 从列表中移除
      setState(() {
        _aliyunVoices.removeWhere((v) => v.aliyunVoiceId == voiceId);
      });

      if (mounted) {
        MoeToast.success(context, '已删除「${voice.name}」');
      }

      AppLogger.info('TTS', '阿里云音色已删除', metadata: {
        'voiceId': voiceId,
        'voiceName': voice.name,
      });
    } catch (e) {
      if (mounted) {
        MoeToast.error(context, '删除失败: $e');
      }
      AppLogger.warning('TTS', '删除阿里云音色失败', metadata: {'error': e.toString()});
    }
  }
}
