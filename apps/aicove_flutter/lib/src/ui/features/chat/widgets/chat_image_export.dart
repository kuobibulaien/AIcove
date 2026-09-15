import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/chat/domain/message.dart';
import '../../../../features/chat/presentation/widgets/message_bubble.dart';
import '../../../theme/tokens.dart';
import 'chat_message_list_items.dart';
import 'chat_export_wallpaper.dart';

/// Renders the complete selection, including bubbles outside the viewport.
/// Shares bubble rendering with chat; never reads or mutates raw history.
Future<Uint8List> renderChatImage({
  required BuildContext context,
  required List<Message> messages,
  required String title,
  String? avatarUrl,
  required Color background,
  double width = 420,
  ImageProvider? wallpaper,
  double wallpaperMaskOpacity = 0.8,
  double wallpaperBlurSigma = 0,
}) async {
  if (messages.isEmpty) throw StateError('请先选择消息');
  final container = ProviderScope.containerOf(context, listen: false);
  final mediaQuery = MediaQuery.of(context).copyWith(
    size: Size(width, 800),
    padding: EdgeInsets.zero,
    viewPadding: EdgeInsets.zero,
    viewInsets: EdgeInsets.zero,
    devicePixelRatio: 2,
  );
  final direction = Directionality.of(context);
  final themes = InheritedTheme.capture(from: context, to: null);
  final view = View.of(context);
  final colors = context.moeColors;

  // Decode every selected image before painting; a failed image must not turn
  // into an apparently successful export with an empty loading placeholder.
  final imageProviders = {
    for (final message in messages)
      for (final block in message.blocks ?? [])
        if (resolveChatMessageListImageProvider(block) case final provider?)
          provider,
  };
  Object? imageError;
  await Future.wait(
    imageProviders.map(
      (provider) => precacheImage(
        ResizeImage(
          provider,
          width: (width * 2).ceil(),
          height: 1600,
          policy: ResizeImagePolicy.fit,
        ),
        context,
        onError: (error, _) => imageError = error,
      ),
    ),
  ).timeout(
    const Duration(seconds: 20),
    onTimeout: () {
      throw StateError('图片加载超时，请稍后重试');
    },
  );
  if (imageError != null) throw StateError('部分图片无法读取，请加载图片后重试');
  if (!context.mounted) throw StateError('已取消导出');

  ui.Image? wallpaperImage;
  if (wallpaper != null) {
    try {
      wallpaperImage = await loadChatExportWallpaper(wallpaper, context);
    } catch (_) {
      throw StateError('聊天背景无法读取，请加载背景后重试');
    }
  }
  if (!context.mounted) {
    wallpaperImage?.dispose();
    throw StateError('已取消导出');
  }
  final boundary = RenderRepaintBoundary();
  final pipeline = PipelineOwner();
  final focus = FocusManager();
  final owner = BuildOwner(focusManager: focus);
  final renderView = RenderView(
    view: view,
    configuration: ViewConfiguration(
      logicalConstraints: BoxConstraints.tight(Size(width, 800)),
      physicalConstraints: BoxConstraints.tight(Size(width, 800)),
      devicePixelRatio: 1,
    ),
    child: RenderConstrainedOverflowBox(
      alignment: Alignment.topCenter,
      minWidth: width,
      maxWidth: width,
      minHeight: 0,
      maxHeight: double.infinity,
      child: boundary,
    ),
  );
  pipeline.rootNode = renderView;
  renderView.prepareInitialFrame();
  RenderObjectToWidgetElement<RenderBox>? element;
  ui.Image? image;
  try {
    element = RenderObjectToWidgetAdapter<RenderBox>(
      container: boundary,
      child: UncontrolledProviderScope(
        container: container,
        child: themes.wrap(
          Localizations.override(
            context: context,
            child: MediaQuery(
              data: mediaQuery,
              child: Directionality(
                textDirection: direction,
                child: TickerMode(
                  enabled: true,
                  child: Material(
                    color: background,
                    child: CustomPaint(
                      painter: wallpaperImage == null
                          ? null
                          : ChatExportWallpaperPainter(
                              image: wallpaperImage,
                              background: background,
                              maskOpacity: wallpaperMaskOpacity,
                              blurSigma: wallpaperBlurSigma,
                            ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: 20,
                          horizontal: 8,
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                              child: Text(
                                title,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: colors.text,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            for (final message in messages)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 3,
                                ),
                                child: MessageBubble(
                                  message: message,
                                  isMe: message.role == 'user',
                                  avatarUrl: message.role == 'user'
                                      ? null
                                      : avatarUrl,
                                  displayName: message.role == 'user'
                                      ? null
                                      : title,
                                  showName: false,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ).attachToRenderTree(owner);
    void flushLayout() {
      // LayoutBuilder has its own BuildScope. Its normal scheduling waits for
      // the next on-screen frame, so flush each scope in this detached tree.
      final scopes = <BuildScope>{};
      void rebuild(Element node) {
        if (scopes.add(node.buildScope)) owner.buildScope(node);
        node.visitChildren(rebuild);
      }

      rebuild(element!);
      pipeline.flushLayout();
    }

    flushLayout();
    owner.finalizeTree();
    // Bubble/Avatar widgets use resized providers. Warm those exact providers
    // after mounting as well, then rebuild asynchronous cached-image widgets.
    final warmed = <ImageProvider>{};
    for (var pass = 0; pass < 4; pass++) {
      await Future<void>.delayed(Duration.zero);
      if (!context.mounted) throw StateError('已取消导出');
      flushLayout();
      final pending = <Future<void>>[];
      void visit(Element node) {
        final widget = node.widget;
        if (widget is Image && warmed.add(widget.image)) {
          pending.add(precacheImage(widget.image, node, onError: (_, __) {}));
        }
        node.visitChildren(visit);
      }

      visit(element);
      await Future.wait(pending).timeout(const Duration(seconds: 20));
    }
    flushLayout();
    owner.finalizeTree();
    // Bound both raster dimensions and memory; very large exports ask the user
    // to select fewer messages instead of silently cropping the conversation.
    final size = boundary.size;
    final ratio = math.min(
      2.0,
      math.min(
        16384 / math.max(size.width, size.height),
        math.sqrt(16000000 / (size.width * size.height)),
      ),
    );
    if (!ratio.isFinite || ratio < 1) {
      throw StateError('所选消息过长，请分批导出');
    }
    pipeline.flushCompositingBits();
    pipeline.flushPaint();
    image = await boundary.toImage(pixelRatio: ratio);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) throw StateError('图片生成失败，请重试');
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    image?.dispose();
    wallpaperImage?.dispose();
    if (element != null) {
      RenderObjectToWidgetAdapter<RenderBox>(
        container: boundary,
      ).attachToRenderTree(owner, element);
      owner.buildScope(element);
      owner.finalizeTree();
    }
    pipeline.rootNode = null;
    renderView.dispose();
    pipeline.dispose();
    focus.dispose();
  }
}
