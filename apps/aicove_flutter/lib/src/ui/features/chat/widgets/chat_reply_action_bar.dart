import 'package:flutter/material.dart';

/// The row of quiet actions under an assistant reply in document mode.
/// It stays dim and, where a mouse can hover, fades in only for the latest
/// reply or the one under the pointer; touch screens always show it.
class ChatReplyActionBar extends StatefulWidget {
  const ChatReplyActionBar({
    super.key,
    required this.timeLabel,
    required this.color,
    required this.visible,
    this.enabled = true,
    required this.onCopy,
    required this.onQuote,
    this.onRetry,
  });

  final String timeLabel;
  final Color color;

  /// Whether the reply is the latest one or being hovered.
  final bool visible;

  /// False while the reply is still generating: the row keeps its space but
  /// never shows.
  final bool enabled;
  final VoidCallback onCopy;
  final VoidCallback onQuote;

  /// Null hides the retry button (e.g. a character greeting).
  final VoidCallback? onRetry;

  @override
  State<ChatReplyActionBar> createState() => _ChatReplyActionBarState();
}

class _ChatReplyActionBarState extends State<ChatReplyActionBar> {
  bool _hovered = false;

  bool get _alwaysShown => switch (Theme.of(context).platform) {
    TargetPlatform.android || TargetPlatform.iOS => true,
    _ => false,
  };

  @override
  Widget build(BuildContext context) {
    final shown =
        widget.enabled && (widget.visible || _hovered || _alwaysShown);
    final color = widget.color.withValues(alpha: 0.7);
    Widget button(IconData icon, String label, VoidCallback onTap) => Tooltip(
      message: label,
      child: InkResponse(
        onTap: onTap,
        radius: 16,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(icon, size: 16, color: color, semanticLabel: label),
        ),
      ),
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedOpacity(
        opacity: shown ? 1 : 0,
        duration: const Duration(milliseconds: 150),
        child: IgnorePointer(
          ignoring: !shown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              button(Icons.copy_rounded, '复制', widget.onCopy),
              button(Icons.format_quote_rounded, '引用', widget.onQuote),
              if (widget.onRetry != null)
                button(Icons.refresh_rounded, '重试', widget.onRetry!),
              const SizedBox(width: 6),
              Text(
                widget.timeLabel,
                style: TextStyle(color: color, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// `刚刚` / `8分钟前` / `3小时前` within a day, otherwise [fallback].
String chatReplyTimeLabel(
  DateTime time,
  DateTime now,
  String Function(DateTime) fallback,
) {
  final gap = now.difference(time);
  if (gap.isNegative || gap.inMinutes < 1) return '刚刚';
  if (gap.inHours < 1) return '${gap.inMinutes}分钟前';
  if (gap.inDays < 1) return '${gap.inHours}小时前';
  return fallback(time);
}
