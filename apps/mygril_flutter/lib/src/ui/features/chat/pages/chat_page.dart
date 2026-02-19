import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
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
import 'chat_background_settings_page.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/animations/parallax_slide_page_route.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../features/settings/app_settings.dart';
import '../../../../core/database/database.dart' as db;
import '../../../../core/database/database_provider.dart';
import '../../../../core/database/converters/database_converters.dart';
import '../../../../core/models/message_block.dart';
import '../../../../core/utils/data_image.dart';
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
  /// 鍒嗛〉鍔犺浇鐘舵€?
  bool _isLoadingMore = false;

  /// 鏄惁杩樻湁鏇村鍘嗗彶娑堟伅
  bool _hasMoreMessages = true;

  /// 宸查鍔犺浇杩囩殑浼氳瘽 ID锛岄伩鍏嶉噸澶嶉鍔犺浇
  String? _preloadedConversationId;
  bool _didSchedulePrecache = false;

  @override
  void initState() {
    super.initState();
    // 杩涘叆鑱婂ぉ椤垫椂灏芥棭鎶?activeConversationId 璁剧疆鍒颁綅锛岄伩鍏嶉甯у厛娓叉煋鍒?榛樿浼氳瘽"閫犳垚闂烦/鍗￠】
    final targetId = widget.conversationId;
    if (targetId == null) return;
    final activeId = ref.read(activeConversationIdProvider);
    if (activeId != targetId) {
      ref.read(activeConversationIdProvider.notifier).state = targetId;
    }
    // 娓呴櫎璇ヤ細璇濈殑鏈璁℃暟
    ref.read(conversationsProvider.notifier).clearUnread(targetId);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 涓嶈鍦?didChangeDependencies 閲岀洿鎺ヨ窇澶ч噺棰勭紦瀛橈細
    // 杩欓噷澶勪簬鈥滆矾鐢卞垰鍒囨崲銆佽浆鍦哄姩鐢昏寮€濮嬧€濈殑鍏抽敭璺緞锛屼换浣曞悓姝ュ惊鐜?IO 閮藉彲鑳藉鑷粹€滅偣鍑诲悗鍏堥】涓€涓嬧€濄€?
    // 棰勭紦瀛樻斁鍒伴甯т箣鍚庡悗鍙拌繘琛岋紙涓嶉樆濉炲姩鐢伙級锛岄伩鍏嶅崱椤匡紱鍥剧墖鏄惁闂儊涓昏闈犫€滆繘鍏ュ墠棰勭儹/缂撳瓨鍛戒腑鈥濊В鍐炽€?
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

  /// 瑙﹀彂鍥剧墖棰勫姞杞?
  void _triggerImagePreload() {
    final targetId = widget.conversationId;
    if (targetId == null || targetId == _preloadedConversationId) {
      // 瀹藉睆鍐呭祵 ChatPage锛坈onversationId==null锛変笉璧伴缂撳瓨锛涘悓浼氳瘽鍙缂撳瓨涓€娆?
      return;
    }

    // 鑾峰彇浼氳瘽鏁版嵁
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

  /// 棰勫姞杞戒細璇濅腑鐨勫浘鐗囷紙鍚庡彴棰勭儹锛屼笉闃诲杞満/棣栧抚锛?
  Future<void> _preloadImages(Conversation conv) async {
    if (_preloadedConversationId == conv.id) return;

    try {
      const maxMessagesToScan = 10; // 鍙壂棣栧睆闄勮繎鐨勬秷鎭紝閬垮厤涓€娆℃€ф壂鎻忚繃澶?blocks
      const maxImagesToCache = 24; // 鎺у埗棰勭紦瀛樹笂闄愶紝閬垮厤 ImageCache/瑙ｇ爜鍘嬪姏杩囧ぇ

      final providers = <ImageProvider>[];

      // 1. 棰勭紦瀛樺ご鍍?
      final avatarUrl = conv.avatarUrl ?? conv.characterImage;
      if (avatarUrl != null && avatarUrl.isNotEmpty) {
        final provider = _getImageProvider(avatarUrl);
        if (provider != null) {
          providers.add(provider);
        }
      }

      // 2. 棰勭紦瀛橀灞忔秷鎭腑鐨勫浘鐗?琛ㄦ儏
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
      // 棰勫姞杞藉け璐ヤ笉褰卞搷姝ｅ父娴佺▼
    }
  }

  /// 鏍规嵁 URL 鑾峰彇瀵瑰簲鐨?ImageProvider
  ImageProvider? _getImageProvider(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return null;

    // data:image/...;base64,... 鍙兘寰堝ぇ锛岄缂撳瓨浼氬紩鍏ラ澶栧悓姝?decode 鎴愭湰锛岃繖閲岄€夋嫨璺宠繃锛堜笉闃诲棣栧抚锛夈€?
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
      // 鏈湴鏂囦欢锛堥伩鍏?existsSync 鍚屾 IO锛屼氦缁?ImageProvider 鑷繁澶勭悊澶辫触鎯呭喌锛?
      return FileImage(File(trimmed));
    }
  }

  /// 鏍规嵁 MessageBlock 鑾峰彇瀵瑰簲鐨?ImageProvider
  ImageProvider? _getBlockImageProvider(MessageBlock block) {
    if (block is ImageBlock) {
      // base64 鍥剧墖棰勭紦瀛樹細甯︽潵鍚屾瑙ｇ爜寮€閿€锛堝疄闄呮覆鏌撴椂宸叉湁鍏滃簳锛夛紝杩欓噷璺宠繃閬垮厤褰卞搷鍔ㄧ敾娴佺晠搴?
      if (block.base64 != null && block.base64!.isNotEmpty) return null;

      // 缃戠粶鍥剧墖
      if (block.url != null && block.url!.isNotEmpty) {
        return CachedNetworkImageProvider(block.url!);
      }
      // 鏈湴鍥剧墖
      if (block.localPath != null && block.localPath!.isNotEmpty) {
        // 閬垮厤 existsSync 鍚屾 IO
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

  Widget _buildConversationBackground({
    required Conversation? conv,
    required Color fallbackColor,
    required Widget child,
  }) {
    final raw = conv?.chatBackgroundImage?.trim();
    if (raw == null || raw.isEmpty) {
      return Container(color: fallbackColor, child: child);
    }

    final image = _buildBackgroundImage(raw);
    if (image == null) {
      return Container(color: fallbackColor, child: child);
    }
    final maskOpacity =
        (conv?.chatBackgroundMaskOpacity ?? 0.8).clamp(0.0, 1.0);
    final topMaskOpacity = (maskOpacity + 0.12).clamp(0.0, 1.0);
    final blurSigma =
        (conv?.chatBackgroundBlurSigma ?? 0.0).clamp(0.0, 30.0);

    final Widget bgImage = blurSigma > 0.1
        ? ImageFiltered(
            imageFilter: ui.ImageFilter.blur(
              sigmaX: blurSigma,
              sigmaY: blurSigma,
              tileMode: TileMode.decal,
            ),
            child: image,
          )
        : image;

    return Container(
      color: fallbackColor,
      child: Stack(
        fit: StackFit.expand,
        children: [
          bgImage,
          IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    fallbackColor.withValues(alpha: topMaskOpacity),
                    fallbackColor.withValues(
                        alpha: (maskOpacity * 0.9).clamp(0.0, 1.0)),
                    fallbackColor.withValues(alpha: maskOpacity),
                  ],
                ),
              ),
            ),
          ),
          child,
        ],
      ),
    );
  }

  Widget? _buildBackgroundImage(String raw) {
    final bytes = decodeDataImage(raw);
    if (bytes != null) {
      return Image.memory(
        bytes,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
      );
    }

    final provider = _getImageProvider(raw);
    if (provider == null) return null;
    return Image(
      image: provider,
      fit: BoxFit.cover,
      gaplessPlayback: true,
      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
    );
  }

  @override
  void didUpdateWidget(covariant ChatPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 濡傛灉 conversationId 鍙樺寲锛屾洿鏂?provider 骞堕噸缃垎椤电姸鎬?
    final targetId = widget.conversationId;
    if (targetId != oldWidget.conversationId && targetId != null) {
      ref.read(activeConversationIdProvider.notifier).state = targetId;
      // 鍒囨崲浼氳瘽鏃堕噸缃垎椤电姸鎬?
      setState(() {
        _hasMoreMessages = true;
        _isLoadingMore = false;
      });
      _scheduleImagePrecache();
      // 娓呴櫎鏂颁細璇濈殑鏈璁℃暟
      ref.read(conversationsProvider.notifier).clearUnread(targetId);
    }
  }

  /// 鍔犺浇鏇村鍘嗗彶娑堟伅锛堝垎椤靛姞杞斤級
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

      // 鑾峰彇褰撳墠鏈€鏃ф秷鎭殑鏃堕棿
      final oldestMessage = conv.messages.first;
      final oldestTime = oldestMessage.createdAt.millisecondsSinceEpoch;

      // 浠庢暟鎹簱鍔犺浇鏇存棭鐨勬秷鎭?
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

      // 鎵归噺鑾峰彇 blocks
      final messageIds = dbMsgs.map((m) => m.id).toList();
      final dbBlocks = await blockRepo.getByMessages(messageIds);

      // 鎸?messageId 鍒嗙粍
      final blocksByMsgId = <String, List<MessageBlock>>{};
      for (final dbBlock in dbBlocks) {
        final block = MessageBlockConverter.fromDb(dbBlock);
        if (block != null) {
          blocksByMsgId.putIfAbsent(dbBlock.messageId, () => []).add(block);
        }
      }

      // 缁勮娑堟伅锛坮eversed: 鏁版嵁搴撹繑鍥?desc锛孶I 闇€瑕?asc锛?
      final olderMessages = dbMsgs.reversed.map((dbMsg) {
        final blocks = blocksByMsgId[dbMsg.id];
        return MessageConverter.fromDb(dbMsg, blocks: blocks);
      }).toList();

      // 鏇存柊浼氳瘽锛屾妸鏇存棫鐨勬秷鎭彃鍏ュ埌澶撮儴
      await ref.read(conversationsProvider.notifier).updateOne(
            conv.id,
            (c) => c.copyWith(messages: [...olderMessages, ...c.messages]),
          );

      // 濡傛灉鍔犺浇鐨勬秷鎭皯浜?0鏉★紝璇存槑娌℃湁鏇村浜?
      if (dbMsgs.length < 30) {
        setState(() => _hasMoreMessages = false);
      }
    } catch (e) {
      debugPrint('鍔犺浇鏇村娑堟伅澶辫触: $e');
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
    // 娉ㄦ剰锛氱Щ闄や簡 sendingProvider 鐨?watch锛屾敼鍦?_ChatAppBarTitle 涓眬閮ㄧ洃鍚?
    // 杩欐牱鍙戦€佺姸鎬佸彉鍖栨椂鍙噸寤烘爣棰橈紝涓嶄細褰卞搷 Composer 杈撳叆妗?
    final actions = ref.read(chatActionsProvider); // 鏀圭敤 read锛宎ctions 涓嶄細鍙?
    final sidebarVisible = ref.watch(sidebarVisibleProvider);
    final settingsAsync = ref.watch(appSettingsProvider);
    final colors = context.moeColors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final chatBgColor = settingsAsync.maybeWhen(
      data: (settings) {
        if (isDark) return colors.bgMain;
        // 榛樿鑹茶窡闅忓叏灞€鑳屾櫙鑹?
        return settings.chatBackgroundColor.color ?? colors.surface;
      },
      orElse: () => isDark ? colors.bgMain : colors.surface,
    );
    final hasCustomBackground =
        (conv?.chatBackgroundImage?.trim().isNotEmpty ?? false);
    final extendBehindAppBar = hasCustomBackground;
    final listTopSpacing = extendBehindAppBar
        ? MediaQuery.paddingOf(context).top + kToolbarHeight
        : 0.0;

    return Scaffold(
      // 鐢辫緭鍏ョ粍浠惰嚜宸辩鐞嗏€滈敭鐩?鏇村闈㈡澘鈥濆崰浣嶄笌浣嶇Щ锛岄伩鍏?Scaffold 鑷姩鎸ゅ帇甯冨眬閫犳垚璺冲姩
      resizeToAvoidBottomInset: false,
      extendBodyBehindAppBar: extendBehindAppBar,
      appBar: AppBar(
        backgroundColor:
            hasCustomBackground ? Colors.transparent : colors.headerColor,
        foregroundColor: colors.headerContentColor,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: TextStyle(
          fontSize: 22, // 璇︽儏椤垫爣棰樼◢寰皬涓€鐐?
          fontWeight: MoeFontWeights.emphasis,
          color: colors.headerContentColor,
          letterSpacing: 0.8,
        ),
        bottom: hasCustomBackground
            ? null
            : PreferredSize(
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
            return Text(sending ? '瀵规柟杈撳叆涓?..' : (conv?.displayName ?? '鑱婂ぉ'));
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
              tooltip: '鏇村',
              onPressed: () async {
                await showChatSettingsDialog(
                  context: context,
                  conversation: conv,
                  onSearchMessages: () {
                    showMoeBottomSheet(
                      context: context,
                      title: '鏌ユ壘鑱婂ぉ璁板綍',
                      showCloseButton: true,
                      maxHeight: MediaQuery.sizeOf(context).height * 0.85,
                      builder: (context) =>
                          _ChatMessageSearchContent(conversation: conv),
                    );
                  },
                  onEditContact: () async {
                    // 缂栬緫瑙掕壊椤甸潰锛堣宸粦鍔ㄥ姩鐢伙級
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
                            clearAvatarUrl: result.clearAvatarUrl,
                            characterImage: result.characterImage,
                            clearCharacterImage: result.clearCharacterImage,
                            chatBackgroundImage: result.chatBackgroundImage,
                            clearChatBackgroundImage:
                                result.clearChatBackgroundImage,
                            clearChatBackgroundMaskOpacity:
                                result.clearChatBackgroundImage,
                            selfAddress: result.selfAddress,
                            clearSelfAddress: result.clearSelfAddress,
                            addressUser: result.addressUser,
                            clearAddressUser: result.clearAddressUser,
                            voiceFile: result.voiceFile,
                            clearVoiceFile: result.clearVoiceFile,
                            description: result.description,
                            clearDescription: result.clearDescription,
                            personaPrompt: result.personaPrompt,
                            enabledPlugins: result.enabledPlugins,
                            clearEnabledPlugins: result.clearEnabledPlugins,
                          );
                      if (!context.mounted) return;
                      MoeToast.brief(context, 'Character saved');
                    }
                  },
                  onChatBackgroundSettings: (result) async {
                    await ref
                        .read(conversationsProvider.notifier)
                        .applyContactEdit(
                          conv.id,
                          chatBackgroundImage: result.backgroundImage,
                          clearChatBackgroundImage: result.clearBackgroundImage,
                          chatBackgroundMaskOpacity: result.maskOpacity,
                          clearChatBackgroundMaskOpacity:
                              result.clearMaskOpacity,
                          chatBackgroundBlurSigma: result.blurSigma,
                          clearChatBackgroundBlurSigma: result.clearBlurSigma,
                        );
                    if (!context.mounted) return;
                    MoeToast.brief(context, 'Chat background updated');
                  },
                  onPinnedChanged: (value) async {
                    await ref
                        .read(conversationsProvider.notifier)
                        .updateConversationSettings(
                          conv.id,
                          isPinned: value,
                        );
                    if (!context.mounted) return;
                    MoeToast.brief(
                      context,
                      value ? 'Pinned' : 'Unpinned',
                    );
                  },
                  onMutedChanged: (value) async {
                    await ref
                        .read(conversationsProvider.notifier)
                        .updateConversationSettings(
                          conv.id,
                          isMuted: value,
                        );
                    if (!context.mounted) return;
                    MoeToast.brief(context, value ? '宸插紑鍚厤鎵撴壈' : '宸插叧闂厤鎵撴壈');
                  },
                  onNotificationSoundChanged: (value) async {
                    await ref
                        .read(conversationsProvider.notifier)
                        .updateConversationSettings(
                          conv.id,
                          notificationSound: value,
                        );
                    if (!context.mounted) return;
                    MoeToast.brief(context, value ? '宸插紑鍚彁绀洪煶' : '宸插叧闂彁绀洪煶');
                  },
                  onClearMessages: () async {
                    await ref
                        .read(conversationsProvider.notifier)
                        .clearMessages(conv.id);
                    if (!context.mounted) return;
                    MoeToast.brief(context, 'Chat history cleared');
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
                    MoeToast.brief(context, 'Plugin settings updated');
                  },
                );
              },
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: _buildConversationBackground(
        conv: conv,
        fallbackColor: chatBgColor,
        child: Column(
          children: [
            if (listTopSpacing > 0) SizedBox(height: listTopSpacing),
            // 閿欒淇℃伅涓嶅啀鏄剧ず鍦║I涓紝閬垮厤褰卞搷鑱婂ぉ浣撻獙
            // 濡傞渶璋冭瘯锛屽彲浠ュ湪鎺у埗鍙版煡鐪媏rror鐘舵€?
            // 鍔犺浇鐘舵€侀€氳繃AppBar鐨?瀵规柟杈撳叆涓?.."鍜屾秷鎭皵娉＄姸鎬佹樉绀?
            Expanded(
              child: conv == null
                  ? const Center(child: CircularProgressIndicator())
                  : GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onTap: () {
                        final keyboardHeight =
                            MediaQuery.viewInsetsOf(context).bottom;
                        // 閿洏鏄剧ず涓細鍙殣钘忛敭鐩樹絾涓嶇珛鍒讳涪鐒︾偣锛岃杈撳叆妗嗚窡鐫€閿洏鍔ㄧ敾涓€璧峰洖鏀讹紙閬垮厤琚敭鐩樼洊浣忥級
                        if (keyboardHeight > 0) {
                          SystemChannels.textInput
                              .invokeMethod('TextInput.hide');
                          return;
                        }
                        // 閿洏鏈樉绀猴細涓㈢劍鐐圭敤浜庡叧闂€滄洿澶氶潰鏉库€濓紙鏇村闈㈡澘浼氫繚鎸佷竴涓彧璇荤劍鐐癸級
                        FocusManager.instance.primaryFocus?.unfocus();
                      },
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
                            ref.read(editingTextProvider.notifier).state = text;
                          }
                        },
                        onRegenerateMessage: (message) {
                          if (ref.read(sendingProvider)) {
                            MoeToast.brief(
                              context,
                              'Please wait for current message to finish',
                            );
                            return;
                          }
                          actions.regenerate(message.id);
                        },
                      ),
                    ),
            ),
            // 杈撳叆鏍忎娇鐢ㄥ唴閮?SafeArea 澶勭悊绯荤粺灏忕櫧鏉★紝閿洏閫傞厤鍚庣画鍗曠嫭璇勪及
            Composer(
              disabled: false, // 绉婚櫎绂佺敤閫昏緫锛屽厑璁哥敤鎴烽殢鏃惰緭鍏?
              onSend: (text) {
                // 濡傛灉姝ｅ湪鍙戦€侊紝涓嶅鐞嗘柊娑堟伅锛堝湪鍥炶皟鏃舵鏌ワ紝閬垮厤閲嶅缓锛?
                if (ref.read(sendingProvider)) {
                  MoeToast.brief(
                    context,
                    'Please wait for current message to finish',
                  );
                  return;
                }
                // 妫€鏌ユ槸鍚︽湁寮曠敤娑堟伅
                final quoted = ref.read(quotedMessageProvider);
                if (quoted != null) {
                  // 甯﹀紩鐢ㄥ彂閫?
                  final quotedText = quoted.content.length > 30
                      ? '${quoted.content.substring(0, 30)}...'
                      : quoted.content;
                  final quotedPrefix = '> Quote: $quotedText\n\n';
                  actions.send(quotedPrefix + text);
                  ref.read(quotedMessageProvider.notifier).state = null;
                } else {
                  actions.send(text);
                }
              },
              onImageSelected: (imagePath) {
                // 濡傛灉姝ｅ湪鍙戦€侊紝涓嶅鐞嗘柊鍥剧墖
                if (ref.read(sendingProvider)) {
                  MoeToast.brief(
                    context,
                    'Please wait for current message to finish',
                  );
                  return;
                }
                actions.sendWithImage(imagePath);
              },
              onFileSelected: (filePath) {
                // 濡傛灉姝ｅ湪鍙戦€侊紝涓嶅鐞嗘柊鏂囦欢
                if (ref.read(sendingProvider)) {
                  MoeToast.brief(
                    context,
                    'Please wait for current message to finish',
                  );
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

    // 涓や釜鏉′欢閮芥病濉椂锛屼笉鍋氣€滃叏搴撴悳绱⑩€濓紝閬垮厤涓€涓嬪瓙鍒峰嚭澶璁板綍銆?
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
        // 鍏抽敭璇嶆悳绱㈡
        Padding(
          padding: const EdgeInsets.all(16),
          child: MoeTextField(
            controller: _searchCtrl,
            autofocus: true,
            hint: '杈撳叆鍏抽敭璇嶏紙鍙€夛級',
            prefixIcon: Icons.search,
            suffix: _searchCtrl.text.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.clear, size: 20),
                    onPressed: _clearKeyword,
                  )
                : null,
            borderColor: colors.borderLight,
            focusBorderColor: colors.primary,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            onChanged: (value) {
              setState(() => _keyword = value);
              _scheduleSearch();
            },
          ),
        ),

        // 鏃ユ湡绛涢€?
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
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
                  title: const Text('鏃ユ湡'),
                  subtitle: Text(date == null ? '鍏ㄩ儴' : _formatDay(date)),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: '閫夋嫨鏃ユ湡',
                        icon: const Icon(Icons.calendar_month, size: 20),
                        color: moePrimary,
                        onPressed: _pickDate,
                      ),
                      if (date != null)
                        IconButton(
                          tooltip: '娓呴櫎鏃ユ湡',
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

        // 缁撴灉鍖?
        Expanded(
          child: _loading
              ? const Center(child: MoeLoadingIndicator())
              : (_error != null)
                  ? MoeEmptyState(
                      icon: Icons.error_outline,
                      title: '鎼滅储澶辫触',
                      description: _error!,
                    )
                  : (keyword.isEmpty && date == null)
                      ? const MoeEmptyState(
                          icon: Icons.search,
                          title: '璇疯緭鍏ュ叧閿瘝鎴栭€夋嫨鏃ユ湡',
                        )
                      : (_results.isEmpty)
                          ? const MoeEmptyState(
                              icon: Icons.search_off,
                              title: '鏈壘鍒板尮閰嶇殑鑱婂ぉ璁板綍',
                            )
                          : Column(
                              children: [
                                Padding(
                                  padding:
                                      const EdgeInsets.fromLTRB(16, 0, 16, 8),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          '鍏?${_results.length} 鏉★紙鏈€澶氭樉绀?200 鏉★級',
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
                                      final time =
                                          DateTime.fromMillisecondsSinceEpoch(
                                              m.createdAt);
                                      final roleLabel =
                                          m.role == 'user' ? 'Me' : 'TA';
                                      final text = m.content.trim().isEmpty
                                          ? '[Non-text message]'
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
                                                    color: colors.muted
                                                        .withValues(
                                                            alpha: 0.12),
                                                  ),
                                                  child: Text(
                                                    roleLabel,
                                                    style: TextStyle(
                                                      fontSize: 12,
                                                      color: colors.text,
                                                      fontWeight: MoeFontWeights
                                                          .emphasis,
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
