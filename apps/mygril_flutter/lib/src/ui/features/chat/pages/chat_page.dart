import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../features/chat/providers2.dart';
import '../../../../features/chat/presentation/widgets/composer.dart';
import '../../../../features/chat/presentation/widgets/contact_edit_dialog.dart';
import '../../../../ui/features/character/pages/contact_edit_page.dart';
import '../../../../features/chat/presentation/widgets/chat_settings_dialog.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/animations/parallax_slide_page_route.dart';
import '../../../../ui/shared/widgets/moe_toast.dart';
import '../../../../features/settings/app_settings.dart';
import '../widgets/chat_message_list.dart';

class ChatPage extends ConsumerWidget {
  final String? conversationId;
  final bool showToggleButton;
  const ChatPage({super.key, this.conversationId, this.showToggleButton = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (conversationId != null) {
      final activeId = ref.read(activeConversationIdProvider);
      if (activeId != conversationId) {
        ref.read(activeConversationIdProvider.notifier).state = conversationId;
      }
    }
    final conv = ref.watch(activeConversationProvider);
    // 注意：移除了 sendingProvider 的 watch，改在 _ChatAppBarTitle 中局部监听
    // 这样发送状态变化时只重建标题，不会影响 Composer 输入框
    final actions = ref.read(chatActionsProvider); // 改用 read，actions 不会变
    final sidebarVisible = ref.watch(sidebarVisibleProvider);
    final settingsAsync = ref.watch(appSettingsProvider);
    final colors = context.moeColors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final chatBgColor = settingsAsync.maybeWhen(
      data: (settings) => isDark ? colors.bgMain : settings.chatBackgroundColor.color,
      orElse: () => isDark ? colors.bgMain : colors.surface,
    );

    return Scaffold(
      appBar: AppBar(
        backgroundColor: colors.headerColor,
        foregroundColor: colors.headerContentColor,
        elevation: 0,
        titleTextStyle: TextStyle(
          fontSize: 22, // 详情页标题稍微小一点
          fontWeight: FontWeight.w800,
          color: colors.headerContentColor,
          letterSpacing: 0.8,
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(borderWidth),
          child: Container(
            height: borderWidth,
            decoration: BoxDecoration(
              color: colors.divider,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.04),
                  offset: const Offset(0, 1),
                  blurRadius: 0,
                ),
              ],
            ),
          ),
        ),
        title: Consumer(
          builder: (context, ref, _) {
            final sending = ref.watch(sendingProvider);
            return Text(sending ? '对方输入中...' : (conv?.displayName ?? '聊天'));
          },
        ),
        centerTitle: false,
        leading: showToggleButton
            ? Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () {
                    ref.read(sidebarVisibleProvider.notifier).state = !sidebarVisible;
                  },
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    child: Icon(
                      sidebarVisible ? Icons.menu_open : Icons.menu,
                      color: colors.headerContentColor,
                    ),
                  ),
                ),
              )
            : null,
        actions: [
          if (conv != null)
            IconButton(
              icon: Icon(Icons.more_horiz, color: colors.headerContentColor),
              tooltip: '更多',
              onPressed: () async {
                await showChatSettingsDialog(
                  context: context,
                  conversation: conv,
                  onSearchMessages: () {
                    // TODO: 实现查找聊天记录功能
                    MoeToast.brief(context, '查找功能开发中');
                  },
                  onEditContact: () async {
                    // 编辑角色页面（视差滑动动画）
                    final result = await Navigator.of(context).push<ContactEditResult>(
                      ParallaxSlidePageRoute(page: ContactEditPage(conversation: conv)),
                    );
                    if (result != null) {
                      await ref.read(conversationsProvider.notifier).applyContactEdit(
                            conv.id,
                            displayName: result.displayName,
                            avatarUrl: result.avatarUrl,
                            characterImage: result.characterImage,
                            addressUser: result.addressUser,
                            personaPrompt: result.personaPrompt,
                          );
                      if (!context.mounted) return;
                      MoeToast.brief(context, '已保存角色信息');
                    }
                  },
                  onPinnedChanged: (value) async {
                    await ref.read(conversationsProvider.notifier).updateConversationSettings(
                      conv.id,
                      isPinned: value,
                    );
                    if (!context.mounted) return;
                    MoeToast.brief(context, value ? '已置顶' : '已取消置顶');
                  },
                  onMutedChanged: (value) async {
                    await ref.read(conversationsProvider.notifier).updateConversationSettings(
                      conv.id,
                      isMuted: value,
                    );
                    if (!context.mounted) return;
                    MoeToast.brief(context, value ? '已开启免打扰' : '已关闭免打扰');
                  },
                  onNotificationSoundChanged: (value) async {
                    await ref.read(conversationsProvider.notifier).updateConversationSettings(
                      conv.id,
                      notificationSound: value,
                    );
                    if (!context.mounted) return;
                    MoeToast.brief(context, value ? '已开启提示音' : '已关闭提示音');
                  },
                  onClearMessages: () async {
                    await ref.read(conversationsProvider.notifier).clearMessages(conv.id);
                    if (!context.mounted) return;
                    MoeToast.brief(context, '已清空聊天记录');
                  },
                  onDeleteConversation: () async {
                    await ref.read(conversationsProvider.notifier).deleteConversation(conv.id);
                    if (context.mounted && context.canPop()) context.pop();
                  },
                );
              },
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: Container(
        color: moePanel,
        child: Column(
          children: [
            // 错误信息不再显示在UI中，避免影响聊天体验
            // 如需调试，可以在控制台查看error状态
            // 加载状态通过AppBar的"对方输入中..."和消息气泡状态显示
            Expanded(
              child: conv == null
                  ? const Center(child: CircularProgressIndicator())
                  : Container(
                      // MoeTalk风格：消息区域背景色可配置
                      color: chatBgColor,
              child: ChatMessageList(
                conversationId: conv.id,
                messages: conv.messages,
                avatarUrl: conv.avatarUrl ?? conv.characterImage,
                displayName: conv.displayName,
              ),
                    ),
            ),
            // 输入栏使用内部 SafeArea 处理系统小白条，键盘适配后续单独评估
            Composer(
              disabled: false, // 移除禁用逻辑，允许用户随时输入
              onSend: (text) {
                // 如果正在发送，不处理新消息（在回调时检查，避免重建）
                if (ref.read(sendingProvider)) {
                  MoeToast.brief(context, '请等待当前消息发送完成');
                  return;
                }
                actions.send(text);
              },
              onImageSelected: (imagePath) {
                // 如果正在发送，不处理新图片
                if (ref.read(sendingProvider)) {
                  MoeToast.brief(context, '请等待当前消息发送完成');
                  return;
                }
                actions.sendWithImage(imagePath);
              },
            ),
          ],
        ),
      ),
    );
  }
}
