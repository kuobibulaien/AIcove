/// ModelListPage - 服务提供商管理页面
///
/// 显示和管理 AI 模型的服务提供商（渠道）。
///
/// 设计特点：
/// - 单个 MoeSettingsGroup 包裹所有供应商
/// - 顶部操作：搜索/新增（从右到左）
/// - 长按进入多选模式，底部显示操作条（全选/删除）
/// - 列表行：头像 + 名称 + 能力/模型数量摘要 + 启用状态
///
/// 更新记录：
/// - 2026-01-25: 删除导入/分享功能，简化操作
/// - 2026-01-21: 改造为 kelivo 风格的供应商列表
library;

import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/settings/app_settings.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/shared/animations/parallax_slide_page_route.dart';
import '../widgets/model_search_sheet.dart';
import 'add_provider_sheet.dart';
import 'default_model_settings_page.dart';
import 'provider_detail_page.dart';

class ModelListPage extends ConsumerStatefulWidget {
  const ModelListPage({super.key});

  @override
  ConsumerState<ModelListPage> createState() => _ModelListPageState();
}

class _ModelListPageState extends ConsumerState<ModelListPage> {
  bool _selectMode = false;
  final Set<String> _selected = {};
  final Set<String> _settleKeys = {}; // 正在"落定"动画的项目

  // 本地 providers 列表，用于乐观更新拖拽排序
  // 拖拽时先更新本地状态让 UI 立即响应，再异步保存
  List<ProviderAuth>? _localProviders;

  void _exitSelectMode() {
    setState(() {
      _selectMode = false;
      _selected.clear();
    });
  }

  void _toggleSelected(String providerId) {
    setState(() {
      if (_selected.contains(providerId)) {
        _selected.remove(providerId);
      } else {
        _selected.add(providerId);
      }
    });
  }

  void _toggleSelectAll(List<ProviderAuth> providers) {
    setState(() {
      final ids = providers.map((p) => p.id).toSet();
      final allSelected = ids.isNotEmpty && ids.every(_selected.contains);
      _selected
        ..clear()
        ..addAll(allSelected ? <String>{} : ids);
    });
  }

  Future<void> _onReorderProviders(int oldIndex, int newIndex) async {
    if (oldIndex == newIndex) return;

    final settings = ref.read(appSettingsProvider).value;
    if (settings == null) return;

    // 使用本地状态或从设置中获取
    final providers =
        List<ProviderAuth>.from(_localProviders ?? settings.providers);

    // ReorderableListView 的 newIndex 需要调整
    if (newIndex > oldIndex) {
      newIndex -= 1;
    }

    final movedItem = providers[oldIndex];
    final item = providers.removeAt(oldIndex);
    providers.insert(newIndex, item);

    // 【关键】立即更新本地状态，让 UI 先响应
    setState(() {
      _localProviders = providers;
      _settleKeys.add(movedItem.id);
    });

    // 异步保存到持久化存储
    final notifier = ref.read(appSettingsProvider.notifier);
    await notifier.reorderProviders(providers.map((p) => p.id).toList());

    // 延迟移除动画状态
    Future.delayed(const Duration(milliseconds: 220), () {
      if (!mounted) return;
      setState(() => _settleKeys.remove(movedItem.id));
    });
  }

  Future<void> _deleteSelected(List<ProviderAuth> providers) async {
    final ids = providers
        .map((p) => p.id)
        .where(_selected.contains)
        .toList(growable: false);
    if (ids.isEmpty) return;

    final confirm = await showMeoTalkDialog(
      context: context,
      title: '删除供应商',
      content: Text('确定要删除选中的 ${ids.length} 个供应商吗？此操作不可撤销。'),
      confirmText: '删除',
      cancelText: '取消',
    );

    if (confirm != true || !mounted) return;

    final notifier = ref.read(appSettingsProvider.notifier);
    for (final id in ids) {
      await notifier.deleteProvider(id);
    }

    if (!mounted) return;
    setState(() {
      _selectMode = false;
      _selected.clear();
    });
    MoeToast.success(context, '已删除 ${ids.length} 个供应商');
  }

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(appSettingsProvider);
    final colors = context.moeColors;

    return PopScope(
      canPop: !_selectMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selectMode) {
          _exitSelectMode();
        }
      },
      child: MoePageScaffold(
        appBar: MoeAppBar(
          title: '模型管理',
          showBackButton: true,
          actions: [
            MoeIconButton(
              icon: Icons.search,
              semanticLabel: '搜索模型',
              onTap: () => showModelSearchSheet(context, ref),
            ),
            MoeIconButton(
              icon: Icons.add,
              semanticLabel: '新增',
              onTap: () => showAddProviderSheet(context),
            ),
          ],
        ),
        backgroundColor: colors.surface,
        body: settingsAsync.when(
          loading: () =>
              const Center(child: MoeLoadingIndicator(message: '加载中...')),
          error: (e, _) => Center(
            child: MoeEmptyState(
              icon: Icons.error_outline,
              title: '加载失败',
              description: '$e',
            ),
          ),
          data: (settings) => _buildContent(settings, colors),
        ),
      ),
    );
  }

  Widget _buildContent(AppSettings settings, MoeColors colors) {
    // 优先使用本地状态（乐观更新），否则使用设置中的数据
    final providers = _localProviders ?? settings.providers;
    final providerEntries =
        providers.map(_ProviderListEntry.fromProvider).toList(growable: false);

    final selectedCount =
        providers.where((p) => _selected.contains(p.id)).length;

    return GestureDetector(
      onTap: _selectMode ? _exitSelectMode : null,
      child: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            children: [
              // ============ 默认模型设置 ============
              MoeSettingsGroup(
                margin: EdgeInsets.zero,
                padding: EdgeInsets.zero,
                children: [
                  MoeSettingsRow(
                    label: '默认模型设置',
                    trailingType: MoeSettingsRowTrailing.chevron,
                    onTap: () {
                      Navigator.of(context).push(
                        ParallaxSlidePageRoute(
                          page: const DefaultModelSettingsPage(),
                        ),
                      );
                    },
                  ),
                ],
              ),

              const SizedBox(height: 16),

              // ============ 渠道供应商列表 ============
              if (providers.isEmpty)
                MoeEmptyState(
                  icon: Icons.cloud_off,
                  title: '还没有任何供应商',
                  description: '右上角可以「新增」供应商',
                  action: MoePrimaryButton(
                    label: '新增供应商',
                    icon: Icons.add,
                    onPressed: () => showAddProviderSheet(context),
                  ),
                )
              else
                MoeSettingsGroup(
                  margin: EdgeInsets.zero,
                  padding: EdgeInsets.zero,
                  children: [
                    ReorderableListView.builder(
                      shrinkWrap: true,
                      padding: EdgeInsets.zero,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: providers.length,
                      onReorder: _onReorderProviders,
                      buildDefaultDragHandles: false,
                      proxyDecorator: (child, index, animation) {
                        return AnimatedBuilder(
                          animation: animation,
                          builder: (context, child) {
                            final t =
                                Curves.easeInOut.transform(animation.value);
                            final scale = lerpDouble(1.0, 0.98, t) ?? 1.0;
                            return Transform.scale(
                              scale: scale,
                              child: Opacity(
                                opacity: 0.95,
                                child: child,
                              ),
                            );
                          },
                          child: child,
                        );
                      },
                      itemBuilder: (context, index) {
                        final entry = providerEntries[index];
                        return ReorderableDelayedDragStartListener(
                          key: ValueKey(entry.provider.id),
                          index: index,
                          child: _SettleAnim(
                            active: _settleKeys.contains(entry.provider.id),
                            child: _ProviderRow(
                              entry: entry,
                              selectMode: _selectMode,
                              selected: _selected.contains(entry.provider.id),
                              onToggleSelect: () =>
                                  _toggleSelected(entry.provider.id),
                              onOpenDetail: () {
                                Navigator.of(context).push(
                                  ParallaxSlidePageRoute(
                                    page: ProviderDetailPage(
                                      providerId: entry.provider.id,
                                    ),
                                  ),
                                );
                              },
                              showDivider: index != providerEntries.length - 1,
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ),

              const SizedBox(height: 80), // 底部留白
            ],
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _SelectionBar(
              visible: _selectMode,
              count: selectedCount,
              total: providers.length,
              onDelete:
                  selectedCount == 0 ? null : () => _deleteSelected(providers),
              onSelectAll: () => _toggleSelectAll(providers),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProviderRow extends StatelessWidget {
  const _ProviderRow({
    required this.entry,
    required this.selectMode,
    required this.selected,
    required this.onToggleSelect,
    required this.onOpenDetail,
    this.showDivider = true,
  });

  final _ProviderListEntry entry;
  final bool selectMode;
  final bool selected;
  final VoidCallback onToggleSelect;
  final VoidCallback onOpenDetail;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;

    return MoeSettingsRow(
      iconWidget: Row(
        children: [
          if (selectMode) ...[
            MoeCheckbox(
              value: selected,
              onChanged: (_) => onToggleSelect(),
              size: MoeCheckboxSize.md,
            ),
            const SizedBox(width: 8),
          ],
          ProviderAvatar(
            providerName: entry.name,
            size: ProviderAvatarSize.sm,
          ),
        ],
      ),
      iconContainerWidth: selectMode ? 84 : 40,
      label: entry.name,
      labelMaxLines: 1,
      subtitle: entry.subtitle,
      trailingType: MoeSettingsRowTrailing.custom,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _StatusChip(enabled: entry.provider.enabled),
          if (!selectMode) ...[
            const SizedBox(width: 6),
            Icon(Icons.chevron_right, size: 16, color: colors.muted),
          ],
        ],
      ),
      onTap: selectMode ? onToggleSelect : onOpenDetail,
      showDivider: showDivider,
    );
  }
}

class _ProviderListEntry {
  const _ProviderListEntry({
    required this.provider,
    required this.name,
    required this.subtitle,
  });

  final ProviderAuth provider;
  final String name;
  final String subtitle;

  factory _ProviderListEntry.fromProvider(ProviderAuth provider) {
    final name = (provider.displayName?.trim().isNotEmpty ?? false)
        ? provider.displayName!.trim()
        : provider.id;
    final caps = provider.capabilities
        .map((c) => ModelCapability.fromValue(c)?.label)
        .whereType<String>()
        .toList(growable: false);
    final capSummary = caps.isEmpty
        ? null
        : (caps.length > 2
            ? '${caps.take(2).join('/')} +${caps.length - 2}'
            : caps.join('/'));
    final modelCount = provider.visibleModels.isNotEmpty
        ? provider.visibleModels.length
        : provider.models.length;
    final subtitleParts = <String>[];
    if (capSummary != null && capSummary.isNotEmpty) {
      subtitleParts.add(capSummary);
    }
    subtitleParts.add('$modelCount 个模型');

    return _ProviderListEntry(
      provider: provider,
      name: name,
      subtitle: subtitleParts.join(' · '),
    );
  }
}

class _SelectionBar extends StatelessWidget {
  const _SelectionBar({
    required this.visible,
    required this.count,
    required this.total,
    required this.onDelete,
    required this.onSelectAll,
  });

  final bool visible;
  final int count;
  final int total;
  final VoidCallback? onDelete;
  final VoidCallback onSelectAll;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final cs = Theme.of(context).colorScheme;

    return AnimatedSlide(
      offset: visible ? Offset.zero : const Offset(0, 1),
      duration: kAnim,
      curve: Curves.easeOutCubic,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: kAnimFast,
        curve: Curves.easeOut,
        child: IgnorePointer(
          ignoring: !visible,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _CircleActionButton(
                    icon: Icons.delete_outline,
                    color: cs.error,
                    backgroundColor: colors.componentBackground,
                    onTap: onDelete,
                    semanticLabel: '删除($count/$total)',
                  ),
                  const SizedBox(width: 14),
                  _CircleActionButton(
                    icon: Icons.select_all,
                    color: colors.focus,
                    backgroundColor: colors.componentBackground,
                    onTap: onSelectAll,
                    semanticLabel: '全选',
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CircleActionButton extends StatelessWidget {
  const _CircleActionButton({
    required this.icon,
    required this.color,
    required this.backgroundColor,
    required this.onTap,
    required this.semanticLabel,
  });

  final IconData icon;
  final Color color;
  final Color backgroundColor;
  final VoidCallback? onTap;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    return MoeIconButton(
      icon: icon,
      semanticLabel: semanticLabel,
      onTap: onTap,
      color: onTap == null ? colors.muted : color,
      backgroundColor: backgroundColor.withValues(alpha: 0.75),
      pressedBackgroundColor: backgroundColor.withValues(alpha: 0.9),
      borderRadius: MoeRadii.borderCapsule,
      border:
          BorderSide(color: colors.border.withValues(alpha: 0.25), width: 0.8),
    );
  }
}

/// 启用/禁用状态标签（使用主题色）
class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.enabled});
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final bg = enabled
        ? colors.primary.withValues(alpha: 0.12)
        : colors.muted.withValues(alpha: 0.15);
    final fg = enabled ? colors.primary : colors.muted;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: MoeG2Decoration(
        radius: MoeRadii.xs,
        color: bg,
      ),
      child: Text(
        enabled ? '已启用' : '已禁用',
        style: TextStyle(fontSize: 11, color: fg),
      ),
    );
  }
}

/// 落定动画 - 拖拽结束后的微小弹跳动画，消除闪烁感
/// 参考 kelivo 项目的实现
class _SettleAnim extends StatelessWidget {
  const _SettleAnim({required this.active, required this.child});
  final bool active;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tween = Tween<double>(begin: active ? 0.94 : 1.0, end: 1.0);
    return TweenAnimationBuilder<double>(
      tween: tween,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutBack,
      builder: (context, scale, _) {
        return AnimatedOpacity(
          duration: const Duration(milliseconds: 140),
          opacity: 1.0,
          child: Transform.scale(scale: scale, child: child),
        );
      },
    );
  }
}
