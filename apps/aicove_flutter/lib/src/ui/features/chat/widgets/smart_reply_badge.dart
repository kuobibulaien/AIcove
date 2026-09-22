import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../features/settings/app_settings.dart';
import '../../../../features/chat/chat_providers.dart';
import '../../../../features/smart_reply/application/smart_reply_controller.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';

class SmartReplyBadge extends ConsumerStatefulWidget {
  const SmartReplyBadge({
    super.key,
    required this.conversationId,
    required this.size,
  });
  final String conversationId;
  final double size;

  @override
  ConsumerState<SmartReplyBadge> createState() => _SmartReplyBadgeState();
}

class _SmartReplyBadgeState extends ConsumerState<SmartReplyBadge> {
  final _anchorKey = GlobalKey();
  bool _loading = false;
  bool _open = false;

  bool _canUse(String modelRef) {
    final settings = ref.read(appSettingsProvider).valueOrNull;
    return settings?.smartReplyEnabled == true &&
        settings?.smartReplyModel == modelRef &&
        !ref.read(conversationSendingProvider(widget.conversationId));
  }

  Future<void> _showReplies() async {
    if (_open) return;
    final settings = ref.read(appSettingsProvider).valueOrNull;
    if (settings?.smartReplyEnabled != true) return;
    if (ref.read(conversationSendingProvider(widget.conversationId))) {
      MoeToast.brief(context, '等对方回复完成后再试');
      return;
    }
    final modelRef = settings!.smartReplyModel;
    if (modelRef.isEmpty) {
      MoeToast.brief(context, '请先在通用设置中选择辅助模型');
      return;
    }
    _open = true;
    setState(() => _loading = true);
    try {
      final replies = await ref
          .read(smartReplyControllerProvider(widget.conversationId))
          .load(modelRef);
      if (!mounted) return;
      setState(() => _loading = false);
      if (!_canUse(modelRef)) return;
      final box = _anchorKey.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached) return;
      await MoePopupMenu.show(
        context,
        targetBox: box,
        alignToEnd: true,
        items: [
          for (var index = 0; index < replies.length; index++)
            MoePopupMenuItem(
              key: ValueKey('smart_reply_candidate_$index'),
              label: replies[index],
              onTap: () => _select(replies[index], modelRef),
            ),
        ],
      );
    } catch (error) {
      if (mounted) {
        MoeToast.error(
          context,
          error is FormatException ? error.message : '生成失败，请检查辅助模型后再次点击重试',
        );
      }
    } finally {
      _open = false;
      if (mounted && _loading) setState(() => _loading = false);
    }
  }

  Future<void> _select(String text, String modelRef) async {
    try {
      final current = await ref
          .read(smartReplyControllerProvider(widget.conversationId))
          .isCurrent(modelRef);
      if (!mounted) return;
      if (!current || !_canUse(modelRef)) {
        MoeToast.brief(context, '对话或设置已更新，请重新打开辅助回答');
        return;
      }
      ref.read(smartReplyDraftProvider(widget.conversationId).notifier).state =
          text;
    } catch (_) {
      if (mounted) MoeToast.error(context, '无法使用此候选，请重试');
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(appSettingsProvider).valueOrNull;
    if (settings?.smartReplyEnabled != true) return const SizedBox.shrink();
    ref.watch(smartReplyControllerProvider(widget.conversationId));
    return SizedBox(
      key: _anchorKey,
      width: widget.size,
      height: widget.size,
      child: _loading
          ? const MoeFloatingSurface(
              radius: 999,
              child: Center(
                child: MoeLoadingIndicator(size: MoeLoadingSize.sm),
              ),
            )
          : MoeIconButton(
              key: const ValueKey('smart_reply_badge'),
              icon: Icons.auto_awesome_outlined,
              semanticLabel: '辅助回答',
              size: 22,
              padding: EdgeInsets.all((widget.size - 22) / 2),
              minTouchTarget: widget.size,
              borderRadius: BorderRadius.circular(widget.size / 2),
              color: context.moeColors.accentColor,
              onTap: _showReplies,
            ),
    );
  }
}
