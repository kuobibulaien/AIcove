import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/agent_context/domain/silly_tavern_world_book.dart';
import '../../../../features/agent_context/domain/tavern_compatibility_port.dart';
import '../../../../features/agent_context/providers/preset_recipe_provider.dart';
import '../../../shared/effects/smooth_clip.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';
import '../widgets/tavern_common.dart';

/// 条目超过这个数时显示搜索框。
const int _searchThreshold = 8;

/// 一本世界书的条目列表，条目很多时按需构建。
class TavernWorldBookPage extends ConsumerStatefulWidget {
  const TavernWorldBookPage({
    super.key,
    required this.presetId,
    required this.bookId,
  });

  final String presetId;
  final String bookId;

  @override
  ConsumerState<TavernWorldBookPage> createState() =>
      _TavernWorldBookPageState();
}

class _TavernWorldBookPageState extends ConsumerState<TavernWorldBookPage> {
  String _query = '';

  void _change(Future<void> Function(TavernCompatibilityPort port) action) =>
      runTavernAction(
        context,
        () => ref
            .read(presetRecipeImportControllerProvider.notifier)
            .change(widget.presetId, action),
      );

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final preset = ref.watch(presetRecipeProvider(widget.presetId));
    final book = preset.valueOrNull?.worldBooks
        .where((b) => b.id == widget.bookId)
        .firstOrNull;
    return MoePageScaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: colors.surface,
      appBar: MoeAppBar(title: book?.name ?? '世界书', showBackButton: true),
      body: MoeSettingsContent(
        child: book == null
            ? Center(
                child: preset.isLoading
                    ? const CircularProgressIndicator()
                    : const MoeEmptyState(title: '这本世界书已不存在'),
              )
            : Builder(builder: (context) => _content(context, book)),
      ),
    );
  }

  Widget _content(BuildContext context, TavernWorldBook book) {
    final colors = context.moeColors;
    final query = _query.trim().toLowerCase();
    final entries = query.isEmpty
        ? book.entries
        : book.entries.where((e) => _matches(e, query)).toList();
    final enabled = book.entries.where((e) => e.enabled).length;
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: moeUnderBarPadding(context, const EdgeInsets.only(top: 16)),
          sliver: SliverToBoxAdapter(
            child: MoeSettingsGroup(
              children: [
                MoeSettingsRow(
                  label: '启用这本世界书',
                  subtitleWidget: tavernSubtitle(
                    context,
                    '$enabled/${book.entries.length} 个条目开启 · ${book.tokenBudget == null ? '共用全局预算' : '每本最多 ${book.tokenBudget} token'}',
                    warnings: book.warnings,
                  ),
                  trailingType: MoeSettingsRowTrailing.custom,
                  trailing: MoeSwitch(
                    key: ValueKey('book-${book.id}'),
                    value: book.enabled,
                    semanticLabel: '启用世界书 ${book.name}',
                    onChanged: (v) => _change(
                      (port) =>
                          port.setWorldBookEnabled(widget.presetId, book.id, v),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (book.entries.length > _searchThreshold)
          SliverToBoxAdapter(
            child: MoeSearchField(
              hintText: '搜索条目名、关键词或正文',
              initialValue: _query,
              padding: const EdgeInsets.only(top: MoeSettingsLayout.sectionGap),
              onChanged: (value) => setState(() => _query = value),
            ),
          ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 16, 12, 8),
            child: Text(
              book.enabled
                  ? query.isEmpty
                        ? '条目'
                        : '找到 ${entries.length} 个条目'
                  : '整本已关闭，条目都不会触发',
              style: TextStyle(
                fontSize: 13,
                fontWeight: MoeFontWeights.emphasis,
                color: book.enabled ? colors.primary : colors.toastWarning,
              ),
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.only(bottom: 24),
          sliver: DecoratedSliver(
            decoration: ShapeDecoration(
              color: colors.componentBackground,
              shape: moeG2Shape(
                radius: MoeSettingsLayout.cardRadius,
                side: BorderSide(
                  color: colors.border.withValues(alpha: 0.06),
                  width: 0.6,
                ),
              ),
            ),
            sliver: SliverPadding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              sliver: entries.isEmpty
                  ? const SliverToBoxAdapter(
                      child: MoeSettingsRow(
                        label: '没有条目',
                        showDivider: false,
                        trailingType: MoeSettingsRowTrailing.none,
                      ),
                    )
                  : SliverList.builder(
                      itemCount: entries.length,
                      itemBuilder: (context, index) => _entryRow(
                        book,
                        entries[index],
                        isLast: index == entries.length - 1,
                      ),
                    ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _entryRow(
    TavernWorldBook book,
    TavernWorldEntry entry, {
    required bool isLast,
  }) {
    final trigger = entry.constant
        ? '常驻'
        : entry.keys.isEmpty
        ? '没有关键词'
        : '关键词：${entry.keys.take(4).join('、')}${entry.keys.length > 4 ? ' 等 ${entry.keys.length} 个' : ''}';
    return MoeSettingsRow(
      label: entry.name,
      labelMaxLines: 2,
      showDivider: !isLast,
      subtitleWidget: tavernSubtitle(
        context,
        '$trigger\n${_position(entry)}',
        warnings: [
          if (entry.unsupported.isNotEmpty)
            '用到${entry.unsupported.join('、')}，暂不支持，不会触发',
        ],
      ),
      trailingType: MoeSettingsRowTrailing.custom,
      trailing: MoeSwitch(
        key: ValueKey('world-${book.id}-${entry.id}'),
        value: entry.enabled,
        semanticLabel: '启用 ${entry.name}',
        onChanged: (v) => _change(
          (port) =>
              port.setWorldEntryEnabled(widget.presetId, book.id, entry.id, v),
        ),
      ),
      onTap: () =>
          showTavernText(context, title: entry.name, text: entry.content),
    );
  }
}

bool _matches(TavernWorldEntry entry, String query) =>
    entry.name.toLowerCase().contains(query) ||
    entry.keys.any((k) => k.toLowerCase().contains(query)) ||
    entry.content.toLowerCase().contains(query);

String _position(TavernWorldEntry entry) => switch (entry.position) {
  0 => '放在角色设定前',
  1 => '放在角色设定后',
  4 =>
    entry.depth == 0
        ? '以${tavernRoleLabel(entry.role)}身份插在最新消息后'
        : '以${tavernRoleLabel(entry.role)}身份插在倒数第 ${entry.depth} 条消息前',
  _ => '暂不支持的位置 ${entry.position}',
};
