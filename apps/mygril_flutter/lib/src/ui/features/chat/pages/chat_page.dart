import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../../features/chat/domain/conversation.dart';
import '../../../../features/chat/providers2.dart';
import '../../../../features/chat/presentation/widgets/composer.dart';
import '../../../../features/chat/presentation/widgets/contact_edit_dialog.dart';
import '../../../../ui/features/character/pages/contact_edit_page.dart';
import '../../../../features/chat/presentation/widgets/chat_settings_dialog.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/animations/parallax_slide_page_route.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../features/settings/app_settings.dart';
import '../../../../core/database/database.dart' as db;
import '../../../../core/database/database_provider.dart';
import '../../../../core/database/converters/database_converters.dart';
import '../../../../core/models/message_block.dart';
import '../../../../core/utils/image_preheat_queue.dart';
import '../widgets/chat_message_list.dart';

class ChatPage extends ConsumerStatefulWidget {
  final String? conversationId;
  final Conversation? initialConversation;
  final bool showToggleButton;
  const ChatPage(
      {super.key,
      this.conversationId,
      this.initialConversation,
      this.showToggleButton = false});

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  /// 分页加载状态
  bool _isLoadingMore = false;

  /// 是否还有更多历史消息
  bool _hasMoreMessages = true;

  /// 已预加载过的会话 ID，避免重复预加载
  String? _preloadedConversationId;
  bool _didSchedulePrecache = false;

  @override
  void initState() {
    super.initState();
    // 进入聊天页时尽早把 activeConversationId 设置到位，避免首帧先渲染到“默认会话”造成闪跳/卡顿
    final targetId = widget.conversationId;
    if (targetId == null) return;
    final activeId = ref.read(activeConversationIdProvider);
    if (activeId != targetId) {
      ref.read(activeConversationIdProvider.notifier).state = targetId;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 不要在 didChangeDependencies 里直接跑大量预缓存：
    // 这里处于“路由刚切换、转场动画要开始”的关键路径，任何同步循环/IO 都可能导致“点击后先顿一下”。
    // 预缓存放到首帧之后后台进行（不阻塞动画），避免卡顿；图片是否闪烁主要靠“进入前预热/缓存命中”解决。
    _scheduleImagePrecache();
  }

  void _scheduleImagePrecache() {
    if (_didSchedulePrecache) return;
    _didSchedulePrecache = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _didSchedulePrecache = false;
      if (!mounted) return;
      _triggerImagePreload();
    });
  }

  /// 触发图片预加载
  void _triggerImagePreload() {
    final targetId = widget.conversationId;
    if (targetId == null || targetId == _preloadedConversationId) {
      // 宽屏内嵌 ChatPage（conversationId==null）不走预缓存；同会话只预缓存一次
      return;
    }

    // 获取会话数据
    final initial = widget.initialConversation?.id == targetId
        ? widget.initialConversation
        : null;
    final conv = initial ??
        ref.read(conversationsProvider).maybeWhen(
              data: (list) {
                for (final c in list) {
                  if (c.id == targetId) return c;
                }
                return null;
              },
              orElse: () => null,
            );

    if (conv != null) {
      _preloadImages(conv);
    }
  }

  /// 预加载会话中的图片（后台预热，不阻塞转场/首帧）
  Future<void> _preloadImages(Conversation conv) async {
    if (_preloadedConversationId == conv.id) return;

    try {
      const maxMessagesToScan = 10; // 只扫首屏附近的消息，避免一次性扫描过多 blocks
      const maxImagesToCache = 24; // 控制预缓存上限，避免 ImageCache/解码压力过大

      final providers = <ImageProvider>[];

      // 1. 预缓存头像
      final avatarUrl = conv.avatarUrl ?? conv.characterImage;
      if (avatarUrl != null && avatarUrl.isNotEmpty) {
        final provider = _getImageProvider(avatarUrl);
        if (provider != null) {
          providers.add(provider);
        }
      }

      // 2. 预缓存首屏消息中的图片/表情
      final messages = conv.messages;
      final start = messages.length > maxMessagesToScan
          ? messages.length - maxMessagesToScan
          : 0;
      for (var i = start;
          i < messages.length && providers.length < maxImagesToCache;
          i++) {
        final msg = messages[i];
        if (msg.blocks == null) continue;
        for (final block in msg.blocks!) {
          if (providers.length >= maxImagesToCache) break;
          final provider = _getBlockImageProvider(block);
          if (provider != null) {
            providers.add(provider);
          }
        }
      }

      if (providers.isNotEmpty && context.mounted) {
        ref.read(imagePreheatQueueProvider).enqueueAllFromContext(
              context,
              providers,
            );
      }

      _preloadedConversationId = conv.id;
    } catch (_) {
      // 预加载失败不影响正常流程
    }
  }

  /// 根据 URL 获取对应的 ImageProvider
  ImageProvider? _getImageProvider(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return null;

    // data:image/...;base64,... 可能很大，预缓存会引入额外同步 decode 成本，这里选择跳过（不阻塞首帧）。
    if (trimmed.startsWith('data:image')) return null;

    final isNetwork =
        trimmed.startsWith('http://') || trimmed.startsWith('https://');
    final isAsset =
        trimmed.startsWith('assets/') || trimmed.startsWith('packages/');

    if (isNetwork) {
      return CachedNetworkImageProvider(trimmed);
    } else if (isAsset) {
      return AssetImage(trimmed);
    } else {
      // 本地文件（避免 existsSync 同步 IO，交给 ImageProvider 自己处理失败情况）
      return FileImage(File(trimmed));
    }
  }

  /// 根据 MessageBlock 获取对应的 ImageProvider
  ImageProvider? _getBlockImageProvider(MessageBlock block) {
    if (block is ImageBlock) {
      // base64 图片预缓存会带来同步解码开销（实际渲染时已有兜底），这里跳过避免影响动画流畅度
      if (block.base64 != null && block.base64!.isNotEmpty) return null;

      // 网络图片
      if (block.url != null && block.url!.isNotEmpty) {
        return CachedNetworkImageProvider(block.url!);
      }
      // 本地图片
      if (block.localPath != null && block.localPath!.isNotEmpty) {
        // 避免 existsSync 同步 IO
        return FileImage(File(block.localPath!));
      }
    } else if (block is EmojiBlock) {
      final path = block.path.trim();
      if (path.isNotEmpty) {
        return _getImageProvider(path);
      }
    }
    return null;
  }

  @override
  void didUpdateWidget(covariant ChatPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 如果 conversationId 变化，更新 provider 并重置分页状态
    final targetId = widget.conversationId;
    if (targetId != oldWidget.conversationId && targetId != null) {
      ref.read(activeConversationIdProvider.notifier).state = targetId;
      // 切换会话时重置分页状态
      setState(() {
        _hasMoreMessages = true;
        _isLoadingMore = false;
      });
      _scheduleImagePrecache();
    }
  }

  /// 加载更多历史消息（分页加载）
  Future<void> _loadMoreMessages(Conversation conv) async {
    if (_isLoadingMore || !_hasMoreMessages) return;
    if (conv.messages.isEmpty) {
      setState(() => _hasMoreMessages = false);
      return;
    }

    setState(() => _isLoadingMore = true);

    try {
      final msgRepo = ref.read(messageRepositoryProvider);
      final blockRepo = ref.read(messageBlockRepositoryProvider);

      // 获取当前最旧消息的时间
      final oldestMessage = conv.messages.first;
      final oldestTime = oldestMessage.createdAt.millisecondsSinceEpoch;

      // 从数据库加载更早的消息
      final dbMsgs = await msgRepo.getByConversation(
        conv.id,
        limit: 30,
        beforeTime: oldestTime,
      );

      if (dbMsgs.isEmpty) {
        setState(() {
          _hasMoreMessages = false;
          _isLoadingMore = false;
        });
        return;
      }

      // 批量获取 blocks
      final messageIds = dbMsgs.map((m) => m.id).toList();
      final dbBlocks = await blockRepo.getByMessages(messageIds);

      // 按 messageId 分组
      final blocksByMsgId = <String, List<MessageBlock>>{};
      for (final dbBlock in dbBlocks) {
        final block = MessageBlockConverter.fromDb(dbBlock);
        if (block != null) {
          blocksByMsgId.putIfAbsent(dbBlock.messageId, () => []).add(block);
        }
      }

      // 组装消息（reversed: 数据库返回 desc，UI 需要 asc）
      final olderMessages = dbMsgs.reversed.map((dbMsg) {
        final blocks = blocksByMsgId[dbMsg.id];
        return MessageConverter.fromDb(dbMsg, blocks: blocks);
      }).toList();

      // 更新会话，把更旧的消息插入到头部
      await ref.read(conversationsProvider.notifier).updateOne(
            conv.id,
            (c) => c.copyWith(messages: [...olderMessages, ...c.messages]),
          );

      // 如果加载的消息少于30条，说明没有更多了
      if (dbMsgs.length < 30) {
        setState(() => _hasMoreMessages = false);
      }
    } catch (e) {
      debugPrint('加载更多消息失败: $e');
    } finally {
      if (mounted) {
        setState(() => _isLoadingMore = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final targetId = widget.conversationId;
    final initial = widget.initialConversation?.id == targetId
        ? widget.initialConversation
        : null;
    final conv = targetId == null
        ? ref.watch(activeConversationProvider)
        : ref.watch(conversationsProvider).maybeWhen(
              data: (list) {
                for (final c in list) {
                  if (c.id == targetId) return c;
                }
                return initial;
              },
              orElse: () => initial,
            );
    // 注意：移除了 sendingProvider 的 watch，改在 _ChatAppBarTitle 中局部监听
    // 这样发送状态变化时只重建标题，不会影响 Composer 输入框
    final actions = ref.read(chatActionsProvider); // 改用 read，actions 不会变
    final sidebarVisible = ref.watch(sidebarVisibleProvider);
    final settingsAsync = ref.watch(appSettingsProvider);
    final colors = context.moeColors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final chatBgColor = settingsAsync.maybeWhen(
      data: (settings) {
        if (isDark) return colors.bgMain;
        // 默认色跟随全局背景色
        return settings.chatBackgroundColor.color ?? colors.surface;
      },
      orElse: () => isDark ? colors.bgMain : colors.surface,
    );

    return Scaffold(
      // 由输入组件自己管理“键盘/更多面板”占位与位移，避免 Scaffold 自动挤压布局造成跳动
      resizeToAvoidBottomInset: false,
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
        leading: widget.showToggleButton
            ? MoeG2ClipRRect(
                radius: 8,
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () {
                      ref.read(sidebarVisibleProvider.notifier).state =
                          !sidebarVisible;
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Icon(
                        sidebarVisible ? Icons.menu_open : Icons.menu,
                        color: colors.headerContentColor,
                      ),
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
                    showMoeBottomSheet(
                      context: context,
                      title: '查找聊天记录',
                      showCloseButton: true,
                      maxHeight: MediaQuery.sizeOf(context).height * 0.85,
                      builder: (context) =>
                          _ChatMessageSearchContent(conversation: conv),
                    );
                  },
                  onEditContact: () async {
                    // 编辑角色页面（视差滑动动画）
                    final result =
                        await Navigator.of(context).push<ContactEditResult>(
                      ParallaxSlidePageRoute(
                          page: ContactEditPage(
                        conversation: conv,
                        editMode: EditMode.editConversation,
                      )),
                    );
                    if (result != null) {
                      await ref
                          .read(conversationsProvider.notifier)
                          .applyContactEdit(
                            conv.id,
                            displayName: result.displayName,
                            avatarUrl: result.avatarUrl,
                            characterImage: result.characterImage,
                            addressUser: result.addressUser,
                            description: result.description,
                            personaPrompt: result.personaPrompt,
                          );
                      if (!context.mounted) return;
                      MoeToast.brief(context, '已保存角色信息');
                    }
                  },
                  onPinnedChanged: (value) async {
                    await ref
                        .read(conversationsProvider.notifier)
                        .updateConversationSettings(
                          conv.id,
                          isPinned: value,
                        );
                    if (!context.mounted) return;
                    MoeToast.brief(context, value ? '已置顶' : '已取消置顶');
                  },
                  onMutedChanged: (value) async {
                    await ref
                        .read(conversationsProvider.notifier)
                        .updateConversationSettings(
                          conv.id,
                          isMuted: value,
                        );
                    if (!context.mounted) return;
                    MoeToast.brief(context, value ? '已开启免打扰' : '已关闭免打扰');
                  },
                  onNotificationSoundChanged: (value) async {
                    await ref
                        .read(conversationsProvider.notifier)
                        .updateConversationSettings(
                          conv.id,
                          notificationSound: value,
                        );
                    if (!context.mounted) return;
                    MoeToast.brief(context, value ? '已开启提示音' : '已关闭提示音');
                  },
                  onClearMessages: () async {
                    await ref
                        .read(conversationsProvider.notifier)
                        .clearMessages(conv.id);
                    if (!context.mounted) return;
                    MoeToast.brief(context, '已清空聊天记录');
                  },
                  onDeleteConversation: () async {
                    await ref
                        .read(conversationsProvider.notifier)
                        .deleteConversation(conv.id);
                    if (context.mounted && context.canPop()) context.pop();
                  },
                  onEnabledPluginsChanged: (plugins) async {
                    await ref
                        .read(conversationsProvider.notifier)
                        .updateConversationSettings(
                          conv.id,
                          enabledPlugins: plugins,
                          clearEnabledPlugins: plugins == null,
                        );
                    if (!context.mounted) return;
                    MoeToast.brief(context, '插件设置已更新');
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
                  : GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onTap: () {
                        final keyboardHeight =
                            MediaQuery.viewInsetsOf(context).bottom;
                        // 键盘显示中：只隐藏键盘但不立刻丢焦点，让输入框跟着键盘动画一起回收（避免被键盘盖住）
                        if (keyboardHeight > 0) {
                          SystemChannels.textInput
                              .invokeMethod('TextInput.hide');
                          return;
                        }
                        // 键盘未显示：丢焦点用于关闭“更多面板”（更多面板会保持一个只读焦点）
                        FocusManager.instance.primaryFocus?.unfocus();
                      },
                      child: Container(
                        // MoeTalk风格：消息区域背景色可配置
                        color: chatBgColor,
                        child: ChatMessageList(
                          key: ValueKey(conv.id),
                          conversationId: conv.id,
                          messages: conv.messages,
                          avatarUrl: conv.avatarUrl ?? conv.characterImage,
                          displayName: conv.displayName,
                          onLoadMore: () => _loadMoreMessages(conv),
                          isLoadingMore: _isLoadingMore,
                          hasMoreMessages: _hasMoreMessages,
                          onEditMessage: (message) async {
                            final text = await actions.editMessage(message.id);
                            if (text != null && text.isNotEmpty) {
                              ref.read(editingTextProvider.notifier).state =
                                  text;
                            }
                          },
                          onRegenerateMessage: (message) {
                            if (ref.read(sendingProvider)) {
                              MoeToast.brief(context, '请等待当前消息发送完成');
                              return;
                            }
                            actions.regenerate(message.id);
                          },
                        ),
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
                // 检查是否有引用消息
                final quoted = ref.read(quotedMessageProvider);
                if (quoted != null) {
                  // 带引用发送
                  final quotedPrefix =
                      '> 引用「${quoted.content.length > 30 ? '${quoted.content.substring(0, 30)}...' : quoted.content}」\n\n';
                  actions.send(quotedPrefix + text);
                  ref.read(quotedMessageProvider.notifier).state = null;
                } else {
                  actions.send(text);
                }
              },
              onImageSelected: (imagePath) {
                // 如果正在发送，不处理新图片
                if (ref.read(sendingProvider)) {
                  MoeToast.brief(context, '请等待当前消息发送完成');
                  return;
                }
                actions.sendWithImage(imagePath);
              },
              onFileSelected: (filePath) {
                // 如果正在发送，不处理新文件
                if (ref.read(sendingProvider)) {
                  MoeToast.brief(context, '请等待当前消息发送完成');
                  return;
                }
                actions.sendWithFile(filePath);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _ChatMessageSearchContent extends ConsumerStatefulWidget {
  final Conversation conversation;

  const _ChatMessageSearchContent({required this.conversation});

  @override
  ConsumerState<_ChatMessageSearchContent> createState() =>
      _ChatMessageSearchContentState();
}

class _ChatMessageSearchContentState
    extends ConsumerState<_ChatMessageSearchContent> {
  final _searchCtrl = TextEditingController();
  Timer? _debounce;
  String _keyword = '';
  DateTime? _selectedDate;
  int _searchSeq = 0;

  bool _loading = false;
  String? _error;
  List<db.Message> _results = const [];

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _scheduleSearch() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      _runSearch();
    });
  }

  Future<void> _runSearch() async {
    final seq = ++_searchSeq;
    final keyword = _keyword.trim();
    final date = _selectedDate;

    // 两个条件都没填时，不做“全库搜索”，避免一下子刷出太多记录。
    if (keyword.isEmpty && date == null) {
      if (!mounted || seq != _searchSeq) return;
      setState(() {
        _loading = false;
        _error = null;
        _results = const [];
      });
      return;
    }

    final int? startMs;
    final int? endMs;
    if (date == null) {
      startMs = null;
      endMs = null;
    } else {
      final start = DateTime(date.year, date.month, date.day);
      startMs = start.millisecondsSinceEpoch;
      endMs = start.add(const Duration(days: 1)).millisecondsSinceEpoch;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final repo = ref.read(messageRepositoryProvider);
      final rows = await repo.searchByConversation(
        widget.conversation.id,
        keyword: keyword.isEmpty ? null : keyword,
        startTime: startMs,
        endTime: endMs,
        limit: 200,
      );
      if (!mounted || seq != _searchSeq) return;
      setState(() {
        _loading = false;
        _results = rows;
      });
    } catch (e) {
      if (!mounted || seq != _searchSeq) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: now,
      initialDate: _selectedDate ?? now,
    );
    if (picked == null || !mounted) return;
    setState(() => _selectedDate = picked);
    _scheduleSearch();
  }

  void _clearDate() {
    setState(() => _selectedDate = null);
    _scheduleSearch();
  }

  void _clearKeyword() {
    setState(() {
      _searchCtrl.clear();
      _keyword = '';
    });
    _scheduleSearch();
  }

  String _formatDay(DateTime date) {
    final y = date.year.toString().padLeft(4, '0');
    final m = date.month.toString().padLeft(2, '0');
    final d = date.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  String _formatTime(DateTime time) {
    final ymd = _formatDay(time);
    final hh = time.hour.toString().padLeft(2, '0');
    final mm = time.minute.toString().padLeft(2, '0');
    return '$ymd $hh:$mm';
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final keyword = _keyword.trim();
    final date = _selectedDate;

    return Column(
      children: [
        // 关键词搜索框
        Padding(
          padding: const EdgeInsets.all(16),
          child: MoeTextField(
            controller: _searchCtrl,
            autofocus: true,
            hint: '输入关键词（可选）',
            prefixIcon: Icons.search,
            suffix: _searchCtrl.text.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.clear, size: 20),
                    onPressed: _clearKeyword,
                  )
                : null,
            borderColor: colors.borderLight,
            focusBorderColor: colors.primary,
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            onChanged: (value) {
              setState(() => _keyword = value);
              _scheduleSearch();
            },
          ),
        ),

        // 日期筛选
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: MoeG2ClipRRect(
            radius: 12,
            child: Container(
              decoration: MoeG2Decoration(
                radius: 12,
                color: colors.surfaceAlt,
                border: Border.all(
                  color: colors.borderLight,
                  width: borderWidth,
                ),
              ),
              child: Material(
                color: Colors.transparent,
                child: ListTile(
                  dense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
                  title: const Text('日期'),
                  subtitle: Text(date == null ? '全部' : _formatDay(date)),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: '选择日期',
                        icon: const Icon(Icons.calendar_month, size: 20),
                        color: moePrimary,
                        onPressed: _pickDate,
                      ),
                      if (date != null)
                        IconButton(
                          tooltip: '清除日期',
                          icon: const Icon(Icons.close, size: 20),
                          color: colors.muted,
                          onPressed: _clearDate,
                        ),
                    ],
                  ),
                  onTap: _pickDate,
                ),
              ),
            ),
          ),
        ),

        const SizedBox(height: 12),

        // 结果区
        Expanded(
          child: _loading
              ? const Center(child: MoeLoadingIndicator())
              : (_error != null)
                  ? MoeEmptyState(
                      icon: Icons.error_outline,
                      title: '搜索失败',
                      description: _error!,
                    )
                  : (keyword.isEmpty && date == null)
                      ? const MoeEmptyState(
                          icon: Icons.search,
                          title: '请输入关键词或选择日期',
                        )
                      : (_results.isEmpty)
                          ? const MoeEmptyState(
                              icon: Icons.search_off,
                              title: '未找到匹配的聊天记录',
                            )
                          : Column(
                              children: [
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                      16, 0, 16, 8),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          '共 ${_results.length} 条（最多显示 200 条）',
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: colors.muted,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Expanded(
                                  child: ListView.separated(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 8,
                                    ),
                                    itemCount: _results.length,
                                    separatorBuilder: (_, __) =>
                                        const SizedBox(height: 8),
                                    itemBuilder: (context, index) {
                                      final m = _results[index];
                                      final time = DateTime
                                          .fromMillisecondsSinceEpoch(
                                              m.createdAt);
                                      final roleLabel =
                                          m.role == 'user' ? '我' : 'TA';
                                      final text = m.content.trim().isEmpty
                                          ? '[非文本消息]'
                                          : m.content.trim();

                                      return Container(
                                        padding: const EdgeInsets.all(12),
                                        decoration: MoeG2Decoration(
                                          radius: 8,
                                          color: colors.surfaceAlt,
                                          border: Border.all(
                                            color: colors.borderLight,
                                            width: borderWidth,
                                          ),
                                        ),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Row(
                                              children: [
                                                Container(
                                                  padding: const EdgeInsets
                                                      .symmetric(
                                                      horizontal: 8,
                                                      vertical: 2),
                                                  decoration: MoeG2Decoration(
                                                    radius: 999,
                                                    color: colors.muted.withValues(alpha: 0.12),
                                                  ),
                                                  child: Text(
                                                    roleLabel,
                                                    style: TextStyle(
                                                      fontSize: 12,
                                                      color: colors.text,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                    ),
                                                  ),
                                                ),
                                                const SizedBox(width: 8),
                                                Expanded(
                                                  child: Text(
                                                    _formatTime(time),
                                                    style: TextStyle(
                                                      fontSize: 12,
                                                      color: colors.muted,
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 8),
                                            Text(
                                              text,
                                              maxLines: 3,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: 13,
                                                color: colors.text,
                                                height: 1.35,
                                              ),
                                            ),
                                          ],
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ],
                            ),
        ),
      ],
    );
  }
}
