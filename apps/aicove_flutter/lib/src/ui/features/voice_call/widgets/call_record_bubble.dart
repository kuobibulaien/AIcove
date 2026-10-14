import 'package:flutter/material.dart';

import '../../../../core/models/message_block.dart';
import '../../../shared/widgets/index.dart';
import '../pages/call_transcript_page.dart';

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
    if (record.missed) return _missed();
    final duration = formatCallDuration(record.duration);
    return Semantics(
      button: true,
      label: '语音通话，时长 $duration，点击查看通话记录',
      child: InkWell(
        key: ValueKey('call-record-${record.callId}'),
        onTap: () => MoeWorkspace.open(
          context,
          CallTranscriptPage(record: record),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: textColor.withValues(alpha: 0.12),
              ),
              child: Icon(Icons.call, size: 18, color: textColor),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '语音通话',
                  style: TextStyle(
                    color: textColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  duration,
                  style: TextStyle(
                    color: textColor.withValues(alpha: 0.75),
                    fontSize: 12,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            const SizedBox(width: 6),
          ],
        ),
      ),
    );
  }

  /// 未接来电：没有记录可看，不可点。
  Widget _missed() {
    return Semantics(
      label: '未接来电',
      child: Row(
        key: ValueKey('call-record-${record.callId}'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: textColor.withValues(alpha: 0.12),
            ),
            child: Icon(Icons.phone_missed, size: 18, color: textColor),
          ),
          const SizedBox(width: 10),
          Text(
            '未接来电',
            style: TextStyle(color: textColor, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 6),
        ],
      ),
    );
  }
}
