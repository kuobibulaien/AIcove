import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/ui_blocks/application/ui_block_state_store.dart';
import '../../../../features/ui_blocks/domain/ui_block.dart';
import '../../../../features/ui_blocks/domain/ui_block_catalog.dart';
import '../../../../features/ui_blocks/domain/ui_state_context.dart';
import '../../effects/smooth_clip.dart';
import '../moe_code_block.dart';
import '../moe_toast.dart';
import 'moe_ui_block_scope.dart';
import 'ui_block_catalog_views.dart';
import 'ui_block_primitives.dart';
import 'ui_block_style.dart';

/// An `aicove-ui` fenced block rendered as an interactive component
/// (ADR0073 交互组件). Used by both chat styles: the document view's
/// Markdown code builder and the bubble's fenced-code parts.
///
/// While the fence is still open it shows a placeholder; a block that does
/// not parse falls back to its source, never breaking the message.
class MoeUiBlock extends ConsumerStatefulWidget {
  const MoeUiBlock({
    super.key,
    required this.code,
    required this.closed,
    this.foregroundColor,
    this.fontSize = 15,
  });

  final String code;
  final bool closed;
  final Color? foregroundColor;
  final double fontSize;

  static bool handles(String language) =>
      language.trim().toLowerCase() == kUiBlockFenceLanguage;

  @override
  ConsumerState<MoeUiBlock> createState() => _MoeUiBlockState();
}

class _MoeUiBlockState extends ConsumerState<MoeUiBlock> {
  UiBlock? _block;
  UiProgram? _program;
  String? _error;
  String? _parsedCode;

  /// Values the user set here, over what was stored.
  final Map<String, Object?> _local = {};

  void _parse() {
    if (_parsedCode == widget.code) return;
    _parsedCode = widget.code;
    _local.clear();
    final parsed = UiBlock.parse(widget.code);
    _block = parsed.block;
    _error = parsed.error;
    _program = null;
    final block = _block;
    if (block == null) return;
    final known = block.component == 'panel' ||
        kUiCatalogNames.contains(block.component) ||
        kUiPrimitives.contains(block.component);
    if (!known) {
      _block = null;
      _error = '不认识的组件「${block.component}」';
      return;
    }
    _program = UiProgram.compile(block);
  }

  ({String conversationId, String key})? _storage(MoeUiBlockScope? scope) {
    final messageId = MoeUiBlockMessage.maybeIdOf(context);
    final block = _block;
    if (scope == null || messageId == null || block == null) return null;
    return (
      conversationId: scope.conversationId,
      key: uiSavedBlockKey(messageId, block.key),
    );
  }

  @override
  Widget build(BuildContext context) {
    final style = UiBlockStyle.of(
      context,
      foregroundColor: widget.foregroundColor,
      fontSize: widget.fontSize,
    );
    if (!widget.closed) return _UiBlockPlaceholder(style: style);
    _parse();
    final block = _block;
    final program = _program;
    if (block == null || program == null) {
      return _UiBlockFallback(code: widget.code, reason: _error, style: style);
    }

    final scope = MoeUiBlockScope.maybeOf(context);
    final storage = _storage(scope);
    final saved = storage == null
        ? null
        : ref.watch(uiBlockStateProvider(storage.conversationId))[storage.key];
    void persist(Map<String, Object?> changes) {
      if (storage == null) return;
      ref
          .read(uiBlockStateProvider(storage.conversationId).notifier)
          .write(storage.key, changes, title: block.title);
    }

    final Widget body;
    if (kUiCatalogNames.contains(block.component)) {
      final node = program.resolve(const {});
      body = UiCatalogView(
        node: node,
        style: style,
        saved: saved?.state,
        onChanged: storage == null ? null : persist,
        ask: scope?.onAsk,
      );
    } else {
      final values = uiRestoreState(
        program.initialState,
        {...?saved?.state, ..._local},
      );
      final runtime = UiBlockRuntime(
        style: style,
        setValues: (changes) {
          setState(() => _local.addAll(changes));
          persist(uiStateDiff(program.initialState, {...values, ...changes}));
        },
        ask: scope?.onAsk,
        copy: (text) async {
          await Clipboard.setData(ClipboardData(text: text));
          if (context.mounted) MoeToast.brief(context, '已复制');
        },
      );
      body = buildUiNode(context, program.resolve(values), runtime, top: true);
    }
    return UiBlockFrame(style: style, child: body);
  }
}

/// The card every block sits in: a flat tint of the text color, so it reads
/// on bubbles and on the document page alike.
class UiBlockFrame extends StatelessWidget {
  const UiBlockFrame({super.key, required this.style, required this.child});

  final UiBlockStyle style;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: MoeG2Decoration(
        radius: 14,
        color: style.fg.withValues(alpha: 0.045),
        border: Border.all(color: style.fg.withValues(alpha: 0.08), width: 0.5),
      ),
      child: DefaultTextStyle.merge(style: style.body, child: child),
    );
  }
}

class _UiBlockPlaceholder extends StatelessWidget {
  const _UiBlockPlaceholder({required this.style});

  final UiBlockStyle style;

  @override
  Widget build(BuildContext context) {
    return UiBlockFrame(
      style: style,
      child: Row(
        children: [
          SizedBox.square(
            dimension: 14,
            child: CircularProgressIndicator(
              strokeWidth: 1.6,
              color: style.fg.withValues(alpha: 0.45),
            ),
          ),
          const SizedBox(width: 10),
          Text('正在生成交互组件…', style: style.caption),
        ],
      ),
    );
  }
}

class _UiBlockFallback extends StatefulWidget {
  const _UiBlockFallback({
    required this.code,
    required this.reason,
    required this.style,
  });

  final String code;
  final String? reason;
  final UiBlockStyle style;

  @override
  State<_UiBlockFallback> createState() => _UiBlockFallbackState();
}

class _UiBlockFallbackState extends State<_UiBlockFallback> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final style = widget.style;
    return UiBlockFrame(
      style: style,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: () => setState(() => _open = !_open),
            child: Row(
              children: [
                Icon(Icons.widgets_outlined, size: 16, color: style.muted),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.reason == null ? '组件没能显示' : '组件没能显示：${widget.reason}',
                    style: style.caption,
                  ),
                ),
                Text(_open ? '收起原文' : '查看原文',
                    style: style.caption.copyWith(color: style.accent)),
              ],
            ),
          ),
          if (_open)
            MoeCodeBlock(
              code: widget.code,
              language: 'json',
              foregroundColor: style.fg,
              fontSize: style.fontSize - 2,
            ),
        ],
      ),
    );
  }
}
