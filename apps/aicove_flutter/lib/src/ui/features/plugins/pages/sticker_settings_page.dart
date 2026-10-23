import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../../../features/stickers/sticker_library.dart';
import '../../../../features/stickers/sticker_library_provider.dart';
import '../../../../features/stickers/sticker_pack_download.dart';
import '../../../../features/stickers/sticker_registry.dart';
import '../../../../ui/shared/animations/parallax_slide_page_route.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/theme/tokens.dart';
import 'sticker_pack_page.dart';

/// 可选下载的动图表情包导入后的套组名，用来判断是否已下载。
const Set<String> gifStickerPackNames = {
  '呆猫八条与淑熊·动图',
  '奶茶鼠plus',
  '月薪喵',
  '高雅人士',
};

/// 表情包设置页：搜索、套组列表、导入。
class StickerSettingsPage extends ConsumerStatefulWidget {
  const StickerSettingsPage({super.key});

  @override
  ConsumerState<StickerSettingsPage> createState() =>
      _StickerSettingsPageState();
}

class _StickerSettingsPageState extends ConsumerState<StickerSettingsPage> {
  String _query = '';
  bool _downloading = false;

  Future<void> _downloadGifPacks() async {
    final ok = await showMeoTalkConfirm(
      context: context,
      title: '下载动图表情包',
      message: '下载 201 张动图，约 42MB，下载后按套组导入，已打好标签。'
          '会先测一下 Gitee 和 GitHub 哪个能连上，国内优先用 Gitee。',
      confirmText: '下载',
    );
    if (ok != true || !mounted) return;
    setState(() => _downloading = true);
    final client = http.Client();
    try {
      final download = await downloadStickerPack(client, gifStickerPackMirrors);
      final result = await ref
          .read(stickerLibraryProvider.notifier)
          .importZip(download.bytes, 'AIcove-gif-stickers.zip');
      if (mounted) {
        MoeToast.success(
          context,
          '已从 ${download.mirror.name} 导入 ${result.added} 张动图',
        );
      }
    } catch (error) {
      if (mounted) MoeToast.error(context, '下载失败：$error');
    } finally {
      client.close();
      if (mounted) setState(() => _downloading = false);
    }
  }

  Widget _buildDownloads(List<StickerPack> packs) {
    final downloaded = packs.any((p) => gifStickerPackNames.contains(p.name));
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      sliver: SliverToBoxAdapter(
        child: MoeSettingsGroup(
          title: '可选下载',
          titleFirst: true,
          children: [
            MoeSettingsRow(
              icon: Icons.download_rounded,
              label: '动图表情包',
              subtitle: _downloading
                  ? '下载中…'
                  : '201 张 · 约 42MB · Gitee / GitHub',
              trailingType: downloaded
                  ? MoeSettingsRowTrailing.custom
                  : MoeSettingsRowTrailing.chevron,
              trailing: downloaded
                  ? Text(
                      '已下载',
                      style: TextStyle(
                        fontSize: 14,
                        color: context.moeColors.muted,
                      ),
                    )
                  : null,
              enabled: !_downloading,
              showDivider: false,
              onTap: downloaded || _downloading ? null : _downloadGifPacks,
            ),
          ],
        ),
      ),
    );
  }

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
                  const EdgeInsets.fromLTRB(16, 12, 16, 8),
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
                ),
              )
            else if (packs == null)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: MoeLoadingIndicator()),
              )
            else if (searching)
              ..._buildSearchResults(packs)
            else if (packs.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: MoeEmptyState(
                  icon: Icons.emoji_emotions_outlined,
                  title: '还没有表情',
                  description: '点右上角 + 导入图片或 ZIP',
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                sliver: SliverToBoxAdapter(
                  child: MoeSettingsGroup(
                    title: '套组',
                    titleFirst: true,
                    children: [
                      for (final (index, pack) in packs.indexed)
                        MoeSettingsRow(
                          iconWidget: StickerThumb(
                            sticker: pack.stickers.firstOrNull,
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
              ),
            if (packs != null && !searching && !library.hasError)
              _buildDownloads(packs),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                child: Text(
                  '所有表情包来源于微信公众号公开表情，已标注原作者，如有侵权请联系删除。',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: colors.muted),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _packSubtitle(StickerPack pack) {
    final parts = [
      '${pack.stickers.length} 张',
      if (pack.author.isNotEmpty) pack.author,
    ];
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
        const SliverFillRemaining(
          hasScrollBody: false,
          child: MoeEmptyState(
            icon: Icons.search_off_rounded,
            title: '没有找到相关表情',
          ),
        )
      else
        StickerGrid(
          stickers: results,
          onTap: (sticker) => showStickerDetailSheet(context, ref, sticker),
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
    if (untagged > 0) '$untagged 张未标注',
    if (skipped > 0) '跳过 $skipped 个',
  ];
  final message = '已导入 $added 张${notes.isEmpty ? '' : '，${notes.join('，')}'}';
  if (added == 0) {
    MoeToast.error(context, message);
  } else {
    MoeToast.success(context, message);
  }
}

/// 单个表情详情：大图，标签、描述与删除。
Future<void> showStickerDetailSheet(
  BuildContext context,
  WidgetRef ref,
  Sticker sticker,
) {
  final notifier = ref.read(stickerLibraryProvider.notifier);
  return showMoeBottomSheet<void>(
    context: context,
    title: sticker.description.isNotEmpty ? sticker.description : '表情',
    builder: (sheetContext) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GestureDetector(
            onTap: () => MoeImagePreview.show(
              sheetContext,
              stickerImageProvider(sticker),
              heroTag: 'sticker_${sticker.id}',
            ),
            child: SizedBox(
              height: 180,
              child: MoeContentSurface(
                radius: 16,
                padding: const EdgeInsets.all(12),
                child: StickerImage(sticker: sticker, iconSize: 48),
              ),
            ),
          ),
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
                    if (sheetContext.mounted) Navigator.of(sheetContext).pop();
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
                    if (sheetContext.mounted) Navigator.of(sheetContext).pop();
                  },
                ),
              ),
              MoeSettingsRow(
                label: '删除这张表情',
                labelColor: Theme.of(sheetContext).colorScheme.error,
                trailingType: MoeSettingsRowTrailing.none,
                showDivider: false,
                onTap: () async {
                  await notifier.deleteStickers(sticker.packId, {sticker.id});
                  if (sheetContext.mounted) Navigator.of(sheetContext).pop();
                },
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

ImageProvider stickerImageProvider(Sticker sticker) =>
    FileImage(File(sticker.path));

/// 表情图片，加载失败显示占位图标。
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

/// 套组列表行的小封面。
class StickerThumb extends StatelessWidget {
  const StickerThumb({super.key, required this.sticker});

  final Sticker? sticker;

  static const double _size = 40;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    return SizedBox.square(
      dimension: _size,
      child: MoeContentSurface(
        radius: 10,
        padding: const EdgeInsets.all(4),
        child: sticker == null
            ? Icon(
                Icons.emoji_emotions_outlined,
                color: colors.muted,
                size: _size * 0.6,
              )
            : StickerImage(sticker: sticker!, iconSize: _size * 0.6),
      ),
    );
  }
}

/// 分节标题，样式与设置分组标题一致。
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
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Row(
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: MoeFontWeights.emphasis,
              color: colors.primary,
            ),
          ),
          const SizedBox(width: 6),
          Text('$count', style: TextStyle(fontSize: 12, color: colors.muted)),
        ],
      ),
    );
  }
}

/// 表情网格：单元格宽度固定上限，列数随可用宽度变化。未标注的右上角带小圆点。
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
          maxCrossAxisExtent: 88,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
        ),
      ),
    );
  }
}

/// 网格中的单个表情：统一内容面 + 按压缩放反馈。
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
              MoeContentSurface(
                radius: 14,
                color: selected == true
                    ? colors.primary.withValues(alpha: 0.16)
                    : null,
                padding: const EdgeInsets.all(8),
                child: StickerImage(sticker: sticker),
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
