import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/stickers/sticker_library.dart';
import '../../../../features/stickers/sticker_library_provider.dart';
import '../../../../features/stickers/sticker_registry.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/theme/tokens.dart';
import 'sticker_settings_page.dart';

/// 单个表情套组：启停、改名、删除，浏览／添加／批量删除表情。
/// 内置套组只能启停。
class StickerPackPage extends ConsumerStatefulWidget {
  const StickerPackPage({super.key, required this.packId});

  final String packId;

  @override
  ConsumerState<StickerPackPage> createState() => _StickerPackPageState();
}

class _StickerPackPageState extends ConsumerState<StickerPackPage> {
  /// 不为空时处于多选删除模式。
  Set<String>? _selected;

  StickerLibraryNotifier get _notifier =>
      ref.read(stickerLibraryProvider.notifier);

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final packs = ref.watch(stickerLibraryProvider).valueOrNull ?? const [];
    final pack = packs.where((p) => p.id == widget.packId).firstOrNull;
    if (pack == null) {
      return MoePageScaffold(
        backgroundColor: colors.surface,
        appBar: const MoeDetailAppBar(title: '表情套组'),
        body: const SizedBox.shrink(),
      );
    }
    final selected = _selected;
    final untagged = pack.stickers.where((s) => s.tags.isEmpty).toList();
    final tagged = pack.stickers.where((s) => s.tags.isNotEmpty).toList();

    return MoePageScaffold(
      backgroundColor: colors.surface,
      extendBodyBehindAppBar: true,
      appBar: MoeDetailAppBar(
        title: pack.name,
        actions: [
          if (selected != null)
            MoeIconButton(
              icon: Icons.delete_outline_rounded,
              semanticLabel: '删除所选表情',
              color: Theme.of(context).colorScheme.error,
              enabled: selected.isNotEmpty,
              onTap: () => _deleteSelected(selected),
            )
          else if (!pack.builtin) ...[
            MoeIconButton(
              icon: Icons.add_rounded,
              semanticLabel: '添加表情',
              onTap: () =>
                  importStickersInteractively(context, ref, packId: pack.id),
            ),
            MoeIconButton(
              icon: Icons.more_horiz_rounded,
              semanticLabel: '更多操作',
              onTap: () => _showPackActions(pack),
            ),
          ],
        ],
      ),
      body: Builder(
        builder: (context) => CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: moeUnderBarPadding(
                  context,
                  const EdgeInsets.only(top: 8),
                ),
                child: MoeSettingsGroup(
                  children: [
                    MoeSettingsRow(
                      label: '让 AI 使用这个套组',
                      subtitle: pack.builtin ? '内置套组只能启停，不能编辑' : null,
                      trailingType: MoeSettingsRowTrailing.switchControl,
                      switchValue: pack.enabled,
                      onSwitchChanged: (value) =>
                          _notifier.setPackEnabled(pack.id, value),
                      showDivider: false,
                    ),
                  ],
                ),
              ),
            ),
            if (pack.stickers.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: MoeEmptyState(
                  icon: Icons.emoji_emotions_outlined,
                  title: '这个套组还是空的',
                  description: '点右上角 + 选择图片或 ZIP 导入。',
                ),
              ),
            if (untagged.isNotEmpty) ...[
              SliverToBoxAdapter(
                child: StickerSectionHeader(
                  title: '未标注（AI 不会使用）',
                  count: untagged.length,
                ),
              ),
              _grid(untagged, pack),
            ],
            if (tagged.isNotEmpty) ...[
              SliverToBoxAdapter(
                child: StickerSectionHeader(
                  title: untagged.isEmpty ? '全部表情' : '已标注',
                  count: tagged.length,
                ),
              ),
              _grid(tagged, pack),
            ],
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        ),
      ),
    );
  }

  Widget _grid(List<Sticker> stickers, StickerPack pack) => StickerGrid(
    stickers: stickers,
    selected: _selected,
    onTap: (sticker) {
      final selected = _selected;
      if (selected != null) {
        setState(() {
          if (!selected.remove(sticker.id)) selected.add(sticker.id);
        });
        return;
      }
      showStickerDetailSheet(context, ref, sticker, readOnly: pack.builtin);
    },
  );

  Future<void> _showPackActions(StickerPack pack) => showMoeActionSheet(
    context: context,
    title: pack.name,
    actions: [
      MoeSheetAction(
        icon: Icons.edit_outlined,
        label: '重命名',
        onTap: () => showMoeAutoSaveTextEditor(
          context: context,
          title: '套组名称',
          initialValue: pack.name,
          onSave: (value) => _notifier.renamePack(pack.id, value),
        ),
      ),
      MoeSheetAction(
        icon: Icons.checklist_rounded,
        label: '批量删除表情',
        isDisabled: pack.stickers.isEmpty,
        onTap: () => setState(() => _selected = {}),
      ),
      MoeSheetAction(
        icon: Icons.delete_outline_rounded,
        label: '删除套组',
        isDestructive: true,
        onTap: () => _deletePack(pack),
      ),
    ],
  );

  Future<void> _deleteSelected(Set<String> ids) async {
    if (ids.isEmpty) return;
    final confirmed = await showMeoTalkDialog(
      context: context,
      title: '删除 ${ids.length} 张表情？',
      content: const Text('已发出的表情在聊天记录里仍会保留。'),
      confirmText: '删除',
      isDanger: true,
    );
    if (confirmed != true) return;
    await _notifier.deleteStickers(widget.packId, ids);
    if (mounted) setState(() => _selected = null);
  }

  Future<void> _deletePack(StickerPack pack) async {
    final confirmed = await showMeoTalkDialog(
      context: context,
      title: '删除套组「${pack.name}」？',
      content: Text('将删除其中 ${pack.stickers.length} 张表情；已发出的表情在聊天记录里仍会保留。'),
      confirmText: '删除',
      isDanger: true,
    );
    if (confirmed != true || !mounted) return;
    Navigator.of(context).pop();
    await _notifier.deletePack(pack.id);
  }
}
