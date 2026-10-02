/// ModelRowTile - 模型行组件
///
/// 从 model_list_page.dart 提取，显示单个模型的信息。
///
/// 设计特点：
/// - 显示模型ID和备注名
/// - 支持编辑备注和类型
/// - 支持切换可见性
/// - 显示模型特性标签和类型标签
/// - 支持复制模型原始ID
///
/// 更新记录：
/// - 2026-01-27: 添加模型类型标签、复制按钮、类型编辑功能
/// - 2026-01-25: 添加模型特性标签显示（视觉/工具/思考/联网）
/// - 2025-12-31: 从 model_list_page.dart 提取
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/api/providers/provider_adapter_factory.dart';
import '../../../../core/api/thinking/thinking_level.dart';
import '../../../../core/api/thinking/thinking_level_catalog.dart';
import '../../../../core/api/thinking/thinking_level_labels.dart';
import '../../../../features/chat/presentation/widgets/thinking_level_sheet.dart';
import '../../../../features/settings/app_settings.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/widgets/index.dart';

/// 模型行组件（用于已显示模型列表）
class ModelRowTile extends ConsumerWidget {
  final String providerId;
  final String model;
  final String? displayName;
  final bool copyOnLongPress;

  const ModelRowTile({
    super.key,
    required this.providerId,
    required this.model,
    required this.displayName,
    this.copyOnLongPress = true,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.moeColors;
    final cs = Theme.of(context).colorScheme;
    final hasDisplayName = displayName != null && displayName!.isNotEmpty;

    // 获取模型类型和配置
    final settings = ref.watch(appSettingsProvider).valueOrNull;
    final modelRef = settings?.buildModelRef(providerId, model) ?? model;
    final modelType = settings?.getModelType(modelRef) ?? ModelType.chat;
    final modelConfig =
        settings?.getModelConfig(modelRef) ?? const ModelConfig();
    final features = modelType == ModelType.chat
        ? (settings
                  ?.getChatModelCapabilities(modelRef)
                  .map((cap) => ModelFeature.fromValue(cap.value))
                  .whereType<ModelFeature>()
                  .toList() ??
              inferModelFeatures(model))
        : const <ModelFeature>[];

    return MoeSettingsRow(
      label: hasDisplayName ? displayName! : model,
      labelMaxLines: 1,
      subtitleWidget: _buildSubtitle(
        colors,
        hasDisplayName,
        modelType,
        features,
      ),
      trailingType: MoeSettingsRowTrailing.custom,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 复制模型ID按钮
          MoeIconButton(
            icon: Icons.copy_outlined,
            size: 16,
            padding: const EdgeInsets.all(6),
            minTouchTarget: 32,
            color: colors.muted,
            onTap: () => _copyModelId(context, model),
          ),
          const SizedBox(width: 2),
          MoeIconButton(
            icon: Icons.edit_outlined,
            size: 18,
            padding: const EdgeInsets.all(6),
            minTouchTarget: 32,
            color: colors.muted,
            onTap: () => _showEditModelDialog(
              context: context,
              ref: ref,
              modelId: model,
              modelRef: modelRef,
              currentDisplayName: displayName,
              currentType: modelType,
              currentConfig: modelConfig,
            ),
          ),
          const SizedBox(width: 2),
          MoeIconButton(
            icon: Icons.delete_outline,
            size: 18,
            padding: const EdgeInsets.all(6),
            minTouchTarget: 32,
            color: cs.error,
            onTap: () => _confirmDeleteModel(
              context: context,
              ref: ref,
              providerId: providerId,
              modelId: model,
              displayName: displayName,
            ),
          ),
        ],
      ),
      onTap: () => _showEditModelDialog(
        context: context,
        ref: ref,
        modelId: model,
        modelRef: modelRef,
        currentDisplayName: displayName,
        currentType: modelType,
        currentConfig: modelConfig,
      ),
      onLongPress: copyOnLongPress ? () => _copyModelId(context, model) : null,
    );
  }

  /// 复制模型ID（原始名称）
  void _copyModelId(BuildContext context, String modelId) {
    Clipboard.setData(ClipboardData(text: modelId));
    HapticFeedback.mediumImpact();
    MoeToast.brief(context, '已复制: $modelId');
  }

  /// 构建副标题区域（模型ID + 类型标签 + 特性标签）
  Widget? _buildSubtitle(
    MoeColors colors,
    bool hasDisplayName,
    ModelType modelType,
    List<ModelFeature> features,
  ) {
    // chat 类型不显示标签（默认类型）
    final showTypeTag = modelType != ModelType.chat;
    final hasFeatures = features.isNotEmpty;

    if (!hasDisplayName && !hasFeatures && !showTypeTag) return null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // 第一行：模型ID（如果有备注名）
        if (hasDisplayName)
          Text(
            model,
            style: TextStyle(fontSize: 12, color: colors.muted),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        // 第二行：类型标签 + 特性标签
        if (showTypeTag || hasFeatures)
          Padding(
            padding: EdgeInsets.only(top: hasDisplayName ? 4 : 0),
            child: Row(
              children: [
                // 模型类型标签（非 chat 类型才显示）
                if (showTypeTag) ...[
                  _ModelTypeChip(type: modelType),
                  if (hasFeatures) const SizedBox(width: 4),
                ],
                // 模型特性标签
                if (hasFeatures)
                  ModelFeatureChips(
                    modelId: model,
                    maxShow: 2,
                    features: features,
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Future<void> _confirmDeleteModel({
    required BuildContext context,
    required WidgetRef ref,
    required String providerId,
    required String modelId,
    String? displayName,
  }) async {
    final label = (displayName != null && displayName.isNotEmpty)
        ? '「$displayName」($modelId)'
        : '「$modelId」';

    final confirmed = await showMeoTalkDialog(
      context: context,
      title: '删除模型',
      content: Text('确定要从该渠道中删除 $label 吗？'),
      confirmText: '删除',
      cancelText: '取消',
    );

    if (confirmed != true) return;

    try {
      await ref
          .read(appSettingsProvider.notifier)
          .deleteProviderModel(providerId: providerId, modelId: modelId);
      if (!context.mounted) return;
      MoeToast.success(context, '已删除模型');
    } catch (e) {
      if (!context.mounted) return;
      MoeToast.error(context, '删除失败: $e');
    }
  }

  /// 显示编辑模型弹窗（支持修改备注、类型、工具调用、模型参数）
  Future<void> _showEditModelDialog({
    required BuildContext context,
    required WidgetRef ref,
    required String modelId,
    required String modelRef,
    String? currentDisplayName,
    required ModelType currentType,
    required ModelConfig currentConfig,
  }) async {
    final ctrl = TextEditingController(text: currentDisplayName ?? '');
    final tempCtrl = TextEditingController(
      text: currentConfig.temperature?.toStringAsFixed(1) ?? '',
    );
    final topPCtrl = TextEditingController(
      text: currentConfig.topP?.toStringAsFixed(2) ?? '',
    );
    final ctxLimitCtrl = TextEditingController(
      text: currentConfig.contextMessageLimit?.toString() ?? '',
    );
    final maxCtxTokensCtrl = TextEditingController(
      text: currentConfig.maxContextTokens?.toString() ?? '',
    );
    var selectedType = currentType;
    var disableToolCalling = currentConfig.disableToolCalling;
    var selectedThinkingLevel = currentConfig.thinkingLevel;
    final settingsSnapshot = ref.read(appSettingsProvider).valueOrNull;
    final providerAuth = settingsSnapshot?.providers
        .where(
          (p) => p.id == (settingsSnapshot.getModelProviderId(modelRef) ?? ''),
        )
        .firstOrNull;
    final thinkingOptions = resolveThinkingOptions(
      providerType: ProviderAdapterFactory.resolveProvider(
        settingsSnapshot?.getModelProviderId(modelRef) ?? 'openai',
        customConfig: providerAuth?.customConfig,
        apiBaseUrl: providerAuth?.apiBaseUrl,
      ),
      modelId: modelId,
    );
    var useAutoCapabilities = currentConfig.chatCapabilities == null;
    var selectedCapabilities = <String>{
      ...(currentConfig.chatCapabilities ??
          inferChatModelCapabilities(modelId).map((cap) => cap.value)),
    };

    Future<void> saveModel() async {
      final displayName = ctrl.text.trim().isEmpty ? null : ctrl.text.trim();
      final type = selectedType;
      final disableTools = disableToolCalling;
      final thinking = selectedThinkingLevel;
      final automaticCapabilities = useAutoCapabilities;
      // 解析参数值
      final tempText = tempCtrl.text.trim();
      final topPText = topPCtrl.text.trim();
      final ctxText = ctxLimitCtrl.text.trim();
      final maxCtxTokensText = maxCtxTokensCtrl.text.trim();
      final manualChatCapabilities = ChatModelCapability.values
          .where(
            (capability) => selectedCapabilities.contains(capability.value),
          )
          .map((capability) => capability.value)
          .toList();

      for (final entry in {'温度': tempText, 'Top P': topPText}.entries) {
        if (entry.value.isNotEmpty &&
            (double.tryParse(entry.value)?.isFinite != true)) {
          throw FormatException('${entry.key}请输入有效数字');
        }
      }
      for (final entry in {
        '上下文条数': ctxText,
        '上下文长度': maxCtxTokensText,
      }.entries) {
        if (entry.value.isNotEmpty &&
            (int.tryParse(entry.value) == null ||
                int.parse(entry.value) <= 0)) {
          throw FormatException('${entry.key}请输入正整数');
        }
      }
      final notifier = ref.read(appSettingsProvider.notifier);

      // 保存显示名称
      await notifier.setModelDisplayName(
        modelId: modelRef,
        displayName: displayName,
      );

      // 保存模型类型
      await notifier.setModelType(modelId: modelRef, type: type);

      // 保存模型配置（包括工具调用、温度、TopP、上下文数）
      await notifier.updateModelConfig(
        modelId: modelRef,
        disableToolCalling: disableTools,
        temperature: tempText.isNotEmpty ? double.tryParse(tempText) : null,
        clearTemperature: tempText.isEmpty,
        topP: topPText.isNotEmpty ? double.tryParse(topPText) : null,
        clearTopP: topPText.isEmpty,
        contextMessageLimit: ctxText.isNotEmpty ? int.tryParse(ctxText) : null,
        clearContextMessageLimit: ctxText.isEmpty,
        maxContextTokens: maxCtxTokensText.isNotEmpty
            ? int.tryParse(maxCtxTokensText)
            : null,
        clearMaxContextTokens: maxCtxTokensText.isEmpty,
        thinkingLevel: thinking,
        clearThinkingLevel: thinking == null,
        chatCapabilities: type == ModelType.chat && !automaticCapabilities
            ? manualChatCapabilities
            : null,
        clearChatCapabilities: type != ModelType.chat || automaticCapabilities,
      );
    }

    await showMoeBottomSheet<void>(
      context: context,
      title: '编辑模型',
      showCloseButton: true,
      isDismissible: false,
      enableDrag: false,
      builder: (context) => MoeAutoSaveForm(
        disposeFields: true,
        save: saveModel,
        snapshot: () => moeAutoSaveSignature([
          ctrl.text,
          tempCtrl.text,
          topPCtrl.text,
          ctxLimitCtrl.text,
          maxCtxTokensCtrl.text,
          selectedType.name,
          disableToolCalling,
          selectedThinkingLevel,
          useAutoCapabilities,
          selectedCapabilities.toList()..sort(),
        ]),
        fields: [ctrl, tempCtrl, topPCtrl, ctxLimitCtrl, maxCtxTokensCtrl],
        builder: (context, setSheetState) => Padding(
          padding: const EdgeInsets.all(16),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 模型ID（带复制按钮）
                Row(
                  children: [
                    Text(
                      '模型ID: ',
                      style: TextStyle(
                        fontSize: 12,
                        color: context.moeColors.muted,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        modelId,
                        style: TextStyle(
                          fontSize: 12,
                          color: context.moeColors.text,
                          fontFamily: 'monospace',
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    MoeIconButton(
                      icon: Icons.copy_outlined,
                      size: 14,
                      color: context.moeColors.muted,
                      onTap: () {
                        Clipboard.setData(ClipboardData(text: modelId));
                        HapticFeedback.lightImpact();
                        MoeToast.brief(context, '已复制');
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // 显示名称输入
                TextFormField(
                  controller: ctrl,
                  decoration: const InputDecoration(
                    labelText: '显示名称（备注）',
                    hintText: '留空则显示原始ID',
                    border: OutlineInputBorder(),
                  ),
                  autofocus: true,
                ),
                const SizedBox(height: 16),

                // 模型类型选择
                Text(
                  '模型类型',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: MoeFontWeights.emphasis,
                    color: context.moeColors.text,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: ModelType.values.map((type) {
                    final isSelected = type == selectedType;
                    return GestureDetector(
                      onTap: () {
                        setSheetState(() => selectedType = type);
                        HapticFeedback.selectionClick();
                      },
                      child: MoeButtonSurface(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        tintColor: isSelected
                            ? type.color.withValues(alpha: 0.15)
                            : context.moeColors.componentBackground,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: isSelected
                              ? type.color
                              : context.moeColors.border,
                          width: isSelected ? 1.5 : 1,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              type.icon,
                              size: 16,
                              color: isSelected
                                  ? type.color
                                  : context.moeColors.muted,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              type.label,
                              style: TextStyle(
                                fontSize: 13,
                                color: isSelected
                                    ? type.color
                                    : context.moeColors.text,
                                fontWeight: isSelected
                                    ? MoeFontWeights.emphasis
                                    : MoeFontWeights.normal,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                ),

                if (selectedType == ModelType.chat) ...[
                  const SizedBox(height: 16),
                  Text(
                    '对话能力标签',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: MoeFontWeights.emphasis,
                      color: context.moeColors.text,
                    ),
                  ),
                  Text(
                    '仅用于 chat 模型，可自动识别或手动指定。',
                    style: TextStyle(
                      fontSize: 11,
                      color: context.moeColors.muted,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: context.moeColors.componentBackground,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: context.moeColors.border),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.auto_awesome_outlined,
                          size: 18,
                          color: context.moeColors.muted,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '自动识别能力',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: context.moeColors.text,
                                ),
                              ),
                              Text(
                                '关闭后可手动选择：视觉 / 工具 / 推理 / 联网',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: context.moeColors.muted,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Switch(
                          value: useAutoCapabilities,
                          onChanged: (value) {
                            setSheetState(() => useAutoCapabilities = value);
                            HapticFeedback.selectionClick();
                          },
                        ),
                      ],
                    ),
                  ),
                  if (useAutoCapabilities)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '自动模式将按模型名推断能力标签。',
                            style: TextStyle(
                              fontSize: 11,
                              color: context.moeColors.muted,
                            ),
                          ),
                          const SizedBox(height: 6),
                          ModelFeatureChips(
                            modelId: modelId,
                            showIcon: true,
                            maxShow: 4,
                          ),
                        ],
                      ),
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: ChatModelCapability.values.map((capability) {
                          final feature = ModelFeature.fromValue(
                            capability.value,
                          );
                          if (feature == null) return const SizedBox.shrink();
                          final isSelected = selectedCapabilities.contains(
                            capability.value,
                          );
                          return GestureDetector(
                            onTap: () {
                              setSheetState(() {
                                if (isSelected) {
                                  selectedCapabilities.remove(capability.value);
                                } else {
                                  selectedCapabilities.add(capability.value);
                                }
                              });
                              HapticFeedback.selectionClick();
                            },
                            child: MoeButtonSurface(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              tintColor: isSelected
                                  ? feature.color.withValues(alpha: 0.15)
                                  : context.moeColors.componentBackground,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: isSelected
                                    ? feature.color
                                    : context.moeColors.border,
                                width: isSelected ? 1.5 : 1,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    feature.icon,
                                    size: 16,
                                    color: isSelected
                                        ? feature.color
                                        : context.moeColors.muted,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    feature.label,
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: isSelected
                                          ? feature.color
                                          : context.moeColors.text,
                                      fontWeight: isSelected
                                          ? MoeFontWeights.emphasis
                                          : MoeFontWeights.normal,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                ],

                // 模型参数
                const SizedBox(height: 16),
                Text(
                  '模型参数',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: MoeFontWeights.emphasis,
                    color: context.moeColors.text,
                  ),
                ),
                Text(
                  '为空时使用全局默认值',
                  style: TextStyle(
                    fontSize: 11,
                    color: context.moeColors.muted,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: tempCtrl,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: InputDecoration(
                          labelText: '温度',
                          hintText: '默认',
                          hintStyle: TextStyle(color: context.moeColors.muted),
                          border: const OutlineInputBorder(),
                          helperText: '0~2',
                          helperStyle: TextStyle(
                            fontSize: 10,
                            color: context.moeColors.muted,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextFormField(
                        controller: topPCtrl,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: InputDecoration(
                          labelText: 'Top P',
                          hintText: '关闭',
                          hintStyle: TextStyle(color: context.moeColors.muted),
                          border: const OutlineInputBorder(),
                          helperText: '0~1',
                          helperStyle: TextStyle(
                            fontSize: 10,
                            color: context.moeColors.muted,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextFormField(
                        controller: ctxLimitCtrl,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: '上下文数',
                          hintText: '自动',
                          hintStyle: TextStyle(color: context.moeColors.muted),
                          border: const OutlineInputBorder(),
                          helperText: '消息条数',
                          helperStyle: TextStyle(
                            fontSize: 10,
                            color: context.moeColors.muted,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: maxCtxTokensCtrl,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: '最大上下文 Token',
                    hintText: '自动',
                    hintStyle: TextStyle(color: context.moeColors.muted),
                    border: const OutlineInputBorder(),
                    helperText: '留空=按模型名自动判断',
                    helperStyle: TextStyle(
                      fontSize: 10,
                      color: context.moeColors.muted,
                    ),
                  ),
                ),

                // 默认思考档位
                const SizedBox(height: 16),
                _ThinkingLevelField(
                  options: thinkingOptions,
                  value: selectedThinkingLevel,
                  onTap: () async {
                    final result = await showThinkingLevelSheet(
                      context,
                      title: '默认思考档位',
                      options: thinkingOptions,
                      current:
                          selectedThinkingLevel ??
                          thinkingOptions.softwareDefault,
                      currentSource: selectedThinkingLevel == null
                          ? ThinkingLevelSource.softwareDefault
                          : ThinkingLevelSource.model,
                      hasOwnSetting: selectedThinkingLevel != null,
                      clearLabel: '清除模型默认，改用软件默认',
                    );
                    if (result == null) return;
                    setSheetState(() {
                      selectedThinkingLevel = result.cleared
                          ? null
                          : result.level;
                    });
                  },
                ),

                // 禁用工具调用开关
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: context.moeColors.componentBackground,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: context.moeColors.border),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.build_outlined,
                        size: 18,
                        color: context.moeColors.muted,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '禁用工具调用',
                              style: TextStyle(
                                fontSize: 14,
                                color: context.moeColors.text,
                              ),
                            ),
                            Text(
                              '开启后 AI 无法使用语音、提醒等插件',
                              style: TextStyle(
                                fontSize: 11,
                                color: context.moeColors.muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Switch(
                        value: disableToolCalling,
                        onChanged: (value) {
                          setSheetState(() => disableToolCalling = value);
                          HapticFeedback.selectionClick();
                        },
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 模型类型标签组件
class _ThinkingLevelField extends StatelessWidget {
  const _ThinkingLevelField({
    required this.options,
    required this.value,
    required this.onTap,
  });

  final ThinkingLevelOptions options;
  final ThinkingLevel? value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final effective = value ?? options.softwareDefault;
    final title = thinkingLevelTitle(effective, isNative: options.isNative);
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: MoeButtonSurface(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        tintColor: Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.border),
        child: Row(
          children: [
            Icon(Icons.psychology_outlined, size: 18, color: colors.muted),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '默认思考档位',
                    style: TextStyle(fontSize: 14, color: colors.text),
                  ),
                  Text(
                    value == null
                        ? '软件默认（$title）· 会话内可单独调整'
                        : '$title · ${thinkingLevelHint(effective)}',
                    style: TextStyle(fontSize: 11, color: colors.muted),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 18, color: colors.muted),
          ],
        ),
      ),
    );
  }
}

class _ModelTypeChip extends StatelessWidget {
  const _ModelTypeChip({required this.type});

  final ModelType type;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = type.color.withValues(alpha: isDark ? 0.2 : 0.12);
    final fgColor = isDark ? type.color.withValues(alpha: 0.9) : type.color;

    return Container(
      height: 16,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(type.icon, size: 10, color: fgColor),
          const SizedBox(width: 3),
          Text(
            type.label,
            style: TextStyle(
              fontSize: 10,
              color: fgColor,
              fontWeight: MoeFontWeights.emphasis,
              height: 1,
            ),
          ),
        ],
      ),
    );
  }
}
