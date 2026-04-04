library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/settings/app_settings.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/theme/tokens.dart';

Future<String?> showComposerModelPickerSheet(BuildContext context) {
  return showMoeBottomSheet<String>(
    context: context,
    title: '选择模型',
    useRootNavigator: true,
    builder: (_) => const _ComposerModelPickerSheet(),
  );
}

@visibleForTesting
List<String> composerResolveDefaultChatQueue(AppSettings settings) {
  final visibleModels = settings.modelList.toSet();
  final queue = <String>[];

  void append(String? modelRef) {
    final normalized = modelRef?.trim() ?? '';
    if (normalized.isEmpty ||
        !visibleModels.contains(normalized) ||
        queue.contains(normalized)) {
      return;
    }
    queue.add(normalized);
  }

  for (final modelRef in settings.defaultChatModels) {
    append(modelRef);
  }
  append(settings.defaultModelName);

  if (queue.isEmpty && settings.modelList.isNotEmpty) {
    queue.add(settings.modelList.first);
  }

  return queue;
}

@visibleForTesting
List<String> composerResolveOtherModels(
  AppSettings settings,
  Iterable<String> queuedModels,
) {
  final queueSet = queuedModels.toSet();
  return settings.modelList
      .where((modelRef) => !queueSet.contains(modelRef))
      .toList(growable: false);
}

@visibleForTesting
List<String> composerReorderModelQueue(
  List<String> modelQueue,
  int oldIndex,
  int newIndex,
) {
  if (oldIndex < 0 || oldIndex >= modelQueue.length) {
    return List<String>.from(modelQueue);
  }

  final reordered = List<String>.from(modelQueue);
  var targetIndex = newIndex.clamp(0, reordered.length);
  if (oldIndex < targetIndex) {
    targetIndex -= 1;
  }
  if (targetIndex == oldIndex) {
    return reordered;
  }

  final moved = reordered.removeAt(oldIndex);
  reordered.insert(targetIndex.clamp(0, reordered.length), moved);
  return reordered;
}

class _ComposerModelPickerSheet extends ConsumerStatefulWidget {
  const _ComposerModelPickerSheet();

  @override
  ConsumerState<_ComposerModelPickerSheet> createState() =>
      _ComposerModelPickerSheetState();
}

class _ComposerModelPickerSheetState
    extends ConsumerState<_ComposerModelPickerSheet> {
  List<String>? _queuedModels;
  String? _sourceSignature;
  bool _savingQueue = false;

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(appSettingsProvider);

    return settingsAsync.when(
      loading: () => const Center(child: MoeLoadingIndicator()),
      error: (error, _) => MoeEmptyState(
        icon: Icons.error_outline,
        title: '加载失败',
        description: '$error',
      ),
      data: _buildContent,
    );
  }

  Widget _buildContent(AppSettings settings) {
    final colors = context.moeColors;
    final currentSourceSignature = _buildSourceSignature(settings);
    final resolvedQueue = composerResolveDefaultChatQueue(settings);

    if (_queuedModels == null || _sourceSignature != currentSourceSignature) {
      _queuedModels = resolvedQueue;
      _sourceSignature = currentSourceSignature;
    }

    final queuedModels = _queuedModels ?? resolvedQueue;
    final otherModels = composerResolveOtherModels(settings, queuedModels);

    if (settings.modelList.isEmpty) {
      return const MoeEmptyState(
        icon: Icons.model_training_outlined,
        title: '暂无可用模型',
        description: '请先在设置中配置至少一个可见模型',
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 0, 0, 16),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Text(
            '长按拖动默认队列可调整当前默认模型与失败切换顺序。',
            style: TextStyle(
              fontSize: 12,
              color: colors.muted,
            ),
          ),
        ),
        _buildSectionHeader(colors, '默认队列', '首位为当前默认模型'),
        const SizedBox(height: 8),
        MoeSettingsGroup(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          padding: EdgeInsets.zero,
          children: [
            ReorderableListView.builder(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: queuedModels.length,
              onReorder: _savingQueue
                  ? (_, __) {}
                  : (oldIndex, newIndex) =>
                      _onReorderQueue(settings, oldIndex, newIndex),
              buildDefaultDragHandles: false,
              itemBuilder: (context, index) {
                final modelRef = queuedModels[index];
                return ReorderableDelayedDragStartListener(
                  key: ValueKey<String>('queue_$modelRef'),
                  index: index,
                  child: _ModelPickerTile(
                    modelRef: modelRef,
                    settings: settings,
                    selected: modelRef == settings.defaultModelName,
                    leading: _QueueOrderBadge(index: index + 1),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (modelRef == settings.defaultModelName)
                          Icon(
                            Icons.check_circle,
                            color: colors.primary,
                            size: 18,
                          ),
                        if (modelRef == settings.defaultModelName)
                          const SizedBox(width: 8),
                        Icon(
                          Icons.drag_handle_rounded,
                          color: colors.muted,
                          size: 20,
                        ),
                      ],
                    ),
                    subtitleSuffix: '优先级 ${index + 1}',
                    onTap: () => Navigator.of(context).pop(modelRef),
                  ),
                );
              },
            ),
          ],
        ),
        if (otherModels.isNotEmpty) ...[
          const SizedBox(height: 20),
          _buildSectionHeader(colors, '其他可用模型', '点击后切换为当前默认并加入队首'),
          const SizedBox(height: 8),
          MoeSettingsGroup(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            padding: EdgeInsets.zero,
            children: [
              for (var index = 0; index < otherModels.length; index++)
                _ModelPickerTile(
                  key: ValueKey<String>('other_${otherModels[index]}'),
                  modelRef: otherModels[index],
                  settings: settings,
                  selected: otherModels[index] == settings.defaultModelName,
                  leading: Icon(
                    otherModels[index] == settings.defaultModelName
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    color: otherModels[index] == settings.defaultModelName
                        ? colors.primary
                        : colors.muted,
                    size: 20,
                  ),
                  trailing: otherModels[index] == settings.defaultModelName
                      ? Icon(Icons.check, color: colors.primary, size: 18)
                      : null,
                  onTap: () => Navigator.of(context).pop(otherModels[index]),
                  showDivider: index != otherModels.length - 1,
                ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildSectionHeader(
    MoeColors colors,
    String title,
    String description,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
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
            style: TextStyle(
              fontSize: 12,
              color: colors.muted,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _onReorderQueue(
    AppSettings settings,
    int oldIndex,
    int newIndex,
  ) async {
    final currentQueue = List<String>.from(
      _queuedModels ?? composerResolveDefaultChatQueue(settings),
    );
    final nextQueue = composerReorderModelQueue(
      currentQueue,
      oldIndex,
      newIndex,
    );
    if (listEquals(currentQueue, nextQueue)) {
      return;
    }

    setState(() {
      _queuedModels = nextQueue;
      _savingQueue = true;
    });

    try {
      await ref
          .read(appSettingsProvider.notifier)
          .setDefaultChatModels(nextQueue);
      if (!mounted) return;
      MoeToast.brief(context, '已更新默认模型顺序');
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _queuedModels = null;
        _sourceSignature = null;
      });
      MoeToast.error(context, '更新模型顺序失败: $error');
    } finally {
      if (!mounted) return;
      setState(() => _savingQueue = false);
    }
  }

  String _buildSourceSignature(AppSettings settings) {
    return <String>[
      settings.defaultModelName,
      ...settings.defaultChatModels,
      '---',
      ...settings.modelList,
    ].join('\n');
  }
}

class _ModelPickerTile extends StatelessWidget {
  const _ModelPickerTile({
    super.key,
    required this.modelRef,
    required this.settings,
    required this.selected,
    this.leading,
    this.trailing,
    this.subtitleSuffix,
    this.showDivider = true,
    this.onTap,
  });

  final String modelRef;
  final AppSettings settings;
  final bool selected;
  final Widget? leading;
  final Widget? trailing;
  final String? subtitleSuffix;
  final bool showDivider;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final modelId = settings.getRawModelId(modelRef);
    final displayName = settings.getModelDisplayName(modelRef);
    final providerId = settings.getModelProviderId(modelRef);
    final providerLabel = providerId != null
        ? settings.providers
                .where((provider) => provider.id == providerId)
                .map((provider) => provider.displayName ?? provider.id)
                .firstOrNull ??
            providerId
        : null;

    final subtitleParts = <String>[
      if (providerLabel != null && providerLabel.isNotEmpty) providerLabel,
      if (displayName != modelId) modelId,
      if (subtitleSuffix != null && subtitleSuffix!.isNotEmpty) subtitleSuffix!,
    ];

    return DecoratedBox(
      decoration: BoxDecoration(
        border: showDivider
            ? Border(
                bottom: BorderSide(
                  color: colors.borderLight,
                  width: borderWidth,
                ),
              )
            : null,
      ),
      child: MoeListTile(
        leading: leading,
        minLeadingWidth: 32,
        title: Text(displayName),
        subtitle:
            subtitleParts.isEmpty ? null : Text(subtitleParts.join(' / ')),
        trailing: trailing,
        selected: selected,
        onTap: onTap,
      ),
    );
  }
}

class _QueueOrderBadge extends StatelessWidget {
  const _QueueOrderBadge({required this.index});

  final int index;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    return Container(
      width: 24,
      height: 24,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colors.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        '$index',
        style: TextStyle(
          fontSize: 11,
          fontWeight: MoeFontWeights.emphasis,
          color: colors.primary,
        ),
      ),
    );
  }
}
