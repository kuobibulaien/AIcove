import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../features/stickers/sticker_registry.dart';

/// 表情包设置页
///
/// 功能：
/// 1. 按套组浏览全部表情，支持按标签 / 描述 / 套组名搜索
/// 3. 点按单个表情查看大图与全部可触发标签（含同义词）
class StickerSettingsPage extends ConsumerStatefulWidget {
  const StickerSettingsPage({super.key});

  @override
  ConsumerState<StickerSettingsPage> createState() =>
      _StickerSettingsPageState();
}

class _StickerSettingsPageState extends ConsumerState<StickerSettingsPage> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final registry = StickerRegistry.instance;
    final searching = _query.trim().isNotEmpty;
    final results = searching ? _searchStickers(registry, _query) : null;
    final folders = registry.stickersByFolder;
    final folderNames = folders.keys.toList()..sort();

    return MoePageScaffold(
      backgroundColor: colors.surface,
      appBar: const MoeDetailAppBar(title: '表情包'),
      body: CustomScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        slivers: [
          SliverToBoxAdapter(
            child: MoeSearchField(
              hintText: '搜索表情、标签或套组',
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              onChanged: (value) => setState(() => _query = value),
            ),
          ),
          if (registry.stickers.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: MoeEmptyState(
                icon: Icons.emoji_emotions_outlined,
                title: '还没有表情包',
                description: '添加表情资源并注册后，这里会列出可供 AI 发送的表情。',
              ),
            )
          else if (searching) ...[
            SliverToBoxAdapter(
              child: _SectionHeader(title: '搜索结果', count: results!.length),
            ),
            if (results.isEmpty)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.only(top: 48),
                  child: MoeEmptyState(
                    icon: Icons.search_off_rounded,
                    title: '没有找到相关表情',
                    description: '换个关键词试试，支持标签同义词、描述和套组名。',
                  ),
                ),
              )
            else
              _buildGrid(results),
          ] else
            for (final name in folderNames) ...[
              SliverToBoxAdapter(
                child: _SectionHeader(
                  title: name,
                  count: folders[name]!.length,
                ),
              ),
              _buildGrid(folders[name]!),
            ],
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }

  /// 搜索：先做同义词归一化的精确标签匹配，再做标签／描述／套组的包含匹配
  List<Sticker> _searchStickers(StickerRegistry registry, String query) {
    final q = query.trim().toLowerCase();
    final results = <Sticker>{...registry.getAllByTag(q)};
    for (final sticker in registry.stickers) {
      if (results.contains(sticker)) continue;
      final haystacks = [sticker.description, sticker.folder, ...sticker.tags];
      if (haystacks.any((h) => h.toLowerCase().contains(q))) {
        results.add(sticker);
      }
    }
    return results.toList();
  }

  Widget _buildGrid(List<Sticker> stickers) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      sliver: SliverGrid(
        delegate: SliverChildBuilderDelegate(
          (context, index) => _StickerCell(
            sticker: stickers[index],
            onTap: () => _showStickerSheet(stickers[index]),
          ),
          childCount: stickers.length,
        ),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 76,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
        ),
      ),
    );
  }

  /// 单个表情详情：大图 + 全部可触发标签
  void _showStickerSheet(Sticker sticker) {
    final registry = StickerRegistry.instance;
    final triggers = sticker.tags
        .expand(registry.triggerWordsOf)
        .toSet()
        .toList();

    showMoeBottomSheet(
      context: context,
      title: sticker.description.isNotEmpty ? sticker.description : '表情详情',
      builder: (sheetContext) {
        final colors = sheetContext.moeColors;
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GestureDetector(
                onTap: () => MoeImagePreview.show(
                  sheetContext,
                  AssetImage(sticker.assetPath),
                  heroTag: 'sticker_${sticker.id}',
                ),
                child: Container(
                  width: double.infinity,
                  height: 180,
                  padding: const EdgeInsets.all(12),
                  decoration: MoeG2Decoration(
                    radius: 16,
                    color: colors.surfaceAlt,
                  ),
                  child: Image.asset(
                    sticker.assetPath,
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => Center(
                      child: Icon(
                        Icons.emoji_emotions_outlined,
                        color: colors.muted,
                        size: 48,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'AI 回复中带以下标签时，可能随机发出这张表情',
                style: TextStyle(fontSize: 12, color: colors.muted),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final word in triggers)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: MoeG2Decoration(
                        radius: 999,
                        color: colors.primary.withValues(alpha: 0.1),
                      ),
                      child: Text(
                        word,
                        style: TextStyle(fontSize: 13, color: colors.primary),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                '来自套组 ${sticker.folder}',
                style: TextStyle(fontSize: 12, color: colors.muted),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 套组／搜索结果的分节标题
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.count});

  final String title;
  final int count;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
      child: Row(
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: MoeFontWeights.emphasis,
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(width: 6),
          Text('$count 个', style: TextStyle(fontSize: 12, color: colors.muted)),
        ],
      ),
    );
  }
}

/// 网格中的单个表情：圆角底 + 按压缩放反馈，点按看详情
class _StickerCell extends StatefulWidget {
  const _StickerCell({required this.sticker, required this.onTap});

  final Sticker sticker;
  final VoidCallback onTap;

  @override
  State<_StickerCell> createState() => _StickerCellState();
}

class _StickerCellState extends State<_StickerCell> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final sticker = widget.sticker;

    return Tooltip(
      message: sticker.description.isNotEmpty
          ? sticker.description
          : sticker.tags.join('、'),
      child: GestureDetector(
        onTap: widget.onTap,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        child: AnimatedScale(
          scale: _pressed ? 0.92 : 1,
          duration: kAnimFast,
          child: Container(
            decoration: MoeG2Decoration(radius: 14, color: colors.surfaceAlt),
            child: MoeG2ClipRRect(
              radius: 14,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Image.asset(
                  sticker.assetPath,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => Center(
                    child: Icon(
                      Icons.emoji_emotions_outlined,
                      color: colors.muted,
                      size: 30,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
