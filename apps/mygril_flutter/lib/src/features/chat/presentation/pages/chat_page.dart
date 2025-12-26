import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../providers2.dart';
import '../../domain/message.dart';
import 'package:mygril_flutter/src/features/chat/presentation/widgets/message_bubble.dart';
import 'package:mygril_flutter/src/features/chat/presentation/widgets/composer.dart';
import 'package:mygril_flutter/src/features/chat/presentation/widgets/contact_edit_dialog.dart';
import 'contact_edit_page.dart';
import 'package:mygril_flutter/src/features/chat/presentation/widgets/chat_settings_dialog.dart';
import '../../../../core/theme/tokens.dart';
import '../../../../core/widgets/parallax_slide_page_route.dart';
import '../../../../core/widgets/moe_toast.dart';
import '../../../settings/app_settings.dart';

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
    final sending = ref.watch(sendingProvider);
    final error = ref.watch(errorProvider);
    final actions = ref.watch(chatActionsProvider);
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
                  color: Colors.black.withOpacity(0.04),
                  offset: const Offset(0, 1),
                  blurRadius: 0,
                ),
              ],
            ),
          ),
        ),
        title: Text(sending ? '对方输入中...' : (conv?.displayName ?? '聊天')),
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
              child: _MessageList(
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
                // 如果正在发送，不处理新消息
                if (sending) {
                  MoeToast.brief(context, '请等待当前消息发送完成');
                  return;
                }
                actions.send(text);
              },
              onImageSelected: (imagePath) {
                // 如果正在发送，不处理新图片
                if (sending) {
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

class _MessageList extends ConsumerStatefulWidget {
  final List<Message> messages;
  final String conversationId;
  final String? avatarUrl;
  final String displayName;
  const _MessageList({
    required this.messages,
    required this.conversationId,
    this.avatarUrl,
    required this.displayName,
  });

  @override
  ConsumerState<_MessageList> createState() => _MessageListState();
}

class _MessageListState extends ConsumerState<_MessageList> {
  final Set<String> _pendingAnimationIds = <String>{};
  DateTime? _latestAnimatedAt;

  @override
  void initState() {
    super.initState();
    if (widget.messages.isNotEmpty) {
      _latestAnimatedAt = widget.messages.last.createdAt;
    }
  }

  @override
  void didUpdateWidget(covariant _MessageList oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.conversationId != widget.conversationId) {
      _pendingAnimationIds.clear();
      _latestAnimatedAt =
          widget.messages.isNotEmpty ? widget.messages.last.createdAt : null;
      return;
    }

    if (widget.messages.isEmpty) {
      _pendingAnimationIds.clear();
      _latestAnimatedAt = null;
      return;
    }

    final threshold = _latestAnimatedAt;
    final List<Message> newMessages;
    if (threshold == null) {
      newMessages = List<Message>.from(widget.messages);
    } else {
      newMessages = widget.messages
          .where((m) => m.createdAt.isAfter(threshold))
          .toList();
    }

    if (newMessages.isEmpty) {
      return;
    }

    setState(() {
      _pendingAnimationIds.addAll(newMessages.map((m) => m.id));
      final newestTime = newMessages
          .map((m) => m.createdAt)
          .reduce((a, b) => a.isAfter(b) ? a : b);
      _latestAnimatedAt = newestTime;
    });
  }

  @override
  Widget build(BuildContext context) {
    final actions = ref.watch(chatActionsProvider);
    final settingsAsync = ref.watch(appSettingsProvider);
    final fontSize = settingsAsync.maybeWhen(
      data: (settings) => settings.messageFontSize,
      orElse: () => 13.0,
    );
    
    // 构建包含时间分隔器的列表项（因为 ListView reverse=true，需要反转列表顺序）
    final listItems = _buildListItemsWithTimeDividers().reversed.toList();
    
    return ListView.builder(
      reverse: true, // 从底部开始显示，新消息在下方
      // 列表左右留白减半，同时底部根据系统安全区适配小白条
      padding: EdgeInsets.only(
        left: 4,
        right: 4,
        top: 10,
        bottom: MediaQuery.of(context).padding.bottom + 10,
      ),
      itemCount: listItems.length,
      itemBuilder: (context, index) {
        final item = listItems[index];

        if (item is _TimeDivider) {
          // 渲染时间分隔器
          return _buildTimeDivider(context, item.time);
        } else if (item is _MessageItem) {
          // 渲染消息气泡（只有最新消息带动画效果）
          final m = item.message;
          final isMe = m.role == 'user';
          final bubbleWidget = Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: MessageBubble(
              isMe: isMe,
              message: m,
              avatarUrl: isMe ? null : widget.avatarUrl,
              displayName: isMe ? null : widget.displayName,
              fontSize: fontSize,
              onRetry: (isMe && m.status == 'failed')
                  ? () => _showRetryDialog(context, m.id, actions)
                  : null,
            ),
          );

          // 只有真正新增的消息才绑定动画，历史消息自然滚动
          final shouldAnimate = _pendingAnimationIds.contains(m.id);
          if (shouldAnimate) {
            _pendingAnimationIds.remove(m.id);
            return _AnimatedMessageItem(
              key: ValueKey(m.id), // 使用消息ID作为唯一标识
              isMe: isMe, // 传递消息来源，决定动画方向
              child: bubbleWidget,
            );
          }
          return bubbleWidget;
        }
        
        return const SizedBox.shrink();
      },
    );
  }

  /// 构建包含时间分隔器的列表项
  List<_ListItem> _buildListItemsWithTimeDividers() {
    final List<_ListItem> items = [];
    final messages = widget.messages;
    
    for (int i = 0; i < messages.length; i++) {
      final currentMessage = messages[i];
      
      // 检查是否需要在当前消息前添加时间分隔器
      if (i == 0) {
        // 第一条消息前总是显示时间
        items.add(_TimeDivider(currentMessage.createdAt));
      } else {
        final previousMessage = messages[i - 1];
        final timeDiff = currentMessage.createdAt.difference(previousMessage.createdAt);
        
        // 如果时间间隔超过20分钟，添加时间分隔器
        if (timeDiff.inMinutes >= 20) {
          items.add(_TimeDivider(currentMessage.createdAt));
        }
      }
      
      // 添加消息本身
      items.add(_MessageItem(currentMessage));
    }
    
    return items;
  }

  /// 构建时间分隔器Widget
  Widget _buildTimeDivider(BuildContext context, DateTime time) {
    final colors = context.moeColors;
    // 格式化时间为 HH:mm
    final timeStr = _formatChatTime(time);

    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: colors.surfaceAlt,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          timeStr,
          style: TextStyle(
            color: colors.muted,
            fontSize: 12,
            fontWeight: FontWeight.w400,
          ),
        ),
      ),
    );
  }

  /// 显示重发确认对话框
  /// 根据时间生成聊天时间戳文案
  ///
  /// 规则：
  /// - 今天：只显示 HH:mm
  /// - 昨天/前天：前缀“昨天/前天 ”+HH:mm
  /// - 超过三天：前缀“周X ”+HH:mm
  String _formatChatTime(DateTime time) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final targetDay = DateTime(time.year, time.month, time.day);

    final dayDiff = today.difference(targetDay).inDays;

    String prefix;
    if (dayDiff <= 0) {
      // 当天，不需要前缀
      prefix = '';
    } else if (dayDiff == 1) {
      prefix = '昨天 ';
    } else if (dayDiff == 2) {
      prefix = '前天 ';
    } else {
      // 超过三天，显示周几
      const weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
      // DateTime.weekday: 1=周一 ... 7=周日
      prefix = '${weekdays[time.weekday - 1]} ';
    }

    final hh = time.hour.toString().padLeft(2, '0');
    final mm = time.minute.toString().padLeft(2, '0');

    return '$prefix$hh:$mm';
  }

  Future<void> _showRetryDialog(
    BuildContext context,
    String messageId,
    ChatActions actions,
  ) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重新发送'),
        content: const Text('是否重新发送该消息？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('发送'),
          ),
        ],
      ),
    );

    if (result == true) {
      await actions.retry(messageId);
    }
  }
}

/// 列表项的基类（用于区分消息和时间分隔器）
abstract class _ListItem {}

/// 消息列表项
class _MessageItem extends _ListItem {
  final Message message;
  _MessageItem(this.message);
}

/// 时间分隔器列表项
class _TimeDivider extends _ListItem {
  final DateTime time;
  _TimeDivider(this.time);
}

/// 带有出现动画的消息包装组件
/// 实现从屏幕边缘滑入的效果（用户消息从右边，AI消息从左边）
class _AnimatedMessageItem extends StatefulWidget {
  final Widget child;
  final bool isMe; // 是否是用户消息（决定动画方向）
  const _AnimatedMessageItem({
    super.key, // 添加 key 参数，用于标识唯一消息
    required this.child,
    required this.isMe,
  });

  @override
  State<_AnimatedMessageItem> createState() => _AnimatedMessageItemState();
}

class _AnimatedMessageItemState extends State<_AnimatedMessageItem>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _opacityAnimation;
  late Animation<Offset> _slideAnimation;

  @override
  void initState() {
    super.initState();
    
    // 创建动画控制器（400ms，比之前稍长让动画更明显）
    _controller = AnimationController(
      duration: const Duration(milliseconds: 400),
      vsync: this,
    );

    // 淡入动画：从 0.3 到 1（不从完全透明开始，更自然）
    _opacityAnimation = Tween<double>(
      begin: 0.3,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut,
    ));

    // 滑动动画：根据消息来源决定方向
    // 用户消息从右边滑入，AI消息从左边滑入
    final startOffset = widget.isMe 
        ? const Offset(1.0, 0.0)  // 从右边滑入
        : const Offset(-1.0, 0.0); // 从左边滑入
    
    _slideAnimation = Tween<Offset>(
      begin: startOffset,
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut, // 使用简单的缓出曲线，流畅自然
    ));

    // 启动动画
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacityAnimation,
      child: SlideTransition(
        position: _slideAnimation,
        child: widget.child,
      ),
    );
  }
}
