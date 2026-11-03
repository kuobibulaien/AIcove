import 'package:flutter/material.dart';

import '../../../../core/models/message_block.dart';
import '../../../shared/widgets/index.dart';
import '../pages/call_transcript_page.dart';
import 'voice_call_view.dart' show voiceCallHangUpRed;

/// 聊天页提供的回拨入口：没接通的通话气泡点一下就给这个角色打过去。
/// 导出图片、备份预览等地方没有它，气泡只显示不可点。
class CallBackScope extends InheritedWidget {
  const CallBackScope({
    super.key,
    required this.onCallBack,
    required super.child,
  });

  final VoidCallback onCallBack;

  static VoidCallback? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<CallBackScope>()?.onCallBack;

  @override
  bool updateShouldNotify(CallBackScope oldWidget) =>
      onCallBack != oldWidget.onCallBack;
}

/// 聊天里的通话气泡：电话图标＋“语音通话”＋时长，点开看逐句记录。
class CallRecordBubble extends StatelessWidget {
  const CallRecordBubble({
    super.key,
    required this.record,
    required this.textColor,
  });

  final CallRecordBlock record;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    final missed = record.missedCall;
    if (missed != null) return _missed(context, missed);
    final duration = formatCallDuration(record.duration);
    return Semantics(
      button: true,
      label: '语音通话，时长 $duration，点击查看通话记录',
      child: InkWell(
        key: ValueKey('call-record-${record.callId}'),
        onTap: () =>
            MoeWorkspace.open(context, CallTranscriptPage(record: record)),
        child: _layout(
          icon: Icons.call,
          iconColor: textColor,
          title: '语音通话',
          subtitle: duration,
        ),
      ),
    );
  }

  /// 没接通：没有记录可看；在聊天页里点一下回拨。
  Widget _missed(BuildContext context, MissedCall kind) {
    final callBack = CallBackScope.maybeOf(context);
    final incoming = kind == MissedCall.incoming;
    final title = switch (kind) {
      MissedCall.incoming => '未接来电',
      MissedCall.cancelled => '已取消',
      MissedCall.unanswered => '对方未接听',
    };
    final hint = incoming ? '点击回拨' : '点击重拨';
    final body = _layout(
      icon: switch (kind) {
        MissedCall.incoming => Icons.phone_missed,
        MissedCall.cancelled => Icons.call_end,
        MissedCall.unanswered => Icons.phone_disabled,
      },
      // 只有角色打来没接的那条用醒目的红色，自己挂的不必提醒。
      iconColor: incoming ? voiceCallHangUpRed : textColor,
      title: title,
      subtitle: callBack == null ? null : hint,
    );
    return Semantics(
      button: callBack != null,
      label: callBack == null ? title : '$title，$hint',
      child: callBack == null
          ? KeyedSubtree(
              key: ValueKey('call-record-${record.callId}'),
              child: body,
            )
          : InkWell(
              key: ValueKey('call-record-${record.callId}'),
              onTap: callBack,
              child: body,
            ),
    );
  }

  Widget _layout({
    required IconData icon,
    required Color iconColor,
    required String title,
    String? subtitle,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: iconColor.withValues(alpha: 0.12),
          ),
          child: Icon(icon, size: 18, color: iconColor),
        ),
        const SizedBox(width: 10),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              style: TextStyle(color: textColor, fontWeight: FontWeight.w600),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(
                  color: textColor.withValues(alpha: 0.75),
                  fontSize: 12,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ],
        ),
        const SizedBox(width: 6),
      ],
    );
  }
}
