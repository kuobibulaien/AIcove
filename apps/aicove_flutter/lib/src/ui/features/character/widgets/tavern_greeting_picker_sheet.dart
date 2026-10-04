import 'package:flutter/material.dart';

import '../../../shared/effects/smooth_clip.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';

/// 卡片收起时的预览行数；超出后提供「展开全文」。
const int _kPreviewLines = 6;

/// 角色卡有多套开场白时让用户选一套；返回所选下标，关闭弹窗返回 null。
Future<int?> showTavernGreetingPicker(
  BuildContext context, {
  required List<String> greetings,
  int? selectedIndex,
}) {
  return showMoeBottomSheet<int>(
    context: context,
    title: '选择开场白',
    builder: (sheetContext) => TavernGreetingPickerList(
      greetings: greetings,
      selectedIndex: selectedIndex,
      onSelected: (index) => Navigator.of(sheetContext).pop(index),
    ),
  );
}

class TavernGreetingPickerList extends StatelessWidget {
  const TavernGreetingPickerList({
    super.key,
    required this.greetings,
    required this.onSelected,
    this.selectedIndex,
  });

  final List<String> greetings;
  final int? selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    return ListView.separated(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      itemCount: greetings.length + 1,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, i) {
        if (i == 0) {
          return Text(
            '这张角色卡有 ${greetings.length} 套开场白，选中的一套会作为角色的第一条消息出现在聊天里。',
            style: TextStyle(fontSize: 13, color: colors.muted),
          );
        }
        final index = i - 1;
        return _GreetingCard(
          index: index,
          text: greetings[index],
          selected: index == selectedIndex,
          onSelected: () => onSelected(index),
        );
      },
    );
  }
}

class _GreetingCard extends StatefulWidget {
  const _GreetingCard({
    required this.index,
    required this.text,
    required this.selected,
    required this.onSelected,
  });

  final int index;
  final String text;
  final bool selected;
  final VoidCallback onSelected;

  @override
  State<_GreetingCard> createState() => _GreetingCardState();
}

class _GreetingCardState extends State<_GreetingCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final selected = widget.selected;
    final bodyStyle = TextStyle(
      fontSize: 13,
      height: 1.45,
      color: colors.textSecondary,
    );
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: widget.onSelected,
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
          decoration: MoeG2Decoration(
            radius: 14,
            color: selected
                ? colors.primary.withValues(alpha: 0.10)
                : colors.surfaceAlt,
            border: Border.all(
              color: selected
                  ? colors.primary
                  : colors.border.withValues(alpha: 0.25),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.index == 0
                          ? '开场白 1（主开场白）'
                          : '开场白 ${widget.index + 1}',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: selected ? colors.primary : colors.text,
                      ),
                    ),
                  ),
                  Text(
                    '${widget.text.length} 字',
                    style: TextStyle(fontSize: 12, color: colors.muted),
                  ),
                  if (selected) ...[
                    const SizedBox(width: 6),
                    Icon(Icons.check_circle, size: 18, color: colors.primary),
                  ],
                ],
              ),
              const SizedBox(height: 6),
              LayoutBuilder(
                builder: (context, constraints) {
                  final overflows = _overflows(context, bodyStyle, constraints);
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.text,
                        maxLines: _expanded ? null : _kPreviewLines,
                        overflow: _expanded ? null : TextOverflow.ellipsis,
                        style: bodyStyle,
                      ),
                      if (overflows)
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton(
                            style: TextButton.styleFrom(
                              foregroundColor: colors.primary,
                            ),
                            onPressed: () =>
                                setState(() => _expanded = !_expanded),
                            child: Text(_expanded ? '收起' : '展开全文'),
                          ),
                        )
                      else
                        const SizedBox(height: 8),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool _overflows(
    BuildContext context,
    TextStyle style,
    BoxConstraints constraints,
  ) {
    final painter = TextPainter(
      text: TextSpan(text: widget.text, style: style),
      maxLines: _kPreviewLines,
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout(maxWidth: constraints.maxWidth);
    final result = painter.didExceedMaxLines;
    painter.dispose();
    return result;
  }
}
