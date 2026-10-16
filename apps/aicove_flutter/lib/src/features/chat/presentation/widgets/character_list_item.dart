/// 消息列表卡片组件 - MoeTalk 风格
///
/// 更新记录：
/// - 2025-12-06: 接入皮肤系统（背景色、描边）
library;

import 'package:flutter/material.dart';
import '../../../../ui/shared/widgets/moe_avatar.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';

import '../../domain/conversation.dart';

/// 消息列表卡片组件 - MoeTalk 风格
class CharacterListItem extends StatelessWidget {
  final Conversation conversation;
  final bool isActive;
  final VoidCallback onTap;
  final GestureTapDownCallback? onTapDown;
  final VoidCallback? onEdit;

  const CharacterListItem({
    super.key,
    required this.conversation,
    this.isActive = false,
    required this.onTap,
    this.onTapDown,
    this.onEdit,
  });

  /// 格式化时间显示
  String _formatTime(DateTime? time) {
    if (time == null) return '';

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final messageDate = DateTime(time.year, time.month, time.day);

    if (messageDate == today) {
      // 今天：HH:mm
      return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    } else if (messageDate == today.subtract(const Duration(days: 1))) {
      // 昨天
      return '昨天';
    } else if (now.year == time.year) {
      // 今年：MM-DD
      return '${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')}';
    } else {
      // 往年：YYYY-MM-DD
      return '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')}';
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final bgColor = isActive
        ? colors.primary.withValues(alpha: isDark ? 0.26 : 0.18)
        : Colors.transparent;
    // Accent text on its own accent tint is too faint; the tint marks the row.
    final titleColor = colors.text;
    final subtitleColor = isActive ? colors.textSecondary : colors.muted;
    final timeColor = subtitleColor;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onTapDown: onTapDown,
        onLongPress: onEdit,
        canRequestFocus: false,
        splashFactory: NoSplash.splashFactory,
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        hoverColor: Colors.transparent,
        focusColor: Colors.transparent,
        overlayColor: WidgetStateProperty.all(Colors.transparent),
        child: Container(
          // 左右内边距，保证卡片内容居中
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          color: bgColor,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 左侧头像
              MoeAvatar(
                  name: conversation.displayName,
                  avatarUrl: conversation.avatarUrl,
                  characterImage: conversation.characterImage),
              const SizedBox(width: 12),
              // 中间：名称 + 最后一条消息
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 第一行：角色名称 + 置顶图标
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            conversation.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: MoeFontWeights.emphasis,
                              fontSize: 16,
                              color: titleColor,
                              letterSpacing: 0.2,
                            ),
                          ),
                        ),
                        if (conversation.isPinned)
                          Padding(
                            padding: const EdgeInsets.only(left: 4),
                            child: Icon(
                              Icons.push_pin,
                              size: 14,
                              color: isActive ? colors.primary : colors.muted,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    // 第二行：静音图标 + 最后一条消息
                    Row(
                      children: [
                        if (conversation.isMuted)
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: Icon(
                              Icons.notifications_off,
                              size: 14,
                              color: subtitleColor,
                            ),
                          ),
                        Expanded(
                          child: Text(
                            conversation.lastMessage ?? '暂无消息',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              color: subtitleColor,
                              height: 1.3,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              // 右侧：时间与未读红点
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisAlignment: MainAxisAlignment.start,
                children: [
                  Text(
                    _formatTime(conversation.lastMessageTime),
                    style: TextStyle(
                      fontSize: 11,
                      color: timeColor,
                    ),
                  ),
                  const SizedBox(height: 6),
                  if (!conversation.isMuted && conversation.unreadCount > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      constraints:
                          const BoxConstraints(minWidth: 20, minHeight: 20),
                      decoration: MoeG2Decoration(
                        radius: 10,
                        color: colors.primary,
                      ),
                      child: Center(
                        child: Text(
                          conversation.unreadCount > 99
                              ? '99+'
                              : '${conversation.unreadCount}',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.white,
                            fontWeight: MoeFontWeights.emphasis,
                            height: 1.2,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
