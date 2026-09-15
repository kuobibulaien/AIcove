import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../ui/shared/widgets/moe_floating_surface.dart';
import '../../ui/theme/tokens.dart';

import 'media_asset.dart';
import 'media_store.dart';

class CloudImage extends StatefulWidget {
  const CloudImage({
    super.key,
    required this.mediaId,
    this.cacheWidth,
    this.frameBuilder,
  }) : _viewer = false;

  const CloudImage._viewer({required this.mediaId})
    : _viewer = true,
      cacheWidth = null,
      frameBuilder = null;

  final bool _viewer;
  final String mediaId;
  final int? cacheWidth;

  /// Lets the existing photo frame use media metadata before laying out its
  /// image and placeholder. Resolving a file must not impose a square frame.
  final Widget Function(BuildContext, MediaAsset?, Widget)? frameBuilder;
  @override
  State<CloudImage> createState() => _CloudImageState();
}

class _CloudImageState extends State<CloudImage> {
  StreamSubscription<String>? _arrivals;
  late Future<(File?, bool, MediaAsset?)> _image = _load();

  @override
  void initState() {
    super.initState();
    unawaited(_watchArrivals());
  }

  Future<void> _watchArrivals() async {
    final media = await MediaStore.shared;
    if (!mounted) return;
    _arrivals = media.arrivals.listen((id) {
      if (mounted && id == widget.mediaId) {
        setState(() {
          _image = _load();
        });
      }
    });
  }

  @override
  void dispose() {
    unawaited(_arrivals?.cancel());
    super.dispose();
  }

  Future<(File?, bool, MediaAsset?)> _load() async {
    final media = await MediaStore.shared;
    final record = await media.load(widget.mediaId);
    final original =
        record?.originalPath != null &&
        await File(record!.originalPath!).exists();
    return (await media.display(widget.mediaId), original, record?.asset);
  }

  @override
  void didUpdateWidget(CloudImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mediaId != widget.mediaId) _image = _load();
  }

  bool _loadingOriginal = false;
  bool _originalFailed = false;

  Future<void> _loadOriginal() async {
    if (_loadingOriginal) return;
    setState(() {
      _loadingOriginal = true;
      _originalFailed = false;
    });
    try {
      final media = await MediaStore.shared;
      await media.original(widget.mediaId);
      final loaded = await _load();
      if (!mounted) return;
      setState(() {
        _image = Future.value(loaded);
      });
    } catch (_) {
      if (mounted) setState(() => _originalFailed = true);
    } finally {
      if (mounted) setState(() => _loadingOriginal = false);
    }
  }

  Widget _placeholder() => const SizedBox(
    width: 160,
    height: 100,
    child: Center(
      child: SizedBox.square(
        dimension: 28,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    ),
  );

  @override
  Widget build(
    BuildContext context,
  ) => FutureBuilder<(File?, bool, MediaAsset?)>(
    future: _image,
    builder: (context, snapshot) {
      final data = snapshot.data;
      final image = data?.$1 != null
          ? Image.file(
              data!.$1!,
              fit: BoxFit.contain,
              cacheWidth: widget.cacheWidth,
              errorBuilder: (_, __, ___) => _placeholder(),
            )
          : _placeholder();
      if (widget._viewer) {
        return Stack(
          fit: StackFit.expand,
          children: [
            Center(child: InteractiveViewer(child: image)),
            Positioned(
              top: 8,
              right: 8,
              child: IconButton(
                tooltip: '关闭',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close, color: Colors.white),
              ),
            ),
            if (data != null && !data.$2)
              Positioned(
                left: 12,
                bottom: 12,
                child: MoeFloatingSurface(
                  radius: 999,
                  child: TextButton(
                    onPressed: _loadingOriginal ? null : _loadOriginal,
                    style: TextButton.styleFrom(
                      foregroundColor: context.moeColors.text,
                      disabledForegroundColor: context.moeColors.textSecondary,
                      backgroundColor: Colors.transparent,
                      shape: const StadiumBorder(),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_loadingOriginal) ...[
                          SizedBox.square(
                            dimension: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: context.moeColors.textSecondary,
                            ),
                          ),
                          const SizedBox(width: 8),
                        ],
                        Text(
                          _loadingOriginal
                              ? '加载原图中…'
                              : _originalFailed
                              ? '加载失败，点击重试'
                              : '加载原图',
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      }
      final tappable = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => showDialog<void>(
          context: context,
          builder: (context) => Dialog(
            backgroundColor: Colors.black,
            insetPadding: const EdgeInsets.all(16),
            clipBehavior: Clip.antiAlias,
            child: Theme(
              data: Theme.of(context).copyWith(
                brightness: Brightness.dark,
                extensions: [
                  ...Theme.of(context).extensions.values.where(
                    (extension) => extension is! MoeColors,
                  ),
                  MoeColors.dark(accentColor: context.moeColors.primary),
                ],
              ),
              child: SizedBox.expand(
                child: CloudImage._viewer(mediaId: widget.mediaId),
              ),
            ),
          ),
        ),
        child: image,
      );
      return widget.frameBuilder?.call(context, data?.$3, tappable) ?? tappable;
    },
  );
}
