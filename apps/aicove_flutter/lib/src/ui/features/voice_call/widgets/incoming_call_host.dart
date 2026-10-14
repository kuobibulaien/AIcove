import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/auto_reply/data/incoming_call.dart';
import '../../../../features/chat/domain/conversation.dart';
import '../../../../features/settings/app_settings.dart';
import '../../../../features/voice_call/application/active_voice_call.dart';
import '../../../shared/widgets/index.dart';
import '../../chat/widgets/chat_wallpaper_background.dart';
import '../pages/voice_call_page.dart';

const _acceptGreen = Color(0xFF30A46C);

/// Shows the incoming-call screen above every page while a proactive call
/// rings (plan 12, §4.8). [onAccepted] opens the call page.
class IncomingCallHost extends ConsumerWidget {
  const IncomingCallHost({
    super.key,
    required this.child,
    required this.onAccepted,
  });

  final Widget child;
  final void Function(Conversation conversation, ActiveVoiceCall call)
  onAccepted;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final incoming = ref.watch(incomingCallProvider);
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        if (incoming != null)
          IncomingCallScreen(
            // Answering from the notification while the same call rings in
            // the app swaps in a fresh screen that connects right away.
            key: ValueKey(
              'incoming-call-${incoming.triggerId}-${incoming.answered}',
            ),
            conversation: incoming.conversation,
            answered: incoming.answered,
            onAccept: () async {
              final call = await ref
                  .read(incomingCallProvider.notifier)
                  .accept();
              if (call != null) onAccepted(incoming.conversation, call);
            },
            onDecline: () =>
                unawaited(ref.read(incomingCallProvider.notifier).decline()),
          ),
      ],
    );
  }
}

/// Full-screen ringing view in the style of the call page: the role's chat
/// background under a dark veil, a pulsing avatar, decline and accept.
class IncomingCallScreen extends ConsumerStatefulWidget {
  const IncomingCallScreen({
    super.key,
    required this.conversation,
    required this.onAccept,
    required this.onDecline,
    this.answered = false,
  });

  final Conversation conversation;

  /// Answered from the notification already: connect without ringing.
  final bool answered;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  @override
  ConsumerState<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends ConsumerState<IncomingCallScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..repeat();
  Timer? _ring;
  bool _answered = false;

  @override
  void initState() {
    super.initState();
    if (widget.answered) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _answer(widget.onAccept),
      );
      return;
    }
    _buzz();
    _ring = Timer.periodic(const Duration(seconds: 2), (_) => _buzz());
  }

  /// No ringtone asset ships with the app: vibrate on phones and play the
  /// system alert on desktop.
  void _buzz() {
    unawaited(HapticFeedback.vibrate());
    unawaited(SystemSound.play(SystemSoundType.alert));
  }

  void _answer(VoidCallback action) {
    if (_answered) return;
    _answered = true;
    _ring?.cancel();
    action();
  }

  @override
  void dispose() {
    _ring?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final conv = widget.conversation;
    final fallback = resolveChatBackgroundColor(
      context,
      ref.watch(appSettingsProvider).valueOrNull?.lightChatBackground,
    );
    return Material(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ChatWallpaperLayer(
            image: conv.chatBackgroundImage,
            fallbackColor: fallback,
            style: chatWallpaperStyleOf(conv).copyWith(mask: 0),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  for (final alpha in const [0.5, 0.38, 0.66])
                    Colors.black.withValues(alpha: alpha),
                ],
              ),
            ),
          ),
          SafeArea(
            child: LayoutBuilder(
              builder: (context, box) {
                final avatar = math.min(140.0, box.maxHeight * 0.2);
                return Column(
                  children: [
                    SizedBox(height: box.maxHeight * 0.12),
                    VoiceCallPulsingAvatar(
                      animation: _pulse,
                      size: avatar,
                      child: MoeAvatar(
                        name: conv.displayName,
                        avatarUrl: conv.avatarUrl,
                        characterImage: conv.characterImage,
                        size: avatar,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Text(
                        conv.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '邀请你语音通话…',
                      key: const ValueKey('incoming-call-status'),
                      style: TextStyle(
                        fontSize: 16,
                        color: Colors.white.withValues(alpha: 0.85),
                      ),
                    ),
                    const Spacer(),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 36),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          VoiceCallRoundButton(
                            key: const ValueKey('incoming-call-decline'),
                            icon: Icons.call_end_rounded,
                            label: '拒绝',
                            color: voiceCallHangUpRed,
                            onTap: () => _answer(widget.onDecline),
                          ),
                          VoiceCallRoundButton(
                            key: const ValueKey('incoming-call-accept'),
                            icon: Icons.call_rounded,
                            label: '接听',
                            color: _acceptGreen,
                            onTap: () => _answer(widget.onAccept),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
