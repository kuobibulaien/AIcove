part of 'message_bubble.dart';

/// [MessageBubble] 的媒体、文件、代码与错误块渲染。
extension _MessageBubbleMediaParts on MessageBubble {
  Widget _buildFileBlock(
    BuildContext context,
    FileBlock block,
    Color textColor,
  ) {
    final colors = context.moeColors;
    final subtitleColor = textColor.withValues(alpha: 0.75);
    final sizeText = _formatBytes(block.fileSize);

    return Padding(
      padding: const EdgeInsets.symmetric(
        vertical: MessageBubble._kRichBlockVerticalPadding,
      ),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: MoeG2Decoration(
          radius: 10,
          color: colors.surfaceAlt.withValues(alpha: 0.35),
          border: Border.all(
            color: colors.borderLight.withValues(alpha: 0.6),
            width: 0.5,
          ),
        ),
        child: Row(
          children: [
            Icon(Icons.insert_drive_file_outlined, color: textColor, size: 22),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    block.fileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: textColor,
                      fontSize: fontSize + 0.5,
                      fontWeight: MoeFontWeights.emphasis,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$sizeText · ${block.mimeType}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: subtitleColor,
                      fontSize: fontSize - 0.5,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)}KB';
    final mb = kb / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(1)}MB';
    final gb = mb / 1024;
    return '${gb.toStringAsFixed(1)}GB';
  }

  Size? _resolveImageDisplaySize(
    ImageBlock block, {
    required double maxWidth,
    required double maxHeight,
    MediaAsset? mediaAsset,
  }) {
    final hasBlockSize = (block.width ?? 0) > 0 && (block.height ?? 0) > 0;
    final rawWidth = (hasBlockSize ? block.width : mediaAsset?.width)
        ?.toDouble();
    final rawHeight = (hasBlockSize ? block.height : mediaAsset?.height)
        ?.toDouble();
    if (rawWidth == null ||
        rawHeight == null ||
        rawWidth <= 0 ||
        rawHeight <= 0) {
      return null;
    }
    final scale = math.min(
      1.0,
      math.min(maxWidth / rawWidth, maxHeight / rawHeight),
    );
    if (!scale.isFinite || scale <= 0) {
      return null;
    }
    return Size(rawWidth * scale, rawHeight * scale);
  }

  /// 统一渲染图片/表情包块
  /// ImageBlock → 等比缩放，最长边贴合最大尺寸（仿微信策略）
  /// EmojiBlock → BoxFit.contain 完整显示（表情包，小尺寸，无裁剪）
  Widget _buildMediaImage(
    BuildContext context,
    MessageBlock block, {
    double imagePreviewScale = 1.0,
  }) {
    final skin = context.skin;
    final radius = skin.bubbleRadius;
    final isSticker = block is EmojiBlock;

    // 尺寸策略：照片占屏幕65%，表情包固定小尺寸
    // imagePreviewScale 用于用户自定义缩放
    final double maxW;
    final double maxH;
    if (isSticker) {
      maxW = 140.0 * imagePreviewScale;
      maxH = 140.0 * imagePreviewScale;
    } else {
      final screenWidth = MediaQuery.of(context).size.width;
      maxW = (screenWidth * 0.65).clamp(180.0, 300.0) * imagePreviewScale;
      maxH = 300.0 * imagePreviewScale;
    }

    ImageProvider? imageProvider;
    String? mediaId;
    Widget imageWidget;
    final photoConstraints = BoxConstraints(maxWidth: maxW, maxHeight: maxH);
    var photoDisplaySize = block is ImageBlock
        ? _resolveImageDisplaySize(block, maxWidth: maxW, maxHeight: maxH)
        : null;
    // 照片无尺寸时（生成中/延迟交付）补一个保守的估算尺寸，让占位与成图同高，
    // 消除「无尺寸 ConstrainedBox(高 maxH*0.55) → 有尺寸 SizedBox」的高度跳变。
    // 仅照片路径，不动 EmojiBlock 表情包。
    if (!isSticker && photoDisplaySize == null) {
      final estimate = math.min(maxW, maxH);
      photoDisplaySize = Size(maxW, estimate);
    }

    // 列表内展示按目标显示宽降采样解码，避免原图分辨率 bitmap 进 ImageCache；
    // 传给 _showImagePreview 的 imageProvider（全屏预览/画廊/Hero）保持原图不受影响。
    // 有尺寸元数据时用实际显示宽（竖图更省），否则回退到 maxW；cacheWidth
    // 默认 allowUpscaling=false，小图不会被放大。
    final photoDecodeWidth =
        ((photoDisplaySize?.width ?? maxW) *
                MediaQuery.devicePixelRatioOf(context))
            .round();

    Widget wrapPhoto(Widget child) {
      if (photoDisplaySize == null) {
        return ConstrainedBox(constraints: photoConstraints, child: child);
      }
      return SizedBox(
        width: photoDisplaySize.width,
        height: photoDisplaySize.height,
        child: child,
      );
    }

    final showRetryHint =
        !isSticker &&
        block is ImageBlock &&
        block.status == BlockStatus.error &&
        onMediaLongPress != null &&
        MediaRegenerationTarget.canRegenerate(message, block);

    // 统一的占位/错误态
    Widget placeholder({bool isError = false}) => Container(
      width: isSticker ? null : photoDisplaySize?.width ?? maxW,
      height: isSticker ? null : photoDisplaySize?.height ?? maxH * 0.55,
      constraints: isSticker
          ? BoxConstraints(maxWidth: maxW * 0.7, maxHeight: maxH * 0.7)
          : null,
      color: Colors.grey.shade200,
      child: Center(
        child: isError && showRetryHint
            ? const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.broken_image, color: Colors.grey),
                  SizedBox(height: 6),
                  Text(
                    '生成失败，长按可重画',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              )
            : isError
            ? Icon(
                isSticker ? Icons.emoji_emotions : Icons.broken_image,
                color: Colors.grey,
              )
            : const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
      ),
    );

    // 根据 block 类型提取 ImageProvider 并构建 imageWidget
    if (isSticker) {
      final rawPath = StickerLibrary.resolveLocalPath(
        block.path.trim(),
        stickerId: block.emojiId,
      );
      final path = rawPath.replaceAll('\\', '/');
      mediaId = mediaIdFromReference(path);
      if (mediaId == null && path.isNotEmpty) {
        final isNetwork =
            path.startsWith('http://') || path.startsWith('https://');
        final isAsset =
            path.startsWith('assets/') || path.startsWith('packages/');
        if (isNetwork) {
          imageProvider = CachedNetworkImageProvider(path);
        } else if (isAsset) {
          imageProvider = AssetImage(path);
        } else {
          imageProvider = FileImage(File(_normalizeLocalFilePath(rawPath)));
        }
      }
      imageWidget = mediaId != null
          ? SizedBox(
              width: maxW,
              height: maxH,
              child: CloudImage(mediaId: mediaId, cacheWidth: photoDecodeWidth),
            )
          : imageProvider != null
          ? ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxW, maxHeight: maxH),
              child: Image(
                image: imageProvider,
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => placeholder(isError: true),
              ),
            )
          : placeholder(isError: true);
    } else {
      // 照片：用 ConstrainedBox 限制最大尺寸，图片等比缩放（仿微信）
      final imgBlock = block as ImageBlock;
      mediaId = imgBlock.mediaId;
      if (mediaId != null) {
        imageWidget = CloudImage(
          mediaId: mediaId,
          cacheWidth: photoDecodeWidth,
          frameBuilder: (context, asset, child) {
            final size =
                _resolveImageDisplaySize(
                  imgBlock,
                  maxWidth: maxW,
                  maxHeight: maxH,
                  mediaAsset: asset,
                ) ??
                photoDisplaySize!;
            return SizedBox(
              width: size.width,
              height: size.height,
              child: child,
            );
          },
        );
      } else if (imgBlock.localPath != null && imgBlock.localPath!.isNotEmpty) {
        imageProvider = FileImage(File(imgBlock.localPath!));
        imageWidget = wrapPhoto(
          Image.file(
            File(imgBlock.localPath!),
            fit: BoxFit.contain,
            cacheWidth: photoDecodeWidth,
            errorBuilder: (_, __, ___) => placeholder(isError: true),
          ),
        );
      } else if (imgBlock.url != null && imgBlock.url!.isNotEmpty) {
        imageProvider = CachedNetworkImageProvider(imgBlock.url!);
        imageWidget = wrapPhoto(
          CachedNetworkImage(
            imageUrl: imgBlock.url!,
            fit: BoxFit.contain,
            memCacheWidth: photoDecodeWidth,
            fadeInDuration: Duration.zero,
            fadeOutDuration: Duration.zero,
            placeholder: (context, url) => placeholder(),
            errorWidget: (context, url, error) => placeholder(isError: true),
          ),
        );
      } else if (imgBlock.base64 != null && imgBlock.base64!.isNotEmpty) {
        final dataBytes = decodeInlineBase64Image(imgBlock.base64);
        if (dataBytes != null) {
          imageProvider = _MemoryImageProviderCache.fromBytes(dataBytes);
          imageWidget = wrapPhoto(
            Image(
              image: ResizeImage.resizeIfNeeded(
                photoDecodeWidth,
                null,
                imageProvider,
              ),
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => placeholder(isError: true),
            ),
          );
        } else {
          imageWidget = placeholder(isError: true);
        }
      } else if (imgBlock.status == BlockStatus.pending) {
        imageWidget = wrapPhoto(placeholder(isError: false));
      } else {
        imageWidget = placeholder(isError: true);
      }
    }

    final heroTag = isSticker ? 'sticker_${block.id}' : 'image_${block.id}';
    final previewItem = mediaId != null
        ? ImagePreviewItem.media(mediaId: mediaId, heroTag: heroTag)
        : imageProvider != null
        ? ImagePreviewItem(provider: imageProvider, heroTag: heroTag)
        : null;
    final canTriggerMediaMenu =
        onMediaLongPress != null && block.status != BlockStatus.pending;

    final media = Builder(
      builder: (context) {
        return Listener(
          onPointerDown: (_useDesktopContextMenu && canTriggerMediaMenu)
              ? (event) {
                  if ((event.buttons & kSecondaryMouseButton) != 0) {
                    final box = context.findRenderObject() as RenderBox?;
                    if (box != null) {
                      onMediaLongPress!(box, block, event.position);
                    }
                  }
                }
              : null,
          child: GestureDetector(
            onTap: previewItem != null
                ? () => _showImagePreview(context, previewItem)
                : null,
            onLongPressStart: canTriggerMediaMenu
                ? (details) {
                    final box = context.findRenderObject() as RenderBox?;
                    if (box != null) {
                      onMediaLongPress!(box, block, details.globalPosition);
                    }
                  }
                : null,
            child: Hero(
              tag: heroTag,
              child: MoeG2ClipRRect(radius: radius, child: imageWidget),
            ),
          ),
        );
      },
    );

    return Padding(
      padding: const EdgeInsets.symmetric(
        vertical: MessageBubble._kMediaBlockVerticalPadding,
      ),
      child: !isSticker && block is ImageBlock && block.versions.length > 1
          ? Stack(
              children: [
                media,
                Positioned(
                  right: 6,
                  bottom: 6,
                  child: _buildImageVersionSwitcher(block),
                ),
              ],
            )
          : media,
    );
  }

  /// 多版本图片右下角的半透明切换胶囊：‹ 当前/总数 ›
  Widget _buildImageVersionSwitcher(ImageBlock block) {
    final count = block.versions.length;
    final index = block.activeVersionIndex.clamp(0, count - 1);
    const textStyle = TextStyle(fontSize: 12, color: Colors.white, height: 1.2);

    Widget arrow(String glyph, Key key, int? target) => GestureDetector(
      key: key,
      behavior: HitTestBehavior.opaque,
      onTap: target == null
          ? null
          : () => onSelectImageVersion?.call(block, target),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        child: Opacity(
          opacity: target == null ? 0.35 : 1,
          child: Text(glyph, style: textStyle),
        ),
      ),
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          arrow(
            '‹',
            Key('image_version_prev_${block.id}'),
            index > 0 ? index - 1 : null,
          ),
          Text('${index + 1}/$count', style: textStyle),
          arrow(
            '›',
            Key('image_version_next_${block.id}'),
            index < count - 1 ? index + 1 : null,
          ),
        ],
      ),
    );
  }

  /// 显示图片全屏预览：有整段聊天的图片清单时进画廊，可左右滑动切换。
  void _showImagePreview(BuildContext context, ImagePreviewItem item) {
    final images = chatImages;
    final index =
        images?.indexWhere((image) => image.heroTag == item.heroTag) ?? -1;
    if (images != null && images.length > 1 && index >= 0) {
      MoeImagePreview.showGallery(context, images: images, initialIndex: index);
    } else {
      MoeImagePreview.showGallery(context, images: [item]);
    }
  }

  /// 渲染音频块
  Widget _buildAudioBlock(
    AudioBlock block,
    Color textColor, {
    required bool isExpanded,
  }) {
    final audioText = block.text?.trim();
    final hasText = audioText != null && audioText.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        AudioPlayerWidget(block: block, textColor: textColor),
        if (isExpanded && hasText) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.only(top: 6),
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(
                  color: textColor.withValues(alpha: 0.15),
                  width: 0.5,
                ),
              ),
            ),
            child: _buildMessageText(
              audioText,
              TextStyle(
                color: textColor,
                height: MoeBubbleStyle.textHeight,
                fontSize: fontSize,
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// 渲染代码块
  Widget _buildCodeBlock(CodeBlock block, Color textColor) {
    return MoeCodeBlock(
      code: block.content,
      language: block.language,
      foregroundColor: textColor,
    );
  }

  /// 渲染错误块
  Widget _buildErrorBlock(ErrorBlock block) {
    return Container(
      margin: const EdgeInsets.symmetric(
        vertical: MessageBubble._kRichBlockVerticalPadding,
      ),
      padding: const EdgeInsets.all(12),
      decoration: MoeG2Decoration(
        radius: 8,
        color: Colors.red.shade100,
        border: Border.all(color: Colors.red.shade300),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: Colors.red.shade700, size: 20),
          // 附加内容区域的水平分隔适当减半，保持一致
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              block.message,
              style: TextStyle(
                color: Colors.red.shade900,
                fontSize: fontSize + 1,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
