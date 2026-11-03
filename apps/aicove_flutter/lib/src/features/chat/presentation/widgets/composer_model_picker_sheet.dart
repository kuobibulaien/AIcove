library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/settings/app_settings.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/theme/tokens.dart';

/// 模型选择结果；[modelRef] 为 null 表示本会话跟随默认模型。
class ComposerModelSelection {
  const ComposerModelSelection(this.modelRef);

  final String? modelRef;
}

/// 按渠道分组的可见聊天模型。
class ComposerProviderModelGroup {
  const ComposerProviderModelGroup({
    required this.providerId,
    required this.providerName,
    required this.models,
  });

  final String providerId;
  final String providerName;
  final List<String> models;
}

/// [sessionModel] 是本会话持久化的模型引用（含可能已隐藏或停用的旧值），
/// null 或空串表示正在跟随默认模型。
Future<ComposerModelSelection?> showComposerModelPickerSheet(
  BuildContext context, {
  String? sessionModel,
}) {
  return showMoeBottomSheet<ComposerModelSelection>(
    context: context,
    title: '选择模型',
    useRootNavigator: true,
    builder: (_) => _ComposerModelPickerSheet(sessionModel: sessionModel),
  );
}

@visibleForTesting
String? composerResolvePrimaryDefaultModel(AppSettings settings) {
  final visibleModels = settings.modelList.toSet();
  for (final modelRef in settings.defaultChatModels) {
    final normalized = modelRef.trim();
    if (normalized.isNotEmpty && visibleModels.contains(normalized)) {
      return normalized;
    }
  }
  final fallback = settings.defaultModelName.trim();
  if (fallback.isNotEmpty && visibleModels.contains(fallback)) {
    return fallback;
  }
  return settings.modelList.isNotEmpty ? settings.modelList.first : null;
}

@visibleForTesting
List<ComposerProviderModelGroup> composerGroupModelsByProvider(
  AppSettings settings,
) {
  final grouped = <String, List<String>>{};
  for (final rawRef in settings.modelList) {
    final modelRef = rawRef.trim();
    if (modelRef.isEmpty) continue;
    final providerId = settings.getModelProviderId(modelRef) ?? '';
    final list = grouped.putIfAbsent(providerId, () => <String>[]);
    if (!list.contains(modelRef)) {
      list.add(modelRef);
    }
  }

  return grouped.entries
      .map(
        (entry) => ComposerProviderModelGroup(
          providerId: entry.key,
          providerName: entry.key.isEmpty
              ? '可选模型'
              : settings.getProviderDisplayName(entry.key),
          models: List<String>.unmodifiable(entry.value),
        ),
      )
      .toList(growable: false);
}

String _formatModelWithProvider(AppSettings settings, String modelRef) {
  final modelName = settings.getModelDisplayName(modelRef);
  final providerId = settings.getModelProviderId(modelRef);
  if (providerId == null || providerId.isEmpty) {
    return modelName;
  }
  final providerName = settings.getProviderDisplayName(providerId);
  if (providerName.isEmpty) {
    return modelName;
  }
  return '$modelName（$providerName）';
}

class _ComposerModelPickerSheet extends ConsumerWidget {
  const _ComposerModelPickerSheet({this.sessionModel});

  final String? sessionModel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsAsync = ref.watch(appSettingsProvider);

    return settingsAsync.when(
      loading: () => const Center(child: MoeLoadingIndicator()),
      error: (error, _) => MoeEmptyState(
        icon: Icons.error_outline,
        title: '加载失败',
        description: '$error',
      ),
      data: (settings) => _buildContent(context, settings),
    );
  }

  Widget _buildContent(BuildContext context, AppSettings settings) {
    final colors = context.moeColors;

    if (settings.modelList.isEmpty) {
      return const MoeEmptyState(
        icon: Icons.model_training_outlined,
        title: '暂无可用模型',
        description: '请先在设置中配置至少一个可见模型',
      );
    }

    final rawSessionModel = sessionModel?.trim() ?? '';
    final isStaleSessionModel =
        rawSessionModel.isNotEmpty && !settings.modelList.contains(rawSessionModel);
    final activeSessionModel =
        !isStaleSessionModel && rawSessionModel.isNotEmpty
            ? rawSessionModel
            : null;
    final followingDefault = rawSessionModel.isEmpty;
    final primaryDefault = composerResolvePrimaryDefaultModel(settings);
    final groups = composerGroupModelsByProvider(settings);

    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(0, 0, 0, 16),
      children: [
        MoeSettingsGroup(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          padding: EdgeInsets.zero,
          children: [
            MoeSettingsRow(
              key: const ValueKey<String>('follow_default_queue'),
              icon: followingDefault
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              iconColor: followingDefault ? colors.primary : colors.muted,
              label: '跟随默认模型',
              subtitle: primaryDefault == null
                  ? null
                  : '当前默认：${_formatModelWithProvider(settings, primaryDefault)}',
              trailingType: followingDefault
                  ? MoeSettingsRowTrailing.custom
                  : MoeSettingsRowTrailing.none,
              trailing: followingDefault
                  ? Icon(Icons.check, color: colors.primary, size: 18)
                  : null,
              backgroundColor: followingDefault
                  ? colors.focus.withValues(alpha: 0.12)
                  : null,
              onTap: () => Navigator.of(context)
                  .pop(const ComposerModelSelection(null)),
            ),
            if (isStaleSessionModel)
              MoeSettingsRow(
                key: const ValueKey<String>('stale_session_model'),
                icon: Icons.info_outline_rounded,
                iconColor: colors.muted,
                label:
                    '原选模型：${_formatModelWithProvider(settings, rawSessionModel)}',
                subtitle: '该模型已隐藏或渠道已关闭，当前暂按默认模型回复',
                trailingType: MoeSettingsRowTrailing.none,
              ),
          ],
        ),
        for (final group in groups)
          MoeSettingsGroup(
            title: group.providerName,
            margin: const EdgeInsets.symmetric(horizontal: 16),
            padding: EdgeInsets.zero,
            children: [
              for (final modelRef in group.models)
                _buildModelRow(
                  context,
                  colors: colors,
                  settings: settings,
                  modelRef: modelRef,
                  selected: modelRef == activeSessionModel,
                ),
            ],
          ),
      ],
    );
  }

  MoeSettingsRow _buildModelRow(
    BuildContext context, {
    required MoeColors colors,
    required AppSettings settings,
    required String modelRef,
    required bool selected,
  }) {
    return MoeSettingsRow(
      key: ValueKey<String>('model_$modelRef'),
      icon: selected
          ? Icons.radio_button_checked
          : Icons.radio_button_unchecked,
      iconColor: selected ? colors.primary : colors.muted,
      label: settings.getModelDisplayName(modelRef),
      trailingType: selected
          ? MoeSettingsRowTrailing.custom
          : MoeSettingsRowTrailing.none,
      trailing: selected
          ? Icon(Icons.check, color: colors.primary, size: 18)
          : null,
      backgroundColor:
          selected ? colors.focus.withValues(alpha: 0.12) : null,
      onTap: () =>
          Navigator.of(context).pop(ComposerModelSelection(modelRef)),
    );
  }
}
