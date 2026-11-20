part of 'message_bubble.dart';

/// 文档模式的消息行：不画头像，消息落在居中的阅读栏里。
///
/// 助手正文占满阅读栏宽度；用户消息是靠右的浅色块，最宽占阅读栏的 85%。
/// 换发言方时（[startsTurn]）多留一段间距，让一问一答成组。
/// 气泡正文选择区：文字可直接选中，长按（右键）菜单照旧。
///
/// 触屏长按后原地松手：清掉长按顺带选中的词，弹消息菜单；长按后滑动：选中
/// 文字，松手弹菜单并带上选中内容（选区随即收起）；双击全屏看文字。鼠标拖动选字，右键弹菜单。系统选择工具栏
/// 不显示，复制等操作统一走消息菜单。
class _SelectableBubble extends StatefulWidget {
  const _SelectableBubble({
    required this.onLongPress,
    required this.selectionColor,
    required this.child,
  });

  final void Function(
    RenderBox box,
    Offset globalPosition,
    String? selectedText,
  )
  onLongPress;
  final Color selectionColor;
  final Widget child;

  @override
  State<_SelectableBubble> createState() => _SelectableBubbleState();
}

class _SelectableBubbleState extends State<_SelectableBubble> {
  final _areaKey = GlobalKey<SelectionAreaState>();
  Timer? _pressTimer;
  int? _pointer;
  Offset _downPosition = Offset.zero;
  bool _longPressed = false;
  bool _dragged = false;
  Timer? _doubleTapTimer;
  Offset _firstTapPosition = Offset.zero;
  final _selectionDelegate = _LineAwareSelectionDelegate();

  SelectableRegionState? get _region => _areaKey.currentState?.selectableRegion;

  String? _selected;

  String? _selectedText() => _selected;

  // 选择区的手势在本次指针事件分发末尾才处理（长按结束才定稿选区，右键会
  // 抢焦点），菜单都推迟到分发结束后再弹。
  void _openMenuLater(Offset position, String? Function() selectedText) {
    scheduleMicrotask(() {
      if (!mounted) return;
      final box = context.findRenderObject() as RenderBox?;
      if (box != null) widget.onLongPress(box, position, selectedText());
    });
  }

  void _reset() {
    _pressTimer?.cancel();
    _pressTimer = null;
    _pointer = null;
    _longPressed = false;
    _dragged = false;
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (event.kind == PointerDeviceKind.mouse) {
      if ((event.buttons & kSecondaryMouseButton) != 0) {
        // 右键会改选区（macOS 选词、Windows 折叠），先记下原选区。
        final selected = _selectedText();
        _openMenuLater(event.position, () => selected);
      }
      return;
    }
    _reset();
    _pointer = event.pointer;
    _downPosition = event.position;
    _pressTimer = Timer(kLongPressTimeout, () => _longPressed = true);
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (event.pointer != _pointer) return;
    if ((event.position - _downPosition).distance <= kTouchSlop) return;
    if (_longPressed) {
      _dragged = true;
    } else {
      // 长按前已移动：是滚动，不是长按。
      _reset();
    }
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (event.pointer != _pointer) return;
    final longPressed = _longPressed;
    final dragged = _dragged;
    final position = _downPosition;
    _reset();
    if (!longPressed) {
      _handleTap(position);
      return;
    }
    _openMenuLater(position, () {
      final selected = dragged ? _selectedText() : null;
      // 选中内容交给菜单；收起选区和把手，免得把手浮在菜单上面。
      _region
        ?..hideToolbar()
        ..clearSelection();
      return selected;
    });
  }

  // 触屏双击：全屏看这条消息的文字（类似微信）。鼠标双击仍是选词。
  void _handleTap(Offset position) {
    final isDoubleTap =
        _doubleTapTimer?.isActive == true &&
        (position - _firstTapPosition).distance <= kDoubleTapSlop;
    _doubleTapTimer?.cancel();
    if (!isDoubleTap) {
      _firstTapPosition = position;
      _doubleTapTimer = Timer(kDoubleTapTimeout, () {});
      return;
    }
    _doubleTapTimer = null;
    scheduleMicrotask(() {
      final region = _region;
      if (!mounted || region == null) return;
      // 选区里拿到的就是气泡实际显示的文字（Markdown 已渲染、引用已拆开）。
      region.selectAll();
      final text = _selected;
      region
        ..hideToolbar()
        ..clearSelection();
      if (text != null) showMessageTextViewer(context, text);
    });
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    if (event.pointer == _pointer) _reset();
  }

  @override
  void dispose() {
    _pressTimer?.cancel();
    _doubleTapTimer?.cancel();
    _selectionDelegate.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _handlePointerDown,
      onPointerMove: _handlePointerMove,
      onPointerUp: _handlePointerUp,
      onPointerCancel: _handlePointerCancel,
      child: SelectionArea(
        key: _areaKey,
        contextMenuBuilder: (context, state) => const SizedBox.shrink(),
        onSelectionChanged: (content) {
          final text = content?.plainText;
          _selected = text == null || text.isEmpty ? null : text;
        },
        child: SelectionContainer(
          delegate: _selectionDelegate,
          child: DefaultSelectionStyle(
            selectionColor: widget.selectionColor,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

/// 选中内容按行拼接：Flutter 默认把各段文字首尾相连，Markdown 段落、长文本
/// 逐行排版（[IncrementalMessageText]）复制出来会丢换行。上下错开的两段之间
/// 补换行，同一行内的片段照旧直接相连；去掉空行占位用的零宽空格。
class _LineAwareSelectionDelegate extends StaticSelectionContainerDelegate {
  @override
  SelectedContent? getSelectedContent() {
    final buffer = StringBuffer();
    var hasContent = false;
    double? previousBottom;
    for (final selectable in selectables) {
      final content = selectable.getSelectedContent();
      if (content == null) continue;
      final top = MatrixUtils.transformPoint(
        selectable.getTransformTo(null),
        Offset.zero,
      ).dy;
      if (previousBottom != null && top >= previousBottom - 1) {
        buffer.write('\n');
      }
      previousBottom = top + selectable.size.height;
      buffer.write(content.plainText);
      hasContent = true;
    }
    if (!hasContent) return null;
    return SelectedContent(
      plainText: buffer.toString().replaceAll('\u200b', ''),
    );
  }
}

class _FoldBubbleGestureHost extends StatefulWidget {
  const _FoldBubbleGestureHost({
    required this.onLongPress,
    required this.expandWidth,
    required this.builder,
  });

  final void Function(
    RenderBox box,
    Offset globalPosition,
    String? selectedText,
  )?
  onLongPress;
  final bool expandWidth;
  final Widget Function(ValueChanged<SelectedContent?> onSelectionChanged)
  builder;

  @override
  State<_FoldBubbleGestureHost> createState() => _FoldBubbleGestureHostState();
}

class _FoldBubbleGestureHostState extends State<_FoldBubbleGestureHost> {
  Timer? _pressTimer;
  int? _pointer;
  Offset _downPosition = Offset.zero;
  bool _longPressed = false;
  bool _dragged = false;
  String? _selected;

  void _openMenuLater(Offset position, String? Function() selectedText) {
    final onLongPress = widget.onLongPress;
    if (onLongPress == null) return;
    scheduleMicrotask(() {
      if (!mounted) return;
      final box = context.findRenderObject() as RenderBox?;
      if (box != null) onLongPress(box, position, selectedText());
    });
  }

  void _reset() {
    _pressTimer?.cancel();
    _pressTimer = null;
    _pointer = null;
    _longPressed = false;
    _dragged = false;
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (widget.onLongPress == null) return;
    if (event.kind == PointerDeviceKind.mouse) {
      if ((event.buttons & kSecondaryMouseButton) != 0) {
        final selected = _selected;
        _openMenuLater(event.position, () => selected);
      }
      return;
    }
    _reset();
    _pointer = event.pointer;
    _downPosition = event.position;
    _pressTimer = Timer(kLongPressTimeout, () => _longPressed = true);
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (event.pointer != _pointer) return;
    if ((event.position - _downPosition).distance <= kTouchSlop) return;
    if (_longPressed) {
      _dragged = true;
    } else {
      _reset();
    }
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (event.pointer != _pointer) return;
    final longPressed = _longPressed;
    final dragged = _dragged;
    final position = _downPosition;
    _reset();
    if (!longPressed) return;
    _openMenuLater(position, () => dragged ? _selected : null);
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    if (event.pointer == _pointer) _reset();
  }

  @override
  void dispose() {
    _pressTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget content = widget.builder((selectedContent) {
      final text = selectedContent?.plainText;
      _selected = text == null || text.isEmpty ? null : text;
    });
    if (widget.expandWidth) {
      content = SizedBox(
        width: double.infinity,
        child: Align(alignment: Alignment.topLeft, child: content),
      );
    }
    if (widget.onLongPress == null) return content;
    return Listener(
      behavior: widget.expandWidth
          ? HitTestBehavior.opaque
          : HitTestBehavior.translucent,
      onPointerDown: _handlePointerDown,
      onPointerMove: _handlePointerMove,
      onPointerUp: _handlePointerUp,
      onPointerCancel: _handlePointerCancel,
      child: content,
    );
  }
}

class _DocumentMessageRow extends StatelessWidget {
  static const double maxReadingWidth = 760;
  static const double userMaxWidthFactor = 0.85;
  static const double turnGap = 14;
  static const double selectionGutter = 50; // 多选框 42 + 间距 8
  static const EdgeInsets userPadding = EdgeInsets.symmetric(
    horizontal: 14,
    vertical: 9,
  );

  final bool isMe;
  final bool startsTurn;
  final bool reserveSelectionGutter;
  final Widget Function(Widget child)? selectionWrapper;
  final Widget? failedIndicator;
  final Widget child;

  const _DocumentMessageRow({
    required this.isMe,
    required this.startsTurn,
    required this.reserveSelectionGutter,
    required this.selectionWrapper,
    required this.failedIndicator,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    // 助手一侧贴阅读栏左缘，只有折叠块这类窄内容时也不居中。
    Widget content = Align(alignment: Alignment.topLeft, child: child);
    if (isMe) {
      content = LayoutBuilder(
        builder: (context, constraints) => Row(
          mainAxisAlignment: MainAxisAlignment.end,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ?failedIndicator,
            Flexible(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: constraints.maxWidth * userMaxWidthFactor,
                ),
                child: child,
              ),
            ),
          ],
        ),
      );
    }
    final inner = reserveSelectionGutter
        ? Padding(
            padding: const EdgeInsets.only(left: selectionGutter),
            child: content,
          )
        : content;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, startsTurn ? turnGap : 0, 16, 0),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: maxReadingWidth),
          child: selectionWrapper?.call(inner) ?? inner,
        ),
      ),
    );
  }
}

/// 头像列（头像 + 与气泡的间隔）。
///
/// showAvatar=false 时仍保留同宽占位，确保连续消息对齐不抖动。
class _AvatarSlot extends StatelessWidget {
  static const double _kAvatarGap = MessageBubble.avatarBubbleGap;
  static const double fallbackWidth = _Avatar.kSize + _kAvatarGap;

  final bool showAvatar;
  final bool isUser;
  final Widget avatar;
  final bool gapOnLeft;

  const _AvatarSlot({
    required this.showAvatar,
    required this.isUser,
    required this.avatar,
    required this.gapOnLeft,
  });

  @override
  Widget build(BuildContext context) {
    const placeholder = SizedBox(width: _Avatar.kSize);

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (gapOnLeft) const SizedBox(width: _kAvatarGap),
        showAvatar ? avatar : placeholder,
        if (!gapOnLeft) const SizedBox(width: _kAvatarGap),
      ],
    );
  }
}

/// 根据头像列实际渲染宽度，限制气泡最大宽度。
///
/// 规则：
/// - 默认双头像：左右都预留头像列宽度
/// - 隐藏用户头像：仅预留左侧头像列
/// - 头像与气泡首行竖直居中对齐，较矮的一方下移
class _AvatarAwareBubbleRow extends StatelessWidget {
  static const double _kMinBubbleMaxWidth = 120.0;
  static const double _kFailedIndicatorWidth = 24.0; // 20 + 右侧间距 4

  final Widget Function(Widget child)? selectionWrapper;
  final String debugId;
  final bool isMe;
  final bool hideUserAvatar;
  final bool hasVisibleAvatar;
  final bool showLeftSlot;
  final bool showRightSlot;
  final bool hasFailedIndicator;
  final Widget? failedIndicator;
  final Widget leftSlot;
  final Widget rightSlot;
  final Widget bubbleChild;

  /// 单行文字气泡的高度，用于把头像与首行对齐。
  final double firstLineHeight;

  const _AvatarAwareBubbleRow({
    required this.debugId,
    this.selectionWrapper,
    required this.isMe,
    required this.hideUserAvatar,
    required this.hasVisibleAvatar,
    required this.showLeftSlot,
    required this.showRightSlot,
    required this.hasFailedIndicator,
    required this.failedIndicator,
    required this.leftSlot,
    required this.rightSlot,
    required this.bubbleChild,
    required this.firstLineHeight,
  });

  @override
  Widget build(BuildContext context) {
    final centerOffset = (_Avatar.kSize - firstLineHeight) / 2;
    final bubbleTop = hasVisibleAvatar ? math.max(0.0, centerOffset) : 0.0;
    final avatarTop = math.max(0.0, -centerOffset);
    Widget slot(Widget child) => avatarTop == 0
        ? child
        : Padding(padding: EdgeInsets.only(top: avatarTop), child: child);
    return LayoutBuilder(
      builder: (context, constraints) {
        const leftReserve = _AvatarSlot.fallbackWidth;
        final rightReserve = hideUserAvatar ? 0.0 : _AvatarSlot.fallbackWidth;
        final failedReserve = (isMe && hasFailedIndicator)
            ? _AvatarAwareBubbleRow._kFailedIndicatorWidth
            : 0.0;
        final bubbleWidthUpperBound = constraints.maxWidth > 0
            ? constraints.maxWidth
            : 0.0;
        final bubbleWidthLowerBound = math.min(
          _AvatarAwareBubbleRow._kMinBubbleMaxWidth,
          bubbleWidthUpperBound,
        );
        final maxBubbleWidth =
            (constraints.maxWidth - leftReserve - rightReserve - failedReserve)
                .clamp(bubbleWidthLowerBound, bubbleWidthUpperBound)
                .toDouble();

        Widget bubbleArea = ConstrainedBox(
          key: ValueKey<String>('message_bubble_constraints_$debugId'),
          constraints: BoxConstraints(maxWidth: maxBubbleWidth),
          child: bubbleChild,
        );

        if (isMe && hasFailedIndicator && failedIndicator != null) {
          bubbleArea = Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [failedIndicator!, bubbleArea],
          );
        }

        final row = Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (showLeftSlot) slot(leftSlot),
            Flexible(
              child: Padding(
                padding: EdgeInsets.only(top: bubbleTop),
                child: Align(
                  alignment: isMe ? Alignment.topRight : Alignment.topLeft,
                  child: bubbleArea,
                ),
              ),
            ),
            if (showRightSlot) slot(rightSlot),
          ],
        );
        return selectionWrapper?.call(row) ?? row;
      },
    );
  }
}

class _Avatar extends StatelessWidget {
  static const double kSize = 38.0;

  final String? avatarUrl;
  const _Avatar({required this.avatarUrl});
  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    // 头像仅 38px 显示，按目标像素降采样解码，避免原图（可达数百万像素）
    // 进 ImageCache 拖慢滚动。
    final avatarDecodeWidth = (kSize * MediaQuery.devicePixelRatioOf(context))
        .round();

    // 缺省、加载中和加载失败时保持空白头像。
    Widget buildFallback() => const SizedBox.expand();

    Widget buildImage(String url) {
      final trimmed = url.trim();
      // 解析对齐标记（如 #top），并获取清理后的路径和对齐方式
      final alignment = trimmed.contains('#top')
          ? Alignment.topCenter
          : Alignment.center;
      final cleanUrl = trimmed.split('#').first;
      final isNetwork =
          cleanUrl.startsWith('http://') || cleanUrl.startsWith('https://');
      final isAsset =
          cleanUrl.startsWith('assets/') || cleanUrl.startsWith('packages/');
      final isLocalFile = _looksLikeLocalFilePath(cleanUrl);

      if (isLocalFile) {
        return Image.file(
          File(_normalizeLocalFilePath(cleanUrl)),
          fit: BoxFit.cover,
          alignment: alignment,
          cacheWidth: avatarDecodeWidth,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => buildFallback(),
        );
      }

      final dataBytes = decodeInlineBase64Image(cleanUrl);
      if (dataBytes != null) {
        return Image(
          image: ResizeImage.resizeIfNeeded(
            avatarDecodeWidth,
            null,
            _MemoryImageProviderCache.fromBytes(dataBytes),
          ),
          fit: BoxFit.cover,
          alignment: alignment,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => buildFallback(),
        );
      }
      if (!isNetwork &&
          !isLocalFile &&
          (isAsset || !cleanUrl.contains('://'))) {
        return Image.asset(
          cleanUrl,
          fit: BoxFit.cover,
          alignment: alignment,
          cacheWidth: avatarDecodeWidth,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => buildFallback(),
        );
      }
      // 网络图片使用 CachedNetworkImage 磁盘缓存
      return CachedNetworkImage(
        imageUrl: cleanUrl,
        fit: BoxFit.cover,
        alignment: alignment,
        memCacheWidth: avatarDecodeWidth,
        fadeInDuration: Duration.zero,
        fadeOutDuration: Duration.zero,
        placeholder: (context, url) => buildFallback(),
        errorWidget: (context, url, error) => buildFallback(),
      );
    }

    final trimmedUrl = avatarUrl?.trim();
    return Container(
      width: kSize,
      height: kSize,
      margin: const EdgeInsets.only(right: 0, top: 0),
      child: MoeG2ClipRRect(
        radius: context.skin.bubbleRadius,
        child: Container(
          color: colors.surfaceAlt,
          child: trimmedUrl != null && trimmedUrl.isNotEmpty
              ? buildImage(trimmedUrl)
              : buildFallback(),
        ),
      ),
    );
  }
}

bool _looksLikeLocalFilePath(String path) {
  if (path.isEmpty) return false;
  if (path.startsWith('/')) return true;
  if (path.startsWith(r'\')) return true;
  if (path.startsWith('file://')) return true;
  if (RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path)) return true;
  return path.contains(r'\');
}

String _normalizeLocalFilePath(String path) {
  if (path.startsWith('file://')) {
    return Uri.parse(path).toFilePath();
  }
  return path;
}

class _MemoryImageProviderCache {
  _MemoryImageProviderCache._();

  static const int _maxEntries = 48;
  static final LinkedHashMap<Uint8List, MemoryImage> _entries =
      LinkedHashMap<Uint8List, MemoryImage>.identity();

  static MemoryImage fromBytes(Uint8List bytes) {
    final cached = _entries.remove(bytes);
    if (cached != null) {
      _entries[bytes] = cached;
      return cached;
    }

    final provider = MemoryImage(bytes);
    _entries[bytes] = provider;
    while (_entries.length > _maxEntries) {
      _entries.remove(_entries.keys.first);
    }
    return provider;
  }
}

/// Momotalk 风格三点闪动输入指示器
///
/// 三个圆点从左到右依次缩放+透明度变化，模拟"对方正在输入"效果。
/// 用于 AI 生成中的占位消息气泡内。
class TypingDotsIndicator extends StatefulWidget {
  /// 圆点颜色
  final Color color;

  /// 单个圆点直径
  final double dotSize;

  /// 圆点间距
  final double spacing;

  /// 组件高度（与文字行高一致，确保气泡大小正常）
  final double? height;

  const TypingDotsIndicator({
    super.key,
    required this.color,
    this.dotSize = 6.0,
    this.spacing = 4.0,
    this.height,
  });

  @override
  State<TypingDotsIndicator> createState() => _TypingDotsIndicatorState();
}

class _TypingDotsIndicatorState extends State<TypingDotsIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final effectiveHeight = widget.height ?? widget.dotSize * 1.6;
    return RepaintBoundary(
      child: SizedBox(
        height: effectiveHeight,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: List.generate(3, (index) {
            return Padding(
              padding: EdgeInsets.only(right: index < 2 ? widget.spacing : 0),
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, child) {
                  // 每个点在周期中有不同的相位偏移（0.0, 0.2, 0.4）
                  final offset = index * 0.2;
                  final t = (_controller.value - offset) % 1.0;
                  // 活跃区间 [0, 0.4]，其余时间静止
                  final active = t < 0.4;
                  // 只使用透明度变化实现从左到右闪动，不缩放
                  final opacity = active
                      ? 0.4 + 0.6 * math.sin(t / 0.4 * math.pi)
                      : 0.4;
                  return DecoratedBox(
                    decoration: BoxDecoration(
                      color: widget.color.withValues(
                        alpha: (widget.color.a * opacity).clamp(0.0, 1.0),
                      ),
                      shape: BoxShape.circle,
                    ),
                    child: child,
                  );
                },
                child: SizedBox(width: widget.dotSize, height: widget.dotSize),
              ),
            );
          }),
        ),
      ),
    );
  }
}
