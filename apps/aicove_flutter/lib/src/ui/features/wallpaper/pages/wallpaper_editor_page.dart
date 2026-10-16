import 'dart:async';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/utils/data_image.dart';
import '../../../../features/chat/domain/conversation.dart';
import '../../../../features/settings/app_settings.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';
import '../../chat/widgets/chat_wallpaper_background.dart';
import '../widgets/wallpaper_preview_samples.dart';

/// 全局壁纸与角色专属壁纸共用的编辑页：上方宽窄屏两块预览画布，拖动改截取、
/// 双指或滚轮缩放；下方面板调遮罩、模糊与缩放。离开页面前自动保存。
///
/// 截取默认只存当前窗口形态的一份，另一形态沿用它；在另一形态的预览里调过后
/// 才单独保存，并可一键改回沿用。
class WallpaperEditorPage extends ConsumerStatefulWidget {
  const WallpaperEditorPage({
    super.key,
    required this.source,
    required this.style,
    required this.defaultStyle,
    required this.kind,
    required this.onSave,
    this.fallbackAlignment = Alignment.center,
    this.conversation,
    this.canChangeImage = false,
    this.onDelete,
  });

  /// 图片来源；角色壁纸可为 null（未设置，预览显示全局壁纸）。
  final String? source;
  final WallpaperStyle style;

  /// 「恢复默认」回到的调节。
  final WallpaperStyle defaultStyle;
  final WallpaperPreviewKind kind;

  /// 保存当前图片来源（[canChangeImage] 时可能已更换或清除）与调节。
  final Future<void> Function(String? source, WallpaperStyle style) onSave;
  final Alignment fallbackAlignment;

  /// 角色壁纸的会话，用于示例里的头像、名字与聊天样式。
  final Conversation? conversation;

  /// 是否可以在这里更换或清除图片（角色壁纸）。
  final bool canChangeImage;

  /// 删除这张壁纸；返回 true 表示已删除，页面不再保存并退出。
  final Future<bool> Function()? onDelete;

  @override
  ConsumerState<WallpaperEditorPage> createState() =>
      _WallpaperEditorPageState();
}

class _WallpaperEditorPageState extends ConsumerState<WallpaperEditorPage>
    with MoeAutoSaveState<WallpaperEditorPage> {
  late String? _source = widget.source;
  late WallpaperStyle _style = widget.style;
  WallpaperLayout? _target;
  Size? _imageSize;
  String? _sizedSource;

  // 手势开始时的截取，缩放按它乘倍数，避免逐帧累乘的误差。
  WallpaperFraming? _gestureStart;

  bool get _hasImage => _source?.trim().isNotEmpty ?? false;

  @override
  void initState() {
    super.initState();
    autoSave.configure(
      save: () => widget.onSave(_hasImage ? _source : null, _style),
      snapshot: () => moeAutoSaveSignature([_source, _style.toJson()]),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _target ??= WallpaperLayout.of(context);
    _resolveImageSize();
  }

  void _resolveImageSize() {
    final source = _hasImage ? _source!.trim() : null;
    if (source == _sizedSource) return;
    _sizedSource = source;
    _imageSize = null;
    final provider = source == null ? null : moeWallpaperImageProvider(source);
    if (provider == null) return;
    unawaited(
      resolveWallpaperImageSize(
        provider,
        createLocalImageConfiguration(context),
      ).then((size) {
        if (mounted && _sizedSource == source) {
          setState(() => _imageSize = size);
        }
      }),
    );
  }

  WallpaperFraming _framing(WallpaperLayout layout) =>
      _style.framingFor(layout, fallback: widget.fallbackAlignment);

  void _setFraming(WallpaperLayout layout, WallpaperFraming? framing) {
    setState(() {
      _target = layout;
      _style = _style.withFraming(layout, framing);
    });
  }

  void _onScaleStart(WallpaperLayout layout) {
    _gestureStart = _framing(layout);
    if (_target != layout) setState(() => _target = layout);
  }

  void _onScaleUpdate(
    WallpaperLayout layout,
    ScaleUpdateDetails details, {
    required Size box,
    required double fit,
  }) {
    final start = _gestureStart;
    final image = _imageSize;
    if (start == null || !_hasImage) return;
    var next = _framing(layout);
    if (details.pointerCount > 1 || details.scale != 1) {
      next = next.copyWith(scale: start.scale * details.scale);
    }
    if (image != null) {
      next = next.dragged(
        details.focalPointDelta / fit,
        box: box,
        image: image,
      );
    }
    _setFraming(layout, next);
  }

  void _onPointerSignal(WallpaperLayout layout, PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_hasImage) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      final current = _framing(layout);
      _setFraming(
        layout,
        current.copyWith(
          scale: current.scale * math.exp(-event.scrollDelta.dy / 400),
        ),
      );
    });
  }

  Future<void> _pickImage() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
    );
    if (!mounted || picked == null || picked.files.isEmpty) return;
    final file = picked.files.first;
    final bytes = file.bytes;
    if (bytes == null || bytes.isEmpty) return;
    setState(() {
      _source = buildDataImage(bytes, fileName: file.name);
      // 新图沿用遮罩与模糊，截取从头开始。
      _style = _style
          .withFraming(WallpaperLayout.narrow, null)
          .withFraming(WallpaperLayout.wide, null);
    });
    _resolveImageSize();
  }

  void _clearImage() {
    setState(() {
      _source = null;
      _style = widget.defaultStyle;
    });
    _resolveImageSize();
  }

  Future<void> _delete() async {
    final deleted = await widget.onDelete!();
    if (!deleted || !mounted) return;
    // 已删除的壁纸不能在离开时被写回。
    autoSave.configure(save: () async {}, snapshot: () => null);
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    return autoSavePage(
      MoePageScaffold(
        appBar: const MoeAppBar(title: '编辑壁纸', showBackButton: true),
        body: Column(
          children: [
            Expanded(child: _buildPreviews(context)),
            _buildPanel(context),
          ],
        ),
      ),
    );
  }

  Widget _buildPreviews(BuildContext context) {
    final current = WallpaperLayout.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        // 够宽时两块并排，否则用标签切换，一次看一块。
        final sideBySide = constraints.maxWidth >= 640;
        if (sideBySide) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  flex: 2,
                  child: _frame(WallpaperLayout.narrow, current),
                ),
                const SizedBox(width: 16),
                Expanded(flex: 5, child: _frame(WallpaperLayout.wide, current)),
              ],
            ),
          );
        }
        final target = _target ?? current;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: Column(
            children: [
              MoeSegmentedControl<WallpaperLayout>(
                key: const ValueKey('wallpaper_editor_layout_tabs'),
                value: target,
                segments: [
                  for (final layout in WallpaperLayout.values)
                    MoeSegment(
                      value: layout,
                      label: layout == current
                          ? '${layout.label}（当前）'
                          : layout.label,
                    ),
                ],
                onChanged: (layout) => setState(() => _target = layout),
              ),
              const SizedBox(height: 10),
              Expanded(child: _frame(target, current, showLabel: false)),
            ],
          ),
        );
      },
    );
  }

  /// 一块预览画布：标题行＋按真实尺寸布局后缩小的屏幕。
  Widget _frame(
    WallpaperLayout layout,
    WallpaperLayout current, {
    bool showLabel = true,
  }) {
    final colors = context.moeColors;
    final virtual = layout == WallpaperLayout.narrow
        ? kNarrowPreviewSize
        : kWidePreviewSize;
    final selected = _target == layout;
    final follows = layout != current && _style.ownFraming(layout) == null;
    return Column(
      children: [
        SizedBox(
          height: 32,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (showLabel)
                Text(
                  layout == current ? '${layout.label}（当前）' : layout.label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: MoeFontWeights.emphasis,
                    color: selected ? colors.primary : colors.text,
                  ),
                ),
              if (layout != current) ...[
                const SizedBox(width: 8),
                follows
                    ? Text(
                        '沿用${current.label}',
                        style: TextStyle(fontSize: 12, color: colors.muted),
                      )
                    : MoeSecondaryButton(
                        key: ValueKey('wallpaper_follow_${layout.name}'),
                        label: '改回沿用${current.label}',
                        size: MoeSecondaryButtonSize.sm,
                        onPressed: () => _setFraming(layout, null),
                      ),
              ],
            ],
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final fit = math.min(
                constraints.maxWidth / virtual.width,
                constraints.maxHeight / virtual.height,
              );
              final radius = BorderRadius.circular(
                layout == WallpaperLayout.narrow ? 28 * fit * 2 : 12,
              );
              return Center(
                child: Listener(
                  onPointerSignal: (event) => _onPointerSignal(layout, event),
                  child: GestureDetector(
                    key: ValueKey('wallpaper_preview_${layout.name}'),
                    behavior: HitTestBehavior.opaque,
                    onTap: () => setState(() => _target = layout),
                    onScaleStart: (_) => _onScaleStart(layout),
                    onScaleUpdate: (details) =>
                        _onScaleUpdate(layout, details, box: virtual, fit: fit),
                    onScaleEnd: (_) => _gestureStart = null,
                    child: Container(
                      width: virtual.width * fit,
                      height: virtual.height * fit,
                      decoration: BoxDecoration(
                        borderRadius: radius,
                        border: Border.all(
                          color: selected ? colors.primary : colors.border,
                          width: selected ? 2 : 1,
                        ),
                        boxShadow: colors.floatingShadows,
                      ),
                      child: ClipRRect(
                        borderRadius: radius,
                        child: FittedBox(
                          child: SizedBox.fromSize(
                            size: virtual,
                            child: IgnorePointer(
                              child: _screen(layout, virtual),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  /// 画布里的屏幕内容，按 [virtual] 尺寸布局。
  Widget _screen(WallpaperLayout layout, Size virtual) {
    final settings = ref.watch(appSettingsProvider).valueOrNull;
    final conversation = widget.conversation;
    final documentStyle =
        (conversation?.chatDisplayStyle ??
            settings?.chatDisplayStyle ??
            ChatDisplayStyle.bubble) ==
        ChatDisplayStyle.document;
    final Widget wallpaper;
    if (widget.kind == WallpaperPreviewKind.chat) {
      wallpaper = ChatWallpaperLayer(
        image: _source,
        fallbackColor: resolveChatBackgroundColor(
          context,
          settings?.lightChatBackground,
        ),
        style: _style,
        layout: layout,
      );
    } else {
      wallpaper = _hasImage
          ? MoeWallpaperView(
              source: _source!,
              style: _style,
              color: Theme.of(context).scaffoldBackgroundColor,
              layout: layout,
              fallbackAlignment: widget.fallbackAlignment,
            )
          : ColoredBox(color: Theme.of(context).scaffoldBackgroundColor);
    }
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(
        size: virtual,
        padding: EdgeInsets.zero,
        viewPadding: EdgeInsets.zero,
        viewInsets: EdgeInsets.zero,
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          wallpaper,
          WallpaperSampleScreen(
            kind: widget.kind,
            wide: layout == WallpaperLayout.wide,
            conversation: conversation,
            documentStyle: documentStyle,
          ),
        ],
      ),
    );
  }

  Widget _buildPanel(BuildContext context) {
    final colors = context.moeColors;
    final target = _target ?? WallpaperLayout.of(context);
    final framing = _framing(target);
    final enabled = _hasImage;
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: MoeSettingsContent(
        child: MoeFloatingSurface(
          key: const ValueKey('wallpaper_editor_panel'),
          radius: 24,
          baseline: MoeMaterialBaseline.background,
          padding: const EdgeInsets.fromLTRB(18, 10, 14, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              MoeLabeledSliderRow(
                key: const ValueKey('wallpaper_mask_slider'),
                label: '遮罩',
                value: _style.mask,
                display: '${(_style.mask * 100).round()}%',
                divisions: 20,
                onChanged: enabled
                    ? (v) => setState(() => _style = _style.copyWith(mask: v))
                    : null,
              ),
              MoeLabeledSliderRow(
                key: const ValueKey('wallpaper_blur_slider'),
                label: '模糊',
                value: _style.blur,
                max: kMaxWallpaperBlur,
                display: '${_style.blur.round()}',
                divisions: kMaxWallpaperBlur.round(),
                onChanged: enabled
                    ? (v) => setState(() => _style = _style.copyWith(blur: v))
                    : null,
              ),
              MoeLabeledSliderRow(
                key: const ValueKey('wallpaper_scale_slider'),
                label: '缩放',
                value: framing.scale,
                min: 1,
                max: kMaxWallpaperScale,
                divisions: ((kMaxWallpaperScale - 1) * 10).round(),
                display: '${framing.scale.toStringAsFixed(1)}×',
                onChanged: enabled
                    ? (v) => _setFraming(target, framing.copyWith(scale: v))
                    : null,
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  enabled ? '拖动${target.label}预览调整位置，双指或滚轮缩放' : '还没有选择图片',
                  style: TextStyle(fontSize: 12, color: colors.muted),
                ),
              ),
              Row(
                children: [
                  for (final (index, button) in [
                    if (widget.canChangeImage)
                      MoeSecondaryButton(
                        key: const ValueKey('wallpaper_pick_image'),
                        label: _hasImage ? '更换图片' : '选择图片',
                        size: MoeSecondaryButtonSize.sm,
                        onPressed: _pickImage,
                      ),
                    if (widget.canChangeImage && _hasImage)
                      MoeSecondaryButton(
                        key: const ValueKey('wallpaper_clear_image'),
                        label: '清除',
                        size: MoeSecondaryButtonSize.sm,
                        onPressed: _clearImage,
                      ),
                    MoeSecondaryButton(
                      key: const ValueKey('wallpaper_reset'),
                      label: '恢复默认',
                      size: MoeSecondaryButtonSize.sm,
                      onPressed: enabled
                          ? () => setState(() => _style = widget.defaultStyle)
                          : null,
                    ),
                    if (widget.onDelete != null)
                      MoeSecondaryButton(
                        key: const ValueKey('wallpaper_delete'),
                        label: '删除壁纸',
                        size: MoeSecondaryButtonSize.sm,
                        foregroundColor: colors.toastError,
                        onPressed: _delete,
                      ),
                  ].indexed) ...[
                    if (index > 0) const SizedBox(width: 8),
                    Expanded(child: button),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
