import 'package:flutter/material.dart';

import '../../../../features/chat/application/chat_page_queries.dart';
import '../../../../features/chat/domain/conversation.dart';
import '../../../shared/widgets/moe_avatar.dart';
import '../../../theme/tokens.dart';

class MessageSearchSectionHeader extends StatelessWidget {
  const MessageSearchSectionHeader(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
    child: Text(
      label,
      style: TextStyle(
        fontSize: 13,
        color: context.moeColors.muted,
        fontWeight: MoeFontWeights.emphasis,
      ),
    ),
  );
}

/// 聊天记录命中行：会话头像与名字，下方是围绕关键词截取并高亮的片段。
class MessageSearchHitTile extends StatelessWidget {
  const MessageSearchHitTile({
    super.key,
    required this.conversation,
    required this.hit,
    required this.keyword,
    required this.onTap,
  });

  final Conversation conversation;
  final ChatPageMessageSearchItem hit;
  final String keyword;
  final VoidCallback onTap;

  static const int _leadingContext = 12;

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    if (time.year == now.year &&
        time.month == now.month &&
        time.day == now.day) {
      return '${two(time.hour)}:${two(time.minute)}';
    }
    if (time.year == now.year) return '${time.month}/${time.day}';
    return '${time.year}/${time.month}/${time.day}';
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final text = hit.content.replaceAll(RegExp(r'\s+'), ' ').trim();
    final match = text.toLowerCase().indexOf(keyword);
    final start = match > _leadingContext ? match - _leadingContext : 0;
    final snippet = start > 0 ? '…${text.substring(start)}' : text;
    final at = match < 0 ? -1 : match - start + (start > 0 ? 1 : 0);
    final base = TextStyle(fontSize: 14, color: colors.muted);
    final prefix = hit.role == 'user' ? '我：' : '';
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            MoeAvatar(
              name: conversation.displayName,
              avatarUrl: conversation.avatarUrl,
              characterImage: conversation.characterImage,
              size: 44,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          conversation.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 16,
                            color: colors.text,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Text(
                        _formatTime(hit.createdAt),
                        style: TextStyle(fontSize: 12, color: colors.muted),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text.rich(
                    TextSpan(
                      style: base,
                      children: [
                        if (prefix.isNotEmpty) TextSpan(text: prefix),
                        if (at < 0)
                          TextSpan(text: snippet)
                        else ...[
                          TextSpan(text: snippet.substring(0, at)),
                          TextSpan(
                            text: snippet.substring(at, at + keyword.length),
                            style: const TextStyle(color: moePrimary),
                          ),
                          TextSpan(
                            text: snippet.substring(at + keyword.length),
                          ),
                        ],
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
