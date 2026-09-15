import 'dart:async';

import 'package:flutter/material.dart';

import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';
import 'chat_message_selection.dart';

/// Dragging starts in the check column; the bubble area keeps native scrolling.
class ChatSelectionRegion extends StatefulWidget {
  const ChatSelectionRegion({
    super.key,
    required this.selection,
    required this.scrollController,
    required this.topInset,
    required this.bottomInset,
    required this.child,
  });

  final ChatMessageSelection? selection;
  final ScrollController scrollController;
  final double topInset;
  final double bottomInset;
  final Widget child;

  @override
  State<ChatSelectionRegion> createState() => _ChatSelectionRegionState();
}

class _ChatSelectionRegionState extends State<ChatSelectionRegion> {
  final _rows = <String, BuildContext>{};
  Timer? _scrollTimer;
  Offset? _pointer;

  void _start(String id, Offset position) {
    _pointer = position;
    widget.selection?.beginDrag(id);
    _scrollTimer?.cancel();
    _scrollTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      final pointer = _pointer;
      final box = context.findRenderObject() as RenderBox?;
      if (pointer == null || box == null || !box.hasSize) return;
      final local = box.globalToLocal(pointer);
      final top = widget.topInset;
      final bottom = box.size.height - widget.bottomInset;
      const edge = 56.0;
      final double velocity;
      if (local.dy < top + edge) {
        velocity = -((top + edge - local.dy) / edge).clamp(0.0, 1.0) * 12;
      } else if (local.dy > bottom - edge) {
        velocity = ((local.dy - bottom + edge) / edge).clamp(0.0, 1.0) * 12;
      } else {
        velocity = 0;
      }
      final controller = widget.scrollController;
      if (velocity != 0 && controller.hasClients) {
        final position = controller.position;
        final reverse = position.axisDirection == AxisDirection.up;
        final next = (position.pixels + (reverse ? -velocity : velocity)).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        );
        if (next != position.pixels) position.jumpTo(next);
      }
      // Geometry changes after layout, including newly paged history rows.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _pointer != null) _selectAt(_pointer!);
      });
    });
  }

  void _selectAt(Offset position) {
    _pointer = position;
    final viewport = context.findRenderObject() as RenderBox?;
    if (viewport == null || !viewport.hasSize) return;
    final origin = viewport.localToGlobal(Offset.zero);
    final top = origin.dy + widget.topInset;
    final bottom = origin.dy + viewport.size.height - widget.bottomInset;
    if (bottom <= top) return;
    final y = position.dy.clamp(top, bottom);
    String? closest;
    var distance = double.infinity;
    for (final entry in _rows.entries) {
      if (!entry.value.mounted ||
          widget.selection?.canSelect(entry.key) != true) {
        continue;
      }
      final box = entry.value.findRenderObject() as RenderBox?;
      if (box == null || !box.attached || !box.hasSize) continue;
      final rowTop = box.localToGlobal(Offset.zero).dy;
      final rowBottom = rowTop + box.size.height;
      if (rowBottom <= top || rowTop >= bottom) continue;
      final delta = y < rowTop
          ? rowTop - y
          : (y > rowBottom ? y - rowBottom : 0.0);
      if (delta < distance) {
        distance = delta;
        closest = entry.key;
      }
    }
    if (closest != null) widget.selection?.extendDrag(closest);
  }

  void _end() {
    _scrollTimer?.cancel();
    _scrollTimer = null;
    _pointer = null;
    widget.selection?.endDrag();
  }

  @override
  void didUpdateWidget(covariant ChatSelectionRegion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selection != widget.selection ||
        widget.selection?.active != true) {
      _end();
    }
  }

  @override
  void dispose() {
    _end();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _SelectionScope(state: this, child: widget.child);
}

class _SelectionScope extends InheritedWidget {
  const _SelectionScope({required this.state, required super.child});
  final _ChatSelectionRegionState state;

  @override
  bool updateShouldNotify(_SelectionScope oldWidget) => true;
}

class ChatSelectableMessage extends StatefulWidget {
  const ChatSelectableMessage({
    super.key,
    required this.messageId,
    required this.child,
  });

  final String messageId;
  final Widget child;

  @override
  State<ChatSelectableMessage> createState() => _ChatSelectableMessageState();
}

class _ChatSelectableMessageState extends State<ChatSelectableMessage> {
  _ChatSelectionRegionState? _region;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _region?._rows.remove(widget.messageId);
    _region = context
        .dependOnInheritedWidgetOfExactType<_SelectionScope>()
        ?.state;
    _region?._rows[widget.messageId] = context;
  }

  @override
  void dispose() {
    _region?._rows.remove(widget.messageId);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final region = _region;
    final selection = region?.widget.selection;
    if (region == null || selection == null || !selection.active) {
      return widget.child;
    }
    final enabled = selection.canSelect(widget.messageId);
    if (!enabled) return widget.child;
    final selected = selection.contains(widget.messageId);
    final colors = context.moeColors;
    return Semantics(
      selected: selected,
      enabled: enabled,
      child: ColoredBox(
        color: selected
            ? colors.primary.withValues(alpha: 0.10)
            : Colors.transparent,
        child: Stack(
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => selection.toggle(widget.messageId),
              onLongPressStart: (details) =>
                  region._start(widget.messageId, details.globalPosition),
              onLongPressMoveUpdate: (details) =>
                  region._selectAt(details.globalPosition),
              onLongPressEnd: (_) => region._end(),
              onLongPressCancel: region._end,
              child: IgnorePointer(child: widget.child),
            ),
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              child: GestureDetector(
                key: ValueKey('message-select-${widget.messageId}'),
                behavior: HitTestBehavior.opaque,
                onTap: () => selection.toggle(widget.messageId),
                onVerticalDragStart: (details) =>
                    region._start(widget.messageId, details.globalPosition),
                onVerticalDragUpdate: (details) =>
                    region._selectAt(details.globalPosition),
                onVerticalDragEnd: (_) => region._end(),
                onVerticalDragCancel: region._end,
                child: SizedBox(
                  width: 42,
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: SizedBox(
                      height: 42,
                      child: IgnorePointer(
                        child: MoeCheckbox(
                          value: selected,
                          enabled: enabled,
                          enableHaptics: false,
                          onChanged: (_) {},
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
