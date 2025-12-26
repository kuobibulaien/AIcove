import 'package:flutter/material.dart';
import '../../../../core/theme/tokens.dart';
import '../../../../core/utils/data_image.dart';
import '../../../../core/widgets/parallax_slide_page_route.dart';
import '../../domain/conversation.dart';

class ChatSettingsPage extends StatelessWidget {
  final Conversation conversation;
  final VoidCallback? onSearchMessages;
  final VoidCallback? onEditContact;
  final ValueChanged<bool>? onPinnedChanged;
  final ValueChanged<bool>? onMutedChanged;
  final ValueChanged<bool>? onNotificationSoundChanged;
  final VoidCallback? onClearMessages;
  final VoidCallback? onDeleteConversation;

  const ChatSettingsPage({
    super.key,
    required this.conversation,
    this.onSearchMessages,
    this.onEditContact,
    this.onPinnedChanged,
    this.onMutedChanged,
    this.onNotificationSoundChanged,
    this.onClearMessages,
    this.onDeleteConversation,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    
    return Scaffold(
      backgroundColor: colors.surface,
      appBar: AppBar(
        backgroundColor: colors.headerColor,
        foregroundColor: colors.headerContentColor,
        elevation: 0,
        title: const Text('聊天设置'),
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: colors.headerContentColor),
          tooltip: '返回',
          onPressed: () => Navigator.pop(context),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(borderWidth),
          child: Container(height: borderWidth, color: colors.divider),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          // 角色信息
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.all(radiusBubble),
                    color: colors.surfaceAlt,
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: _buildAvatar(context, conversation),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        conversation.displayName,
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: colors.text),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          Divider(height: 0, thickness: borderWidth, color: colors.divider),

          _buildListItem(
            context,
            icon: Icons.search,
            title: '查找聊天记录',
            onTap: () {
              Navigator.pop(context);
              onSearchMessages?.call();
            },
          ),

          Divider(height: 0, thickness: borderWidth, color: colors.divider),

          _buildListItem(
            context,
            icon: Icons.edit_outlined,
            title: '编辑角色信息',
            onTap: () => onEditContact?.call(),
          ),

          Divider(height: 0, thickness: borderWidth, color: colors.divider),

          _buildSwitchItem(
            context,
            icon: Icons.push_pin_outlined,
            title: '置顶',
            value: conversation.isPinned,
            onChanged: onPinnedChanged,
          ),

          Divider(height: 0, thickness: borderWidth, color: colors.divider),

          _buildSwitchItem(
            context,
            icon: Icons.notifications_off_outlined,
            title: '消息免打扰',
            value: conversation.isMuted,
            onChanged: onMutedChanged,
          ),

          Divider(height: 0, thickness: borderWidth, color: colors.divider),

          _buildSwitchItem(
            context,
            icon: Icons.volume_up_outlined,
            title: '消息提示音',
            value: conversation.notificationSound,
            onChanged: onNotificationSoundChanged,
          ),

          Divider(height: 0, thickness: borderWidth, color: colors.divider),

          _buildListItem(
            context,
            icon: Icons.delete_sweep_outlined,
            title: '清空聊天记录',
            subtitle: '删除此角色的全部聊天记录',
            onTap: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('清空聊天记录'),
                  content: const Text('确定清空与该角色的所有聊天记录吗？此操作不可撤销。'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
                    FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      style: FilledButton.styleFrom(backgroundColor: Colors.orange),
                      child: const Text('清空'),
                    ),
                  ],
                ),
              );
              if (ok == true && context.mounted) {
                Navigator.pop(context);
                onClearMessages?.call();
              }
            },
          ),

          Divider(height: 0, thickness: borderWidth, color: colors.divider),

          _buildListItem(
            context,
            icon: Icons.delete_outline,
            title: '删除角色',
            subtitle: '删除该角色及其所有聊天记录',
            onTap: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('删除角色'),
                  content: const Text('确定删除该角色及其所有消息记录吗？此操作不可撤销。'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
                    FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      style: FilledButton.styleFrom(backgroundColor: Colors.red),
                      child: const Text('删除'),
                    ),
                  ],
                ),
              );
              if (ok == true && context.mounted) {
                Navigator.pop(context);
                onDeleteConversation?.call();
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _buildAvatar(BuildContext context, Conversation conversation) {
    // 1. 尝试解码 avatarUrl 作为 data URL
    final avatarBytes = decodeDataImage(conversation.avatarUrl);
    if (avatarBytes != null) {
      return Image.memory(avatarBytes, fit: BoxFit.cover);
    }

    // 2. 如果是网络URL
    final avatar = conversation.avatarUrl;
    if (avatar != null && avatar.startsWith('http')) {
      return Image.network(avatar, fit: BoxFit.cover);
    }

    // 3. 如果是本地asset路径
    if (avatar != null && avatar.trim().isNotEmpty) {
      return Image.asset(
        avatar,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _buildFallbackLetter(context, conversation),
      );
    }

    // 4. 尝试使用 characterImage 字段
    final charBytes = decodeDataImage(conversation.characterImage);
    if (charBytes != null) {
      return Image.memory(charBytes, fit: BoxFit.cover);
    }
    final char = conversation.characterImage;
    if (char != null && char.trim().isNotEmpty) {
      return Image.asset(
        char,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _buildFallbackLetter(context, conversation),
      );
    }

    // 5. 最后使用字母占位符
    return _buildFallbackLetter(context, conversation);
  }

  Widget _buildFallbackLetter(BuildContext context, Conversation conversation) {
    final colors = context.moeColors;
    final letter = conversation.displayName.isNotEmpty ? conversation.displayName[0] : '新';
    return Center(
      child: Text(
        letter,
        style: TextStyle(fontSize: 24, color: colors.textSecondary, fontWeight: FontWeight.w500),
      ),
    );
  }

  Widget _buildListItem(
    BuildContext context, {
    required IconData icon,
    required String title,
    String? subtitle,
    VoidCallback? onTap,
  }) {
    final colors = context.moeColors;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      minLeadingWidth: 48,
      leading: Icon(icon, color: colors.text, size: 24),
      title: Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: colors.text)),
      subtitle: subtitle != null ? Text(subtitle, style: TextStyle(fontSize: 12, color: colors.textSecondary)) : null,
      trailing: Icon(Icons.chevron_right, color: colors.muted),
      onTap: onTap,
    );
  }

  Widget _buildSwitchItem(
    BuildContext context, {
    required IconData icon,
    required String title,
    required bool value,
    ValueChanged<bool>? onChanged,
  }) {
    final colors = context.moeColors;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      minLeadingWidth: 48,
      leading: Icon(icon, color: colors.text, size: 24),
      title: Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: colors.text)),
      trailing: Switch(value: value, onChanged: onChanged),
    );
  }
}

Future<void> showChatSettingsDialog({
  required BuildContext context,
  required Conversation conversation,
  VoidCallback? onSearchMessages,
  VoidCallback? onEditContact,
  ValueChanged<bool>? onPinnedChanged,
  ValueChanged<bool>? onMutedChanged,
  ValueChanged<bool>? onNotificationSoundChanged,
  VoidCallback? onClearMessages,
  VoidCallback? onDeleteConversation,
}) {
  return Navigator.of(context).push(
    ParallaxSlidePageRoute(
      page: ChatSettingsPage(
        conversation: conversation,
        onSearchMessages: onSearchMessages,
        onEditContact: onEditContact,
        onPinnedChanged: onPinnedChanged,
        onMutedChanged: onMutedChanged,
        onNotificationSoundChanged: onNotificationSoundChanged,
        onClearMessages: onClearMessages,
        onDeleteConversation: onDeleteConversation,
      ),
    ),
  );
}
