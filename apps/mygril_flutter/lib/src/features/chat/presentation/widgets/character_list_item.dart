/// 消息列表卡片组件 - MoeTalk 风格
/// 
/// 更新记录：
/// - 2025-12-06: 接入皮肤系统（背景色、描边）
import 'package:flutter/material.dart';
import 'package:mygril_flutter/src/core/utils/data_image.dart';
import '../../../../core/theme/skin_provider.dart';
import '../../../../core/theme/tokens.dart';

import '../../domain/conversation.dart';

/// 消息列表卡片组件 - MoeTalk 风格
class CharacterListItem extends StatelessWidget {
  final Conversation conversation;
  final bool isActive;
  final VoidCallback onTap;
  final VoidCallback? onEdit;

  const CharacterListItem({
    super.key,
    required this.conversation,
    this.isActive = false,
    required this.onTap,
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
    final skin = context.skin;
    final colors = context.moeColors;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final bgColor = isActive ? colors.surfaceAlt : colors.surface;
    final borderColor = colors.borderLight;
    final titleColor = colors.text;
    final subtitleColor = colors.muted;
    final timeColor = colors.muted;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          // 左右内边距，保证卡片内容居中
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: bgColor,
            border: Border(
              bottom: BorderSide(color: borderColor, width: skin.borderWidth),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 左侧头像
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.all(radiusBubble),
                  color: colors.surface, // 使用主题背景色，自动适配深浅模式
                  border: Border.all(
                    color: colors.borderLight, // 添加细微描边，增强边界感
                    width: 0.5,
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: _buildAvatarContent(conversation),
              ),
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
                              fontWeight: FontWeight.w600,
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
                              color: colors.focus,
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
                              fontSize: 13,
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
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFF4D4F),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Center(
                        child: Text(
                          conversation.unreadCount > 99 ? '99+' : '${conversation.unreadCount}',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
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

Widget _buildAvatarContent(Conversation conversation) {
  final avatarBytes = decodeDataImage(conversation.avatarUrl);
  if (avatarBytes != null) {
    return Image.memory(avatarBytes, fit: BoxFit.cover);
  }

  final avatar = conversation.avatarUrl;
  if (avatar != null && avatar.startsWith('http')) {
    return Image.network(avatar, fit: BoxFit.cover);
  }
  if (avatar != null && avatar.trim().isNotEmpty) {
    return Image.asset(
      avatar,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => _buildFallbackLetter(conversation),
    );
  }

  final charBytes = decodeDataImage(conversation.characterImage);
  if (charBytes != null) {
    return Image.memory(charBytes, fit: BoxFit.cover);
  }
  final char = conversation.characterImage;
  if (char != null && char.trim().isNotEmpty) {
    return Image.asset(
      char,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => _buildFallbackLetter(conversation),
    );
  }

  return _buildFallbackLetter(conversation);
}

Widget _buildFallbackLetter(Conversation conversation) {
  final text = conversation.displayName.isNotEmpty ? conversation.displayName[0] : '新';
  return Center(
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 24,
        color: Color(0xFF999999),
        fontWeight: FontWeight.w500,
      ),
    ),
  );
}
