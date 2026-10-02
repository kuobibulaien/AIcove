import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../features/chat/chat_providers.dart';
import '../../../../features/dialogue_options/application/dialogue_options_providers.dart';
import '../../../../features/dialogue_options/domain/dialogue_options.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';

/// 对话选项气泡（ADR0045）。只在最新一轮回复带选项、且尚未选用时出现；
/// 模型答完自动展开一次，关闭后收拢为气泡，选用后消失。
class DialogueOptionsBadge extends ConsumerStatefulWidget {
  const DialogueOptionsBadge({
    super.key,
    required this.conversationId,
    required this.options,
    required this.size,
  });
  final String conversationId;
  final DialogueOptions? options;
  final double size;

  @override
  ConsumerState<DialogueOptionsBadge> createState() =>
      _DialogueOptionsBadgeState();
}

class _DialogueOptionsBadgeState extends ConsumerState<DialogueOptionsBadge> {
  final _anchorKey = GlobalKey();
  bool _open = false;

  /// 本会话里有一轮生成结束、还没为它自动展开过。
  bool _awaitingReply = false;
  String? _signatureAtSendStart;

  bool _isVisible(DialogueOptions? options) =>
      options != null &&
      !ref.read(conversationSendingProvider(widget.conversationId)) &&
      ref.read(dialogueOptionsConsumedProvider(widget.conversationId)) !=
          options.signature;

  void _maybeAutoOpen(DialogueOptions? options) {
    if (!_awaitingReply || !_isVisible(options)) return;
    if (options!.signature == _signatureAtSendStart) return;
    _awaitingReply = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _show();
    });
  }

  Future<void> _show() async {
    final options = widget.options;
    if (_open || !_isVisible(options)) return;
    final box = _anchorKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached) return;
    _open = true;
    try {
      await MoePopupMenu.show(
        context,
        targetBox: box,
        alignToEnd: true,
        // 选项多是整句，按内容放宽；手机上最多铺满安全区。
        maxWidth: 360,
        items: [
          for (var index = 0; index < options!.items.length; index++)
            MoePopupMenuItem(
              key: ValueKey('dialogue_option_$index'),
              label: options.items[index],
              onTap: () => _select(options, options.items[index]),
            ),
        ],
      );
    } finally {
      _open = false;
    }
  }

  void _select(DialogueOptions options, String text) {
    if (widget.options?.signature != options.signature) return;
    ref.read(dialogueOptionPickProvider(widget.conversationId).notifier).state =
        DialogueOptionPick(text: text, signature: options.signature);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(conversationSendingProvider(widget.conversationId), (
      previous,
      sending,
    ) {
      if (sending && previous != true) {
        _awaitingReply = true;
        _signatureAtSendStart = widget.options?.signature;
      }
    });
    final sending = ref.watch(conversationSendingProvider(widget.conversationId));
    final consumed = ref.watch(
      dialogueOptionsConsumedProvider(widget.conversationId),
    );
    final options = widget.options;
    if (sending || options == null || options.signature == consumed) {
      return const SizedBox.shrink();
    }
    _maybeAutoOpen(options);
    return SizedBox(
      key: _anchorKey,
      width: widget.size,
      height: widget.size,
      child: MoeIconButton(
        key: const ValueKey('dialogue_options_badge'),
        icon: Icons.auto_awesome_outlined,
        semanticLabel: '对话选项',
        size: 22,
        padding: EdgeInsets.all((widget.size - 22) / 2),
        minTouchTarget: widget.size,
        borderRadius: BorderRadius.circular(widget.size / 2),
        color: context.moeColors.accentColor,
        onTap: _show,
      ),
    );
  }
}
