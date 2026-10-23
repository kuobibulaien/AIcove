import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/models/block_status.dart';
import '../../../../core/models/message_block.dart';
import '../../../../features/chat/domain/message.dart';
import '../../../../features/chat/presentation/widgets/audio_player_widget.dart';
import '../../../../features/chat/services/chat_history_store.dart';
import '../../../shared/widgets/buttons/moe_icon_button.dart';
import '../../../shared/widgets/buttons/moe_primary_button.dart';
import '../../../shared/widgets/moe_floating_surface.dart';
import '../../../theme/tokens.dart';

/// 连续点播判定：相邻两次开播间隔不超过 [maxGap] 的不同语音才算连续。
class VoiceTapStreak {
  VoiceTapStreak({
    this.threshold = 3,
    this.maxGap = const Duration(minutes: 2),
  });

  final int threshold;
  final Duration maxGap;
  final List<String> _urls = <String>[];
  DateTime? _lastAt;

  /// 记一次点播；凑满 [threshold] 条不同语音时返回 true 并清零。
  bool add(String url, DateTime at) {
    final last = _lastAt;
    if (last == null || at.difference(last) > maxGap) _urls.clear();
    _lastAt = at;
    _urls
      ..remove(url)
      ..add(url);
    if (_urls.length < threshold) return false;
    clear();
    return true;
  }

  void clear() {
    _urls.clear();
    _lastAt = null;
  }
}

/// 按时间线顺序列出还没听过的语音地址。
List<String> unreadVoiceUrls(List<Message> messages, Set<String> heard) => [
      for (final message in messages)
        for (final block in message.blocks ?? const <MessageBlock>[])
          if (block is AudioBlock &&
              block.unread &&
              block.status == BlockStatus.success &&
              block.url.isNotEmpty &&
              !heard.contains(block.url))
            block.url,
    ];

/// 连续点播三条语音后，在右下角提议把剩下的未读语音按顺序播完。
/// 也负责把播放过的语音记为已读。
class VoiceAutoplayPrompt extends ConsumerStatefulWidget {
  const VoiceAutoplayPrompt({
    super.key,
    required this.conversationId,
    required this.messages,
  });

  final String conversationId;
  final List<Message> messages;

  @override
  ConsumerState<VoiceAutoplayPrompt> createState() =>
      _VoiceAutoplayPromptState();
}

class _VoiceAutoplayPromptState extends ConsumerState<VoiceAutoplayPrompt> {
  static const Duration _visibleFor = Duration(seconds: 10);

  late final AudioPlaybackCoordinator _coordinator;
  StreamSubscription<String>? _starts;
  final VoiceTapStreak _streak = VoiceTapStreak();
  final Set<String> _marking = <String>{};
  Timer? _hideTimer;
  bool _offered = false;
  bool _visible = false;
  bool _autoplaying = false;
  String? _autoUrl;

  @override
  void initState() {
    super.initState();
    _coordinator = ref.read(audioPlaybackCoordinatorProvider);
    _starts = _coordinator.playStarts.listen(_onPlayStarted);
    _scheduleMarkHeard();
  }

  @override
  void didUpdateWidget(covariant VoiceAutoplayPrompt oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.conversationId != widget.conversationId) {
      _autoplaying = false;
      _autoUrl = null;
      _offered = false;
      _streak.clear();
      _hide();
    }
    _scheduleMarkHeard();
  }

  @override
  void dispose() {
    _autoplaying = false;
    _hideTimer?.cancel();
    unawaited(_starts?.cancel());
    super.dispose();
  }

  bool _isHere(String url) => widget.messages.any(
        (m) => m.blocks?.any((b) => b is AudioBlock && b.url == url) ?? false,
      );

  void _onPlayStarted(String url) {
    if (!mounted || !_isHere(url)) return;
    unawaited(_markRead({url}));
    if (_autoplaying) {
      // 用户自己点了别的语音，连播让位。
      if (url != _autoUrl) _autoplaying = false;
      return;
    }
    if (_offered || !_streak.add(url, DateTime.now())) return;
    if (unreadVoiceUrls(widget.messages, _coordinator.heardUrls).isEmpty) {
      return;
    }
    _offered = true;
    _hideTimer?.cancel();
    _hideTimer = Timer(_visibleFor, _hide);
    setState(() => _visible = true);
  }

  void _hide() {
    _hideTimer?.cancel();
    _hideTimer = null;
    if (mounted && _visible) setState(() => _visible = false);
  }

  /// 回复落库晚于播放时，已听过的语音会带着未读标记出现，这里补记。
  void _scheduleMarkHeard() {
    final heard = {
      for (final message in widget.messages)
        for (final block in message.blocks ?? const <MessageBlock>[])
          if (block is AudioBlock &&
              block.unread &&
              _coordinator.heardUrls.contains(block.url))
            block.url,
    };
    if (heard.isEmpty) return;
    unawaited(Future<void>(() => _markRead(heard)));
  }

  Future<void> _markRead(Set<String> urls) async {
    final conversationId = widget.conversationId;
    for (final message in widget.messages) {
      final blocks = message.blocks;
      if (blocks == null) continue;
      final hits = {
        for (final block in blocks)
          if (block is AudioBlock &&
              block.unread &&
              urls.contains(block.url) &&
              !_marking.contains(block.url))
            block.url,
      };
      if (hits.isEmpty) continue;
      _marking.addAll(hits);
      try {
        await ref.read(chatHistoryStoreProvider).updateMessage(
              conversationId: conversationId,
              message: message.copyWith(blocks: [
                for (final block in blocks)
                  if (block is AudioBlock && hits.contains(block.url))
                    block.withUnread(false)
                  else
                    block,
              ]),
            );
      } finally {
        _marking.removeAll(hits);
      }
    }
  }

  Future<void> _playRemaining() async {
    _hide();
    _autoplaying = true;
    final current = _coordinator.activeController;
    if (current != null && !await current.playToEnd()) {
      _autoplaying = false;
      return;
    }
    while (mounted && _autoplaying) {
      final next =
          unreadVoiceUrls(widget.messages, _coordinator.heardUrls).firstOrNull;
      if (next == null) break;
      _autoUrl = next;
      final subscription = ref.listenManual(
        audioPlayerControllerProvider(next).notifier,
        (_, _) {},
      );
      try {
        if (!await subscription.read().playToEnd()) break;
      } finally {
        subscription.close();
      }
    }
    _autoplaying = false;
    _autoUrl = null;
  }

  @override
  Widget build(BuildContext context) {
    final remaining = _visible
        ? unreadVoiceUrls(widget.messages, _coordinator.heardUrls).length
        : 0;
    return AnimatedSwitcher(
      duration: kAnim,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.3),
            end: Offset.zero,
          ).animate(animation),
          child: child,
        ),
      ),
      child: remaining == 0
          ? const SizedBox.shrink()
          : _buildBubble(context, remaining),
    );
  }

  Widget _buildBubble(BuildContext context, int remaining) {
    final colors = context.moeColors;
    return MoeFloatingSurface(
      key: const ValueKey('voice-autoplay-prompt'),
      radius: 20,
      padding: const EdgeInsets.fromLTRB(14, 6, 4, 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.graphic_eq_rounded, size: 18, color: context.moeAccentInk),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              '自动播放剩下的 $remaining 条语音？',
              style: TextStyle(color: colors.text, fontSize: 14),
            ),
          ),
          const SizedBox(width: 10),
          MoePrimaryButton(
            label: '播放',
            size: MoePrimaryButtonSize.sm,
            onPressed: () => unawaited(_playRemaining()),
          ),
          MoeIconButton(
            icon: Icons.close_rounded,
            size: 18,
            semanticLabel: '关闭',
            onTap: _hide,
          ),
        ],
      ),
    );
  }
}
