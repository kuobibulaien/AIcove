/// DefaultModelSettingsPage - 默认模型设置页面
///
/// 设置默认聊天模型（多选，有序，支持轮询）和图片识别模型（单选）。
///
/// 更新记录：
/// - 2026-02-20: 创建
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/settings/app_settings.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/shared/widgets/index.dart';

/// 默认模型设置页面
class DefaultModelSettingsPage extends ConsumerStatefulWidget {
  const DefaultModelSettingsPage({super.key});

  @override
  ConsumerState<DefaultModelSettingsPage> createState() =>
      _DefaultModelSettingsPageState();
}

class _DefaultModelSettingsPageState
    extends ConsumerState<DefaultModelSettingsPage> {
  /// 本地状态：选中的聊天模型列表（有序）
  List<String>? _localChatModels;

  /// 本地状态：选中的图片识别模型
  String? _localVisionModel;
  bool _visionInitialized = false;
  bool? _localPreferVisionAssistant;
  bool _preferVisionInitialized = false;

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(appSettingsProvider);
    final colors = context.moeColors;

    return Scaffold(
      appBar: const MoeAppBar(title: '默认模型设置', showBackButton: true),
      backgroundColor: colors.surface,
      body: settingsAsync.when(
        loading: () =>
            const Center(child: MoeLoadingIndicator(message: '加载中...')),
        error: (e, _) => Center(child: Text('加载失败: $e')),
        data: (settings) => _buildBody(settings, colors),
      ),
    );
  }

  Widget _buildBody(AppSettings settings, MoeColors colors) {
    // 收集所有启用供应商中的 chat 类型模型
    final chatModels = <_ModelEntry>[];
    for (final provider in settings.providers) {
      if (!provider.enabled) continue;
      for (final modelId in provider.visibleModels) {
        final type = settings.getModelType(modelId);
        if (type == ModelType.chat) {
          chatModels.add(_ModelEntry(
            modelRef: settings.buildModelRef(provider.id, modelId),
            modelId: modelId,
            providerId: provider.id,
            providerName: provider.displayName ?? provider.id,
            displayName: settings.getModelDisplayName(modelId),
          ));
        }
      }
    }

    // 初始化本地状态
    final selectedChatModels = _localChatModels ?? settings.defaultChatModels;
    if (!_visionInitialized) {
      _localVisionModel = settings.defaultVisionModel;
      _visionInitialized = true;
    }
    if (!_preferVisionInitialized) {
      _localPreferVisionAssistant = settings.preferVisionAssistant;
      _preferVisionInitialized = true;
    }
    final preferVisionAssistant =
        _localPreferVisionAssistant ?? settings.preferVisionAssistant;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        // ============ 默认聊天模型 ============
        _buildSectionHeader(colors, '默认聊天模型', '可多选，失败后自动尝试下一个模型'),
        const SizedBox(height: 8),
        MoeSettingsGroup(
          margin: EdgeInsets.zero,
          padding: EdgeInsets.zero,
          children: [
            if (chatModels.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  '暂无可用的聊天模型，请先添加供应商',
                  style: TextStyle(color: colors.muted, fontSize: 13),
                ),
              )
            else
              ...chatModels.map((entry) {
                final isSelected = selectedChatModels.contains(entry.modelRef);
                final order = selectedChatModels.indexOf(entry.modelRef);
                return MoeSettingsRow(
                  iconWidget: _buildOrderBadge(isSelected, order, colors),
                  iconContainerWidth: 28,
                  label: entry.displayName,
                  subtitle: entry.providerName,
                  trailingType: MoeSettingsRowTrailing.custom,
                  trailing: MoeCheckbox(
                    value: isSelected,
                    onChanged: (_) =>
                        _toggleChatModel(entry.modelRef, settings),
                    size: MoeCheckboxSize.md,
                  ),
                  onTap: () => _toggleChatModel(entry.modelRef, settings),
                  showDivider: entry != chatModels.last,
                );
              }),
          ],
        ),

        const SizedBox(height: 24),

        // ============ 图片识别模型 ============
        _buildSectionHeader(colors, '图片识别模型', '发送图片时使用的模型'),
        const SizedBox(height: 8),
        MoeSettingsGroup(
          margin: EdgeInsets.zero,
          padding: EdgeInsets.zero,
          children: [
            MoeSettingsRow(
              icon: Icons.swap_horiz_outlined,
              label: '优先使用视觉辅助模型',
              subtitle: '开启后发送图片会先尝试图片识别模型，再回退聊天模型',
              trailingType: MoeSettingsRowTrailing.switchControl,
              switchValue: preferVisionAssistant,
              onSwitchChanged: (value) =>
                  _togglePreferVisionAssistant(value, settings),
              showDivider: true,
            ),
            if (chatModels.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  '暂无可用的模型',
                  style: TextStyle(color: colors.muted, fontSize: 13),
                ),
              )
            else ...[
              // "跟随聊天模型" 选项
              MoeSettingsRow(
                iconWidget: Icon(Icons.sync, color: colors.muted, size: 18),
                iconContainerWidth: 28,
                label: '跟随聊天模型',
                subtitle: '使用默认聊天模型处理图片',
                trailingType: MoeSettingsRowTrailing.custom,
                trailing: Icon(
                  _localVisionModel == null
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color:
                      _localVisionModel == null ? colors.primary : colors.muted,
                  size: 20,
                ),
                onTap: () => _selectVisionModel(null),
                showDivider: true,
              ),
              ...chatModels.map((entry) {
                final isSelected = _localVisionModel == entry.modelRef;
                return MoeSettingsRow(
                  iconWidget: Icon(
                    Icons.visibility_outlined,
                    color: isSelected ? colors.primary : colors.muted,
                    size: 18,
                  ),
                  iconContainerWidth: 28,
                  label: entry.displayName,
                  subtitle: entry.providerName,
                  trailingType: MoeSettingsRowTrailing.custom,
                  trailing: Icon(
                    isSelected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    color: isSelected ? colors.primary : colors.muted,
                    size: 20,
                  ),
                  onTap: () => _selectVisionModel(entry.modelRef),
                  showDivider: entry != chatModels.last,
                );
              }),
            ],
          ],
        ),
      ],
    );
  }

  Widget _buildSectionHeader(
      MoeColors colors, String title, String description) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 14,
            fontWeight: MoeFontWeights.emphasis,
            color: colors.text,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          description,
          style: TextStyle(fontSize: 12, color: colors.muted),
        ),
      ],
    );
  }

  Widget _buildOrderBadge(bool isSelected, int order, MoeColors colors) {
    if (!isSelected) {
      return SizedBox(
        width: 20,
        height: 20,
        child: Center(
          child: MoeG2ClipRRect(
            radius: 10,
            child: Container(
              width: 20,
              height: 20,
              decoration: MoeG2Decoration(
                radius: 10,
                color: colors.muted.withValues(alpha: 0.15),
              ),
              child: Center(
                child: Text(
                  '-',
                  style: TextStyle(
                    fontSize: 11,
                    color: colors.muted,
                    fontWeight: MoeFontWeights.emphasis,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }
    return SizedBox(
      width: 20,
      height: 20,
      child: Center(
        child: MoeG2ClipRRect(
          radius: 10,
          child: Container(
            width: 20,
            height: 20,
            decoration: MoeG2Decoration(
              radius: 10,
              color: colors.primary.withValues(alpha: 0.15),
            ),
            child: Center(
              child: Text(
                '${order + 1}',
                style: TextStyle(
                  fontSize: 11,
                  color: colors.primary,
                  fontWeight: MoeFontWeights.emphasis,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _toggleChatModel(String modelRef, AppSettings settings) {
    setState(() {
      final current =
          List<String>.from(_localChatModels ?? settings.defaultChatModels);
      if (current.contains(modelRef)) {
        current.remove(modelRef);
      } else {
        current.add(modelRef);
      }
      _localChatModels = current;
    });

    // 保存
    ref
        .read(appSettingsProvider.notifier)
        .setDefaultChatModels(_localChatModels!);
  }

  void _selectVisionModel(String? modelId) {
    final shouldDisablePreferVisionAssistant =
        (modelId == null || modelId.trim().isEmpty) &&
            (_localPreferVisionAssistant == true);
    setState(() {
      _localVisionModel = modelId;
      if (shouldDisablePreferVisionAssistant) {
        _localPreferVisionAssistant = false;
      }
    });
    final notifier = ref.read(appSettingsProvider.notifier);
    notifier.setDefaultVisionModel(modelId);
    if (shouldDisablePreferVisionAssistant) {
      notifier.setPreferVisionAssistant(false);
      MoeToast.info(context, '已关闭“优先使用视觉辅助模型”');
    }
  }

  void _togglePreferVisionAssistant(bool value, AppSettings settings) {
    if (value) {
      final selectedVisionModel =
          (_localVisionModel ?? settings.defaultVisionModel)?.trim();
      if (selectedVisionModel == null || selectedVisionModel.isEmpty) {
        MoeToast.warning(context, '请先选择图片识别模型');
        setState(() {
          _localPreferVisionAssistant = false;
        });
        return;
      }
    }

    setState(() {
      _localPreferVisionAssistant = value;
    });
    ref.read(appSettingsProvider.notifier).setPreferVisionAssistant(value);
  }
}

/// 模型条目
class _ModelEntry {
  final String modelRef;
  final String modelId;
  final String providerId;
  final String providerName;
  final String displayName;

  const _ModelEntry({
    required this.modelRef,
    required this.modelId,
    required this.providerId,
    required this.providerName,
    required this.displayName,
  });
}
