import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/models/message_block.dart';
import '../../../../features/chat/conversation_providers.dart';
import '../../../../features/chat/domain/message.dart';
import '../../../../features/chat/presentation/widgets/message_bubble.dart';
import '../../../../features/voice_call/domain/call_record_port.dart';
import '../../../../features/voice_call/domain/voice_call_ports.dart';
import '../../../../features/voice_call/providers/voice_call_providers.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';

final _legacyCallRecordProvider = FutureProvider.autoDispose
    .family<CallRecord?, String>(
      (ref, callId) => ref.watch(callRecordStoreProvider).load(callId),
    );

/// 一通电话的逐句记录（只读）。记录跟着通话气泡同步；2026-10-12 之前的通话
/// 气泡里没有记录，回退到通话那台设备的旧表。
class CallTranscriptPage extends ConsumerWidget {
  const CallTranscriptPage({super.key, required this.record});

  final CallRecordBlock record;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.moeColors;
    final legacy = record.turns.isEmpty
        ? ref.watch(_legacyCallRecordProvider(record.callId))
        : null;
    return MoePageScaffold(
      extendBodyBehindAppBar: true,
      appBar: MoeAppBar(
        title: '语音通话 · ${formatCallDuration(record.duration)}',
        showBackButton: true,
      ),
      body: Builder(
        builder: (context) {
          if (legacy == null) return _Transcript(turns: record.turns);
          return legacy.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) =>
                _Notice(text: '通话记录读取失败：$e', color: colors.muted),
            data: (old) => old == null
                ? _Notice(
                    text: '这通电话早于记录同步，逐句记录只保存在通话的那台设备上',
                    color: colors.muted,
                  )
                : _Transcript(turns: old.turns),
          );
        },
      ),
    );
  }
}

class _Transcript extends ConsumerWidget {
  const _Transcript({required this.turns});

  final List<CallTurn> turns;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (turns.isEmpty) {
      return _Notice(text: '这通电话里没有人说话', color: context.moeColors.muted);
    }
    // 通话气泡只出现在这个角色的聊天里，名字和头像取当前聊天的角色。
    final conv = ref.watch(activeConversationProvider);
    final name = conv?.displayName ?? '对方';
    final avatar = conv?.avatarUrl ?? conv?.characterImage;
    return ListView.builder(
      padding: moeUnderBarPadding(
        context,
        const EdgeInsets.symmetric(vertical: 16),
      ),
      itemCount: turns.length,
      itemBuilder: (context, index) {
        final turn = turns[index];
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: MessageBubble(
            isMe: turn.isUser,
            displayName: turn.isUser ? '我' : name,
            avatarUrl: turn.isUser ? null : avatar,
            message: Message(
              id: 'call_turn_$index',
              role: turn.role,
              content: turn.interrupted
                  ? '${turn.spokenText}……（被打断）'
                  : turn.spokenText,
              createdAt: DateTime.fromMillisecondsSinceEpoch(0),
            ),
          ),
        );
      },
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.text, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(color: color),
      ),
    ),
  );
}
