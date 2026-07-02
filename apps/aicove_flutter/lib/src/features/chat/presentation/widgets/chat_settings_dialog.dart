import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:figma_squircle/figma_squircle.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../core/utils/avatar_helper.dart';
import '../../../../ui/shared/animations/parallax_slide_page_route.dart';
import '../../../../ui/shared/widgets/moe_app_bar.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../domain/conversation.dart';
import '../../../plugins/plugin_providers.dart';
import '../../../settings/app_settings.dart';
import '../../../../ui/features/settings/pages/chat_plugin_settings_page.dart';
import '../../../../ui/features/chat/pages/chat_background_settings_page.dart';
import '../../../diary/presentation/diary_list_page.dart';

class ChatSettingsPage extends ConsumerWidget {
  final Conversation conversation;
  final VoidCallback? onSearchMessages;
  final VoidCallback? onEditContact;
  final ValueChanged<ChatBackgroundSettingsResult>? onChatBackgroundSettings;
  final ValueChanged<bool>? onPinnedChanged;
  final ValueChanged<bool>? onMutedChanged;
  final ValueChanged<bool>? onNotificationSoundChanged;
  final VoidCallback? onClearMessages;
  final VoidCallback? onDeleteConversation;
  final ValueChanged<List<String>?>? onEnabledPluginsChanged;

  const ChatSettingsPage({
    super.key,
    required this.conversation,
    this.onSearchMessages,
    this.onEditContact,
    this.onChatBackgroundSettings,
    this.onPinnedChanged,
    this.onMutedChanged,
    this.onNotificationSoundChanged,
    this.onClearMessages,
    this.onDeleteConversation,
    this.onEnabledPluginsChanged,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.moeColors;

    return Scaffold(
      backgroundColor: colors.surface,
      appBar: const MoeAppBar(
        title: '聊天设置',
        showBackButton: true,
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          // 角色信息（点击进入编辑）
          InkWell(
            onTap: () => onEditContact?.call(),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    decoration: MoeG2Decoration(
                      radius: radiusBubble.x,
                      color: colors.surfaceAlt,
                    ),
                    child: MoeG2ClipRRect(
                      radius: radiusBubble.x,
                      child: _buildAvatar(context, conversation),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      conversation.displayName,
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: MoeFontWeights.emphasis,
                          color: colors.text),
                    ),
                  ),
                  Icon(Icons.chevron_right, color: colors.muted),
                ],
              ),
            ),
          ),

          Divider(height: 0, thickness: borderWidth, color: colors.borderLight),

          _buildListItem(
            context,
            icon: Icons.book_outlined,
            title: '查看日记',
            onTap: () => _openDiaryPage(context),
          ),

          Divider(height: 0, thickness: borderWidth, color: colors.borderLight),

          _buildListItem(
            context,
            icon: Icons.search,
            title: '查找聊天记录',
            onTap: () {
              Navigator.pop(context);
              onSearchMessages?.call();
            },
          ),

          Divider(height: 0, thickness: borderWidth, color: colors.borderLight),
          _buildListItem(
            context,
            icon: Icons.image_outlined,
            title: '聊天背景',
            subtitle:
                conversation.chatBackgroundImage?.trim().isNotEmpty == true
                    ? '已设置自定义背景'
                    : '使用默认背景',
            onTap: () async {
              final result = await Navigator.of(context)
                  .push<ChatBackgroundSettingsResult>(
                ParallaxSlidePageRoute(
                  page: ChatBackgroundSettingsPage(conversation: conversation),
                ),
              );
              if (result != null) {
                onChatBackgroundSettings?.call(result);
              }
            },
          ),

          Divider(height: 0, thickness: borderWidth, color: colors.borderLight),

          _buildSwitchItem(
            context,
            icon: Icons.push_pin_outlined,
            title: '置顶',
            value: conversation.isPinned,
            onChanged: onPinnedChanged,
          ),

          Divider(height: 0, thickness: borderWidth, color: colors.borderLight),

          _buildSwitchItem(
            context,
            icon: Icons.notifications_off_outlined,
            title: '消息免打扰',
            value: conversation.isMuted,
            onChanged: onMutedChanged,
          ),

          Divider(height: 0, thickness: borderWidth, color: colors.borderLight),

          _buildSwitchItem(
            context,
            icon: Icons.volume_up_outlined,
            title: '消息提示音',
            value: conversation.notificationSound,
            onChanged: onNotificationSoundChanged,
          ),

          Divider(height: 0, thickness: borderWidth, color: colors.borderLight),

          _buildListItem(
            context,
            icon: Icons.extension_outlined,
            title: '插件设置',
            onTap: () => _showPluginSelector(context, ref),
          ),

          Divider(height: 0, thickness: borderWidth, color: colors.borderLight),

          _buildListItem(
            context,
            icon: Icons.delete_sweep_outlined,
            title: '清空聊天记录',
            onTap: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('清空聊天记录'),
                  content: const Text('确定清空与该角色的所有聊天记录吗？此操作不可撤销。'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('取消')),
                    FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      style: FilledButton.styleFrom(
                          backgroundColor: Colors.orange),
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

          Divider(height: 0, thickness: borderWidth, color: colors.borderLight),

          _buildListItem(
            context,
            icon: Icons.delete_outline,
            title: '删除角色',
            onTap: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('删除角色'),
                  content: const Text('确定删除该角色及其所有消息记录吗？此操作不可撤销。'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('取消')),
                    FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      style:
                          FilledButton.styleFrom(backgroundColor: Colors.red),
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
    final colors = context.moeColors;
    final helper = AvatarHelper(
      avatarUrl: conversation.avatarUrl,
      characterImage: conversation.characterImage,
      displayName: conversation.displayName,
    );
    return helper.buildAvatarWidget(
      fallback: Center(
        child: Text(
          conversation.displayName.isNotEmpty
              ? conversation.displayName[0]
              : '新',
          style: TextStyle(
              fontSize: 24,
              color: colors.textSecondary,
              fontWeight: MoeFontWeights.emphasis),
        ),
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
      minLeadingWidth: 24,
      horizontalTitleGap: 12,
      leading: Icon(icon, color: colors.text, size: 24),
      title: Text(title,
          style: TextStyle(
              fontSize: 15,
              fontWeight: MoeFontWeights.emphasis,
              color: colors.text)),
      subtitle: subtitle != null
          ? Text(subtitle,
              style: TextStyle(fontSize: 12, color: colors.textSecondary))
          : null,
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
      minLeadingWidth: 24,
      horizontalTitleGap: 12,
      leading: Icon(icon, color: colors.text, size: 24),
      title: Text(title,
          style: TextStyle(
              fontSize: 15,
              fontWeight: MoeFontWeights.emphasis,
              color: colors.text)),
      trailing: Switch(value: value, onChanged: onChanged),
    );
  }

  void _openDiaryPage(BuildContext context) {
    Navigator.of(context).push(
      ParallaxSlidePageRoute(
        page: DiaryListPage(
          conversationId: conversation.id,
          characterName: conversation.displayName,
        ),
      ),
    );
  }

  void _showPluginSelector(BuildContext context, WidgetRef ref) {
    // 当前允许的插件列表，null表示允许全部
    final currentEnabled = conversation.enabledPlugins;
    // 转换为Set便于操作，null时默认允许全部
    final selectedSet = currentEnabled != null
        ? {
            for (final id in currentEnabled)
              if (conversationScopedChatPluginItems.any((p) => p.id == id)) id,
          }
        : Set<String>.from(
            conversationScopedChatPluginItems.map((p) => p.id),
          );

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _PluginSelectorSheet(
        ref: ref,
        initialSelected: selectedSet,
        onConfirm: (selected) {
          // 如果选择了全部，返回null表示允许全部
          final result =
              selected.length == conversationScopedChatPluginItems.length
                  ? null
                  : selected.toList();
          onEnabledPluginsChanged?.call(result);
        },
      ),
    );
  }
}

/// 插件选择底部弹窗
class _PluginSelectorSheet extends StatefulWidget {
  final WidgetRef ref;
  final Set<String> initialSelected;
  final ValueChanged<Set<String>> onConfirm;

  const _PluginSelectorSheet({
    required this.ref,
    required this.initialSelected,
    required this.onConfirm,
  });

  @override
  State<_PluginSelectorSheet> createState() => _PluginSelectorSheetState();
}

class _PluginSelectorSheetState extends State<_PluginSelectorSheet> {
  late Set<String> _selected;

  @override
  void initState() {
    super.initState();
    _selected = Set.from(widget.initialSelected);
  }

  /// 获取插件全局启用状态
  bool _isPluginGlobalEnabled(String pluginId) {
    switch (pluginId) {
      case 'memory':
        return widget.ref.read(memoryPluginConfigProvider).enabled;
      case 'tts':
        return widget.ref.read(ttsPluginConfigProvider).enabled;
      case 'trigger':
        return widget.ref
                .read(appSettingsProvider)
                .value
                ?.autoReplySettings
                .enabled ??
            false;
      case 'sticker':
        return widget.ref.read(stickerPluginConfigProvider).enabled;
      case 'image':
        return widget.ref
                .read(appSettingsProvider)
                .value
                ?.imageGenerationEnabled ??
            true;
      case 'time_awareness':
        return widget.ref.read(timeAwarenessPluginConfigProvider).enabled;
      default:
        return true; // 未实现的插件默认允许
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    const sheetBorderRadius = SmoothBorderRadius.vertical(
      top: SmoothRadius(cornerRadius: 16, cornerSmoothing: 0.6),
    );
    return Container(
      color: Colors.transparent,
      child: MoeG2ClipRRect.borderRadius(
        borderRadius: sheetBorderRadius,
        child: Container(
          color: colors.surface,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 标题栏
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
                child: Row(
                  children: [
                    Text('插件设置',
                        style: TextStyle(
                            fontSize: 18,
                            fontWeight: MoeFontWeights.emphasis,
                            color: colors.text)),
                    const Spacer(),
                    TextButton(
                      onPressed: () {
                        widget.onConfirm(_selected);
                        Navigator.pop(context);
                      },
                      child: const Text('确定'),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: colors.divider),
              // 插件列表
              ConstrainedBox(
                constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.5),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: conversationScopedChatPluginItems.length,
                  itemBuilder: (context, index) {
                    final item = conversationScopedChatPluginItems[index];
                    final isGlobalEnabled = _isPluginGlobalEnabled(item.id);
                    final isAllowed = _selected.contains(item.id);

                    return ListTile(
                      leading: Icon(
                        item.icon,
                        color: isGlobalEnabled ? colors.text : colors.muted,
                      ),
                      title: Text(
                        item.name,
                        style: TextStyle(
                          color: isGlobalEnabled ? colors.text : colors.muted,
                        ),
                      ),
                      subtitle: isGlobalEnabled
                          ? null
                          : Text('插件未启用',
                              style:
                                  TextStyle(fontSize: 12, color: colors.muted)),
                      trailing: Checkbox(
                        value: isAllowed,
                        onChanged: isGlobalEnabled
                            ? (v) => setState(() {
                                  if (v == true) {
                                    _selected.add(item.id);
                                  } else {
                                    _selected.remove(item.id);
                                  }
                                })
                            : null,
                      ),
                      onTap: isGlobalEnabled
                          ? () => setState(() {
                                if (_selected.contains(item.id)) {
                                  _selected.remove(item.id);
                                } else {
                                  _selected.add(item.id);
                                }
                              })
                          : null,
                    );
                  },
                ),
              ),
              SizedBox(height: MediaQuery.of(context).padding.bottom + 8),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> showChatSettingsDialog({
  required BuildContext context,
  required Conversation conversation,
  VoidCallback? onSearchMessages,
  VoidCallback? onEditContact,
  ValueChanged<ChatBackgroundSettingsResult>? onChatBackgroundSettings,
  ValueChanged<bool>? onPinnedChanged,
  ValueChanged<bool>? onMutedChanged,
  ValueChanged<bool>? onNotificationSoundChanged,
  VoidCallback? onClearMessages,
  VoidCallback? onDeleteConversation,
  ValueChanged<List<String>?>? onEnabledPluginsChanged,
}) {
  return Navigator.of(context).push(
    ParallaxSlidePageRoute(
      page: ChatSettingsPage(
        conversation: conversation,
        onSearchMessages: onSearchMessages,
        onEditContact: onEditContact,
        onChatBackgroundSettings: onChatBackgroundSettings,
        onPinnedChanged: onPinnedChanged,
        onMutedChanged: onMutedChanged,
        onNotificationSoundChanged: onNotificationSoundChanged,
        onClearMessages: onClearMessages,
        onDeleteConversation: onDeleteConversation,
        onEnabledPluginsChanged: onEnabledPluginsChanged,
      ),
    ),
  );
}
