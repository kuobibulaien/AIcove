import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/plugins/plugin_providers.dart';
import '../../../../features/plugins/web_search/web_search_config.dart';
import '../../../../ui/shared/animations/parallax_slide_page_route.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/theme/tokens.dart';
import 'web_search_provider_detail_page.dart';

/// 联网搜索插件设置：内置搜索接管开关、搜索供应商列表与返回内容。
class WebSearchPluginDetailPage extends ConsumerWidget {
  const WebSearchPluginDetailPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.moeColors;
    final config = ref.watch(webSearchPluginConfigProvider);
    final notifier = ref.read(webSearchPluginConfigProvider.notifier);

    return MoePageScaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: colors.surface,
      appBar: const MoeAppBar(title: '联网搜索', showBackButton: true),
      body: MoeSettingsContent(
        child: Builder(
          builder: (context) => ListView(
            padding: moeUnderBarPadding(
              context,
              MoeSettingsLayout.verticalListPadding,
            ),
            children: [
              MoeSettingsGroup(
                children: [
                  MoeSettingsRow(
                    key: const ValueKey('web-search-replace-builtin'),
                    label: '关闭模型内置搜索，改用此工具',
                    subtitle: '开启后，请求会去掉厂商自带的联网搜索参数，统一由下方供应商搜索',
                    trailingType: MoeSettingsRowTrailing.switchControl,
                    switchValue: config.replaceModelBuiltinSearch,
                    onSwitchChanged: (value) => _guard(
                      context,
                      notifier.setReplaceModelBuiltinSearch(value),
                    ),
                    showDivider: false,
                  ),
                ],
              ),
              const SizedBox(height: MoeSettingsLayout.sectionGap),
              _ProvidersSection(config: config),
              const SizedBox(height: MoeSettingsLayout.sectionGap),
              MoeSettingsGroup(
                title: '返回内容',
                children: [
                  MoeSettingsRow(
                    label: '每次搜索条数',
                    subtitle: 'AI 未指定条数时使用',
                    trailingType: MoeSettingsRowTrailing.text,
                    detailText: '${config.numResults}',
                    onTap: () => _editInt(
                      context,
                      title: '每次搜索条数',
                      current: config.numResults,
                      min: WebSearchConfig.minResults,
                      max: WebSearchConfig.maxResults,
                      save: (value) => notifier.updateConfig(
                        ref
                            .read(webSearchPluginConfigProvider)
                            .copyWith(numResults: value),
                      ),
                    ),
                  ),
                  MoeSettingsRow(
                    label: '单条正文上限',
                    subtitle: '越大越占上下文',
                    trailingType: MoeSettingsRowTrailing.text,
                    detailText: '${config.maxCharactersPerResult} 字',
                    showDivider: false,
                    onTap: () => _editInt(
                      context,
                      title: '单条正文上限',
                      current: config.maxCharactersPerResult,
                      min: WebSearchConfig.minCharacters,
                      max: WebSearchConfig.maxCharacters,
                      save: (value) => notifier.updateConfig(
                        ref
                            .read(webSearchPluginConfigProvider)
                            .copyWith(maxCharactersPerResult: value),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: MoeSettingsLayout.sectionGap),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  '供应商按列表顺序使用，前一家失败自动换下一家，长按拖动调整顺序。'
                  '需要所用模型支持工具调用；角色可在「插件」里单独开关。',
                  style: TextStyle(
                    color: colors.textSecondary,
                    fontSize: 13,
                    height: 1.5,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static Future<void> _guard(BuildContext context, Future<void> task) async {
    try {
      await task;
    } catch (e) {
      if (context.mounted) MoeToast.error(context, '$e');
    }
  }

  static Future<void> _editInt(
    BuildContext context, {
    required String title,
    required int current,
    required int min,
    required int max,
    required Future<void> Function(int value) save,
  }) {
    return showMoeAutoSaveTextEditor(
      context: context,
      title: title,
      initialValue: '$current',
      hint: '$min ~ $max',
      keyboardType: TextInputType.number,
      onSave: (text) async {
        final value = int.tryParse(text.trim());
        if (value == null || value < min || value > max) {
          throw FormatException('请输入 $min ~ $max 之间的整数');
        }
        await save(value);
      },
    );
  }
}

class _ProvidersSection extends ConsumerStatefulWidget {
  const _ProvidersSection({required this.config});

  final WebSearchConfig config;

  @override
  ConsumerState<_ProvidersSection> createState() => _ProvidersSectionState();
}

class _ProvidersSectionState extends ConsumerState<_ProvidersSection> {
  /// 拖动后先本地生效，保存完成再以配置为准。
  List<WebSearchProviderEntry>? _localOrder;

  List<WebSearchProviderEntry> get _providers =>
      _localOrder ?? widget.config.providers;

  @override
  void didUpdateWidget(covariant _ProvidersSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.config.providers != widget.config.providers) {
      _localOrder = null;
    }
  }

  Future<void> _onReorder(int oldIndex, int newIndex) async {
    if (oldIndex == newIndex) return;
    final providers = List<WebSearchProviderEntry>.from(_providers);
    providers.insert(newIndex, providers.removeAt(oldIndex));
    setState(() => _localOrder = providers);
    try {
      await ref
          .read(webSearchPluginConfigProvider.notifier)
          .reorderProviders([for (final p in providers) p.id]);
    } catch (e) {
      if (!mounted) return;
      setState(() => _localOrder = null);
      MoeToast.error(context, '$e');
    }
  }

  void _open(String providerId) {
    Navigator.of(context).push(
      ParallaxSlidePageRoute(
        page: WebSearchProviderDetailPage(providerId: providerId),
      ),
    );
  }

  Future<void> _add() async {
    final type = await showWebSearchProviderTypePicker(context);
    if (type == null || !mounted) return;
    final entry = WebSearchProviderEntry.create(type);
    try {
      await ref.read(webSearchPluginConfigProvider.notifier).saveProvider(entry);
    } catch (e) {
      if (mounted) MoeToast.error(context, '$e');
      return;
    }
    if (mounted) _open(entry.id);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final providers = _providers;
    final primaryId = providers.where((p) => p.isUsable).firstOrNull?.id;

    return MoeSettingsGroup(
      title: '搜索供应商',
      padding: EdgeInsets.zero,
      children: [
        if (providers.isNotEmpty)
          ReorderableListView.builder(
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            itemCount: providers.length,
            onReorderItem: _onReorder,
            proxyDecorator: (child, index, animation) => AnimatedBuilder(
              animation: animation,
              builder: (context, child) {
                final t = Curves.easeInOut.transform(animation.value);
                return Transform.scale(
                  scale: lerpDouble(1.0, 0.98, t) ?? 1.0,
                  child: Opacity(opacity: 0.95, child: child),
                );
              },
              child: child,
            ),
            itemBuilder: (context, index) {
              final entry = providers[index];
              return ReorderableDelayedDragStartListener(
                key: ValueKey(entry.id),
                index: index,
                child: _ProviderRow(
                  entry: entry,
                  primary: entry.id == primaryId,
                  onTap: () => _open(entry.id),
                ),
              );
            },
          ),
        MoeSettingsRow(
          key: const ValueKey('web-search-add-provider'),
          icon: Icons.add,
          iconColor: colors.primary,
          label: '添加供应商',
          labelColor: colors.primary,
          trailingType: MoeSettingsRowTrailing.none,
          showDivider: false,
          onTap: _add,
        ),
      ],
    );
  }
}

class _ProviderRow extends StatelessWidget {
  const _ProviderRow({
    required this.entry,
    required this.primary,
    required this.onTap,
  });

  final WebSearchProviderEntry entry;
  final bool primary;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final status = !entry.enabled
        ? '已停用'
        : !entry.isReady
        ? (entry.type.requiresApiKey ? '未填写密钥' : '未填写地址')
        : primary
        ? '优先使用'
        : '备用';
    return MoeSettingsRow(
      iconWidget: ProviderAvatar(
        providerName: entry.type.id,
        size: ProviderAvatarSize.sm,
      ),
      label: entry.displayName,
      labelColor: entry.isUsable ? null : colors.muted,
      subtitle: entry.name.trim().isEmpty ? null : entry.type.label,
      trailingType: MoeSettingsRowTrailing.text,
      detailText: status,
      onTap: onTap,
    );
  }
}

/// 选择要添加的搜索供应商类型。
Future<WebSearchProviderType?> showWebSearchProviderTypePicker(
  BuildContext context,
) {
  return showMoeBottomSheet<WebSearchProviderType>(
    context: context,
    title: '添加搜索供应商',
    builder: (sheetContext) => ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: [
        MoeSettingsGroup(
          margin: EdgeInsets.zero,
          children: [
            for (final type in WebSearchProviderType.values)
              MoeSettingsRow(
                key: ValueKey('web-search-type-${type.id}'),
                iconWidget: ProviderAvatar(
                  providerName: type.id,
                  size: ProviderAvatarSize.sm,
                ),
                label: type.label,
                subtitle: type.supportsFetch ? '搜索＋读取网页' : '搜索',
                showDivider: type != WebSearchProviderType.values.last,
                onTap: () => Navigator.of(sheetContext).pop(type),
              ),
          ],
        ),
      ],
    ),
  );
}
