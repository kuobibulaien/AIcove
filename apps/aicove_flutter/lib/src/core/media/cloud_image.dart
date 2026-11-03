import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../ui/theme/tokens.dart';

import 'media_asset.dart';
import 'media_store.dart';

class CloudImage extends StatefulWidget {
  const CloudImage({
    super.key,
    required this.mediaId,
    this.cacheWidth,
    this.frameBuilder,
  });

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
  late Future<(File?, MediaAsset?)> _image = _load();

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

  Future<(File?, MediaAsset?)> _load() async {
    final media = await MediaStore.shared;
    final record = await media.load(widget.mediaId);
    return (await media.display(widget.mediaId), record?.asset);
  }

  @override
  void didUpdateWidget(CloudImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mediaId != widget.mediaId) _image = _load();
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

  Widget _brokenPlaceholder(BuildContext context) => SizedBox(
    width: 160,
    height: 100,
    child: Center(
      child: Icon(
        Icons.broken_image_outlined,
        size: 28,
        color: context.moeColors.textSecondary,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => FutureBuilder<(File?, MediaAsset?)>(
    future: _image,
    builder: (context, snapshot) {
      final data = snapshot.data;
      final isWaiting =
          snapshot.connectionState == ConnectionState.waiting ||
          (data != null && data.$1 == null && data.$2 != null);
      final image = data?.$1 != null
          ? Image.file(
              data!.$1!,
              fit: BoxFit.contain,
              cacheWidth: widget.cacheWidth,
              errorBuilder: (context, _, __) => _brokenPlaceholder(context),
            )
          : isWaiting
          ? _placeholder()
          : _brokenPlaceholder(context);
      return widget.frameBuilder?.call(context, data?.$2, image) ?? image;
    },
  );
}
