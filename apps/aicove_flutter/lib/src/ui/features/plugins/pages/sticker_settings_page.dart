import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/stickers/sticker_library.dart';
import '../../../../features/stickers/sticker_library_provider.dart';
import '../../../../features/stickers/sticker_registry.dart';
import '../../../../ui/shared/animations/parallax_slide_page_route.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/theme/tokens.dart';
import 'sticker_pack_page.dart';

/// 表情包设置页：套组列表、跨套组搜索、导入图片或压缩包。
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
    final library = ref.watch(stickerLibraryProvider);
    final packs = library.valueOrNull;
    final searching = _query.trim().isNotEmpty;

    return MoePageScaffold(
      backgroundColor: colors.surface,
      extendBodyBehindAppBar: true,
      appBar: MoeDetailAppBar(
        title: '表情包',
        actions: [
          MoeIconButton(
            icon: Icons.add_rounded,
            semanticLabel: '导入表情包',
            onTap: () => importStickersInteractively(context, ref),
          ),
        ],
      ),
      body: Builder(
        builder: (context) => CustomScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          slivers: [
            SliverToBoxAdapter(
              child: MoeSearchField(
                hintText: '搜索表情、标签或套组',
                padding: moeUnderBarPadding(
                  context,
                  const EdgeInsets.fromLTRB(16, 12, 16, 4),
                ),
                onChanged: (value) => setState(() => _query = value),
              ),
            ),
            if (library.hasError)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: MoeEmptyState(
                  icon: Icons.error_outline_rounded,
                  title: '表情包库读取失败',
                  description: '内置表情仍可使用，可稍后重新打开本页。',
                ),
              )
            else if (packs == null)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: MoeLoadingIndicator()),
              )
            else if (searching)
              ..._buildSearchResults(packs)
            else ...[
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                  child: Text(
                    'AI 在回复里写 [标签] 就会发出对应表情。导入时文件名会成为标签，'
                    '例如「开心-1.png」→ 开心；支持多选图片或 ZIP（每个文件夹一个套组）。',
                    style: TextStyle(fontSize: 12, color: colors.muted),
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: MoeSettingsGroup(
                  title: '表情套组',
                  children: [
                    for (final (index, pack) in packs.indexed)
                      MoeSettingsRow(
                        iconWidget: StickerThumb(
                          sticker: pack.stickers.firstOrNull,
                          size: 36,
                        ),
                        label: pack.name,
                        subtitle: _packSubtitle(pack),
                        showDivider: index != packs.length - 1,
                        onTap: () => Navigator.of(context).push(
                          ParallaxSlidePageRoute(
                            page: StickerPackPage(packId: pack.id),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        ),
      ),
    );
  }

  String _packSubtitle(StickerPack pack) {
    final parts = ['${pack.stickers.length} 张'];
    if (pack.untaggedCount > 0) parts.add('${pack.untaggedCount} 张未标注');
    if (!pack.enabled) parts.add('已停用');
    return parts.join(' · ');
  }

  List<Widget> _buildSearchResults(List<StickerPack> packs) {
    final results = searchStickers(packs, _query);
    return [
      SliverToBoxAdapter(
        child: StickerSectionHeader(title: '搜索结果', count: results.length),
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
        StickerGrid(
          stickers: results,
          onTap: (sticker) => showStickerDetailSheet(
            context,
            ref,
            sticker,
            readOnly: sticker.isAsset,
          ),
        ),
    ];
  }
}

/// 搜索：先做同义词归一化的精确标签匹配，再做标签／描述／套组名的包含匹配。
List<Sticker> searchStickers(List<StickerPack> packs, String query) {
  final q = query.trim().toLowerCase();
  final registry = StickerRegistry.instance;
  final normalized = registry.normalizeTag(q);
  final exact = <Sticker>[];
  final partial = <Sticker>[];
  for (final pack in packs) {
    for (final sticker in pack.stickers) {
      if (sticker.tags.any((t) => registry.normalizeTag(t) == normalized)) {
        exact.add(sticker);
      } else if ([
        sticker.description,
        pack.name,
        ...sticker.tags,
      ].any((h) => h.toLowerCase().contains(q))) {
        partial.add(sticker);
      }
    }
  }
  return [...exact, ...partial];
}

/// 选择图片或 ZIP 导入。[packId] 不为空时图片加入该套组，否则新建套组。
Future<void> importStickersInteractively(
  BuildContext context,
  WidgetRef ref, {
  String? packId,
}) async {
  final picked = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: const ['png', 'jpg', 'jpeg', 'gif', 'webp', 'zip'],
    allowMultiple: true,
    withData: true,
  );
  if (picked == null || !context.mounted) return;
  final notifier = ref.read(stickerLibraryProvider.notifier);
  final images = <StickerImportFile>[];
  var added = 0, untagged = 0, skipped = 0;
  try {
    for (final file in picked.files) {
      final bytes =
          file.bytes ??
          (file.path == null ? null : await File(file.path!).readAsBytes());
      if (bytes == null) {
        skipped++;
        continue;
      }
      if (file.name.toLowerCase().endsWith('.zip')) {
        final result = await notifier.importZip(bytes, file.name);
        added += result.added;
        untagged += result.untagged;
        skipped += result.skipped;
      } else {
        images.add(StickerImportFile(file.name, bytes));
      }
    }
    if (images.isNotEmpty) {
      final result = await notifier.importFiles(images, packId: packId);
      added += result.added;
      untagged += result.untagged;
      skipped += result.skipped;
    }
  } catch (error) {
    if (context.mounted) MoeToast.error(context, '导入失败：$error');
    return;
  }
  if (!context.mounted) return;
  final notes = [
    if (untagged > 0) '$untagged 张未标注，需补标签后 AI 才会使用',
    if (skipped > 0) '跳过 $skipped 个重复或不支持的文件',
  ];
  final message = '已导入 $added 张${notes.isEmpty ? '' : '；${notes.join('，')}'}';
  if (added == 0) {
    MoeToast.error(context, message);
  } else {
    MoeToast.success(context, message);
  }
}

/// 单个表情详情：大图、描述、标签与可触发词。用户表情可编辑和删除。
Future<void> showStickerDetailSheet(
  BuildContext context,
  WidgetRef ref,
  Sticker sticker, {
  required bool readOnly,
}) {
  final registry = StickerRegistry.instance;
  final notifier = ref.read(stickerLibraryProvider.notifier);
  return showMoeBottomSheet<void>(
    context: context,
    title: sticker.description.isNotEmpty ? sticker.description : '表情详情',
    builder: (sheetContext) {
      final colors = sheetContext.moeColors;
      final triggers = sticker.tags
          .expand(registry.triggerWordsOf)
          .toSet()
          .toList();
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              onTap: () => MoeImagePreview.show(
                sheetContext,
                stickerImageProvider(sticker),
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
                child: StickerImage(sticker: sticker, iconSize: 48),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              triggers.isEmpty
                  ? '还没有标签，AI 不会使用这张表情'
                  : 'AI 回复中带以下标签时，可能随机发出这张表情',
              style: TextStyle(fontSize: 13, color: colors.textSecondary),
            ),
            if (triggers.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final word in triggers) StickerTagChip(label: word),
                ],
              ),
            ],
            if (!readOnly) ...[
              const SizedBox(height: 12),
              MoeSettingsGroup(
                margin: EdgeInsets.zero,
                children: [
                  MoeSettingsRow(
                    label: '标签',
                    detailText: sticker.tags.isEmpty
                        ? '未标注'
                        : sticker.tags.join('、'),
                    trailingType: MoeSettingsRowTrailing.text,
                    onTap: () => showMoeAutoSaveTextEditor(
                      context: sheetContext,
                      title: '编辑标签',
                      hint: '用逗号或空格分隔，如：开心 好耶',
                      initialValue: sticker.tags.join('，'),
                      onSave: (value) async {
                        await notifier.updateSticker(
                          sticker.id,
                          tags: splitStickerTags(value),
                        );
                        if (sheetContext.mounted) {
                          Navigator.of(sheetContext).pop();
                        }
                      },
                    ),
                  ),
                  MoeSettingsRow(
                    label: '描述',
                    detailText: sticker.description.isEmpty
                        ? '无'
                        : sticker.description,
                    trailingType: MoeSettingsRowTrailing.text,
                    onTap: () => showMoeAutoSaveTextEditor(
                      context: sheetContext,
                      title: '编辑描述',
                      initialValue: sticker.description,
                      onSave: (value) async {
                        await notifier.updateSticker(
                          sticker.id,
                          description: value,
                        );
                        if (sheetContext.mounted) {
                          Navigator.of(sheetContext).pop();
                        }
                      },
                    ),
                  ),
                  MoeSettingsRow(
                    label: '删除这张表情',
                    labelColor: Theme.of(sheetContext).colorScheme.error,
                    trailingType: MoeSettingsRowTrailing.none,
                    showDivider: false,
                    onTap: () async {
                      await notifier.deleteStickers(sticker.packId, {
                        sticker.id,
                      });
                      if (sheetContext.mounted) {
                        Navigator.of(sheetContext).pop();
                      }
                    },
                  ),
                ],
              ),
            ],
          ],
        ),
      );
    },
  );
}

ImageProvider stickerImageProvider(Sticker sticker) => sticker.isAsset
    ? AssetImage(sticker.path)
    : FileImage(File(sticker.path));

/// 表情图片：内置资源或本机文件，加载失败显示占位图标。
class StickerImage extends StatelessWidget {
  const StickerImage({super.key, required this.sticker, this.iconSize = 30});

  final Sticker sticker;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return Image(
      image: ResizeImage.resizeIfNeeded(
        (240 * dpr).round(),
        null,
        stickerImageProvider(sticker),
      ),
      fit: BoxFit.contain,
      errorBuilder: (_, __, ___) => Center(
        child: Icon(
          Icons.emoji_emotions_outlined,
          color: context.moeColors.muted,
          size: iconSize,
        ),
      ),
    );
  }
}

/// 套组封面等小缩略图。
class StickerThumb extends StatelessWidget {
  const StickerThumb({super.key, required this.sticker, this.size = 36});

  final Sticker? sticker;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    return Container(
      width: size,
      height: size,
      padding: const EdgeInsets.all(3),
      decoration: MoeG2Decoration(radius: 10, color: colors.surfaceAlt),
      child: sticker == null
          ? Icon(
              Icons.emoji_emotions_outlined,
              color: colors.muted,
              size: size * 0.6,
            )
          : StickerImage(sticker: sticker!, iconSize: size * 0.6),
    );
  }
}

class StickerTagChip extends StatelessWidget {
  const StickerTagChip({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: MoeG2Decoration(
        radius: 999,
        color: colors.primary.withValues(alpha: 0.1),
      ),
      child: Text(label, style: TextStyle(fontSize: 13, color: colors.primary)),
    );
  }
}

/// 分节标题
class StickerSectionHeader extends StatelessWidget {
  const StickerSectionHeader({
    super.key,
    required this.title,
    required this.count,
  });

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

/// 表情网格（Sliver）。未标注的表情右上角带小圆点提示。
class StickerGrid extends StatelessWidget {
  const StickerGrid({
    super.key,
    required this.stickers,
    required this.onTap,
    this.selected,
  });

  final List<Sticker> stickers;
  final ValueChanged<Sticker> onTap;

  /// 不为空时进入多选模式，显示勾选状态。
  final Set<String>? selected;

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      sliver: SliverGrid(
        delegate: SliverChildBuilderDelegate(
          (context, index) => _StickerCell(
            sticker: stickers[index],
            selected: selected?.contains(stickers[index].id),
            onTap: () => onTap(stickers[index]),
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
}

/// 网格中的单个表情：圆角底 + 按压缩放反馈
class _StickerCell extends StatefulWidget {
  const _StickerCell({
    required this.sticker,
    required this.onTap,
    this.selected,
  });

  final Sticker sticker;
  final VoidCallback onTap;
  final bool? selected;

  @override
  State<_StickerCell> createState() => _StickerCellState();
}

class _StickerCellState extends State<_StickerCell> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final sticker = widget.sticker;
    final selected = widget.selected;

    return Tooltip(
      message: sticker.description.isNotEmpty
          ? sticker.description
          : sticker.tags.isEmpty
          ? '未标注'
          : sticker.tags.join('、'),
      child: GestureDetector(
        onTap: widget.onTap,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        child: AnimatedScale(
          scale: _pressed ? 0.92 : 1,
          duration: kAnimFast,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Container(
                decoration: MoeG2Decoration(
                  radius: 14,
                  color: selected == true
                      ? colors.primary.withValues(alpha: 0.16)
                      : colors.surfaceAlt,
                ),
                child: MoeG2ClipRRect(
                  radius: 14,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: StickerImage(sticker: sticker),
                  ),
                ),
              ),
              if (selected != null)
                Positioned(
                  top: 4,
                  right: 4,
                  child: Icon(
                    selected
                        ? Icons.check_circle_rounded
                        : Icons.radio_button_unchecked_rounded,
                    size: 18,
                    color: selected ? colors.primary : colors.muted,
                  ),
                )
              else if (sticker.tags.isEmpty)
                Positioned(
                  top: 6,
                  right: 6,
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: colors.toastWarning,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
