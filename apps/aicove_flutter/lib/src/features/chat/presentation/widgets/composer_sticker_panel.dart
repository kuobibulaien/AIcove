import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../ui/features/plugins/pages/sticker_settings_page.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../stickers/sticker_library.dart';
import '../../../stickers/sticker_library_provider.dart';
import '../../../stickers/sticker_registry.dart';

/// 聊天输入框底部的表情包选择面板。
///
/// 展示用户表情库中的全部套组（包括仅自己使用、或尚未打标的表情），点击即可直接发送。
class ComposerStickerPanel extends ConsumerStatefulWidget {
  const ComposerStickerPanel({
    super.key,
    required this.onBack,
    required this.onStickerSelected,
  });

  final VoidCallback onBack;
  final ValueChanged<Sticker> onStickerSelected;

  @override
  ConsumerState<ComposerStickerPanel> createState() =>
      _ComposerStickerPanelState();
}

class _ComposerStickerPanelState extends ConsumerState<ComposerStickerPanel> {
  String? _selectedPackId;

  StickerPack? _resolveSelectedPack(List<StickerPack> packs) {
    if (packs.isEmpty) return null;
    if (_selectedPackId != null) {
      for (final pack in packs) {
        if (pack.id == _selectedPackId) return pack;
      }
    }
    // 优先默认选中非空套组
    for (final pack in packs) {
      if (pack.stickers.isNotEmpty) return pack;
    }
    return packs.first;
  }

  void _openStickerSettings(BuildContext context) {
    MoeWorkspace.open(context, const StickerSettingsPage());
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final libraryAsync = ref.watch(stickerLibraryProvider);
    final packs = libraryAsync.valueOrNull;
    final selectedPack = packs == null ? null : _resolveSelectedPack(packs);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
          child: Row(
            children: [
              _HeaderIconButton(
                key: const ValueKey('composer_sticker_back'),
                icon: Icons.arrow_back_ios_new_rounded,
                tooltip: '返回更多',
                onTap: widget.onBack,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: packs == null || packs.isEmpty
                    ? Text(
                        '表情',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: MoeFontWeights.emphasis,
                          color: colors.text,
                        ),
                      )
                    : SizedBox(
                        height: 32,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: packs.length,
                          separatorBuilder: (_, __) => const SizedBox(width: 6),
                          itemBuilder: (context, index) {
                            final pack = packs[index];
                            final active = pack.id == selectedPack?.id;
                            return _PackTabChip(
                              label: pack.name,
                              active: active,
                              onTap: () =>
                                  setState(() => _selectedPackId = pack.id),
                            );
                          },
                        ),
                      ),
              ),
              const SizedBox(width: 6),
              _HeaderIconButton(
                key: const ValueKey('composer_sticker_import'),
                icon: Icons.add_rounded,
                tooltip: '添加表情',
                onTap: () => importStickersInteractively(
                  context,
                  ref,
                  packId: selectedPack?.id,
                ),
              ),
              const SizedBox(width: 4),
              _HeaderIconButton(
                key: const ValueKey('composer_sticker_manage'),
                icon: Icons.settings_outlined,
                tooltip: '管理表情包',
                onTap: () => _openStickerSettings(context),
              ),
            ],
          ),
        ),
        Expanded(
          child: _buildBody(
            context,
            libraryAsync: libraryAsync,
            packs: packs,
            selectedPack: selectedPack,
          ),
        ),
      ],
    );
  }

  Widget _buildBody(
    BuildContext context, {
    required AsyncValue<List<StickerPack>> libraryAsync,
    required List<StickerPack>? packs,
    required StickerPack? selectedPack,
  }) {
    final colors = context.moeColors;
    if (libraryAsync.hasError) {
      return Center(
        child: Text(
          '表情加载失败',
          style: TextStyle(fontSize: 13, color: colors.muted),
        ),
      );
    }
    if (packs == null) {
      return const Center(child: MoeLoadingIndicator());
    }
    if (packs.isEmpty || selectedPack == null || selectedPack.stickers.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.emoji_emotions_outlined,
              size: 32,
              color: colors.muted,
            ),
            const SizedBox(height: 8),
            Text(
              packs.isEmpty ? '还没有添加表情' : '这个套组还没有表情',
              style: TextStyle(fontSize: 13, color: colors.muted),
            ),
            const SizedBox(height: 10),
            GestureDetector(
              onTap: () => importStickersInteractively(
                context,
                ref,
                packId: selectedPack?.id,
              ),
              child: MoeButtonSurface(
                radius: 999,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 7,
                ),
                child: Text(
                  '导入图片或压缩包',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: MoeFontWeights.emphasis,
                    color: colors.accentColor,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    final stickers = selectedPack.stickers;
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(22)),
      child: GridView.builder(
        padding: EdgeInsets.zero,
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 98,
          crossAxisSpacing: 2,
          mainAxisSpacing: 2,
        ),
        itemCount: stickers.length,
        itemBuilder: (context, index) {
          final sticker = stickers[index];
          return _StickerPickerCell(
            key: ValueKey('composer_sticker_${sticker.id}'),
            sticker: sticker,
            onTap: () => widget.onStickerSelected(sticker),
          );
        },
      ),
    );
  }
}

class _HeaderIconButton extends StatelessWidget {
  const _HeaderIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: SizedBox.square(
          dimension: 32,
          child: MoeButtonSurface(
            radius: 10,
            padding: EdgeInsets.zero,
            child: Center(
              child: Icon(icon, size: 18, color: colors.textSecondary),
            ),
          ),
        ),
      ),
    );
  }
}

class _PackTabChip extends StatelessWidget {
  const _PackTabChip({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    return GestureDetector(
      onTap: onTap,
      child: MoeContentSurface(
        radius: 999,
        color: active ? colors.accentColor.withValues(alpha: 0.16) : null,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        child: Center(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              fontWeight:
                  active ? MoeFontWeights.emphasis : MoeFontWeights.normal,
              color: active ? colors.accentColor : colors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

class _StickerPickerCell extends StatefulWidget {
  const _StickerPickerCell({
    super.key,
    required this.sticker,
    required this.onTap,
  });

  final Sticker sticker;
  final VoidCallback onTap;

  @override
  State<_StickerPickerCell> createState() => _StickerPickerCellState();
}

class _StickerPickerCellState extends State<_StickerPickerCell> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final sticker = widget.sticker;
    final label = sticker.tags.isNotEmpty
        ? sticker.tags.join('、')
        : sticker.description;
    final child = GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(
            color: colors.surfaceAlt,
            child: StickerImage(sticker: sticker, iconSize: 24),
          ),
          if (_pressed) const ColoredBox(color: Color(0x1F000000)),
        ],
      ),
    );
    if (label.isEmpty) return child;
    return Tooltip(message: label, child: child);
  }
}
