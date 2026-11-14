import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/chat/application/chat_page_conversation_actions.dart';
import '../../../../features/chat/application/chat_view_prefs.dart';
import '../../../../features/chat/conversation_providers.dart';
import '../../../../features/chat/domain/conversation.dart';
import '../../../../features/settings/app_settings.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';
import '../../settings/pages/chat_ui_settings_page.dart';
import '../../wallpaper/pages/wallpaper_editor_page.dart';
import '../../wallpaper/widgets/wallpaper_preview_samples.dart';
import '../widgets/chat_wallpaper_background.dart';

const Duration _kDeferredPreviewWindow = Duration(milliseconds: 420);

/// 聊天菜单「聊天界面」：上方用真实消息气泡预览当前会话效果，
/// 下方高级材质面板分「界面」「行为」两个标签页。「界面」三项同高：消息样式只对
/// 这个联系人生效；壁纸的图片、遮罩、模糊与截取在与全局壁纸共用的
/// [WallpaperEditorPage] 里调；更多选项的箭头跳到 [ChatUiSettingsPage] 的
/// 「其他」子项改全局值。
class ChatInterfaceSettingsPage extends ConsumerStatefulWidget {
  const ChatInterfaceSettingsPage({super.key, required this.conversation});

  final Conversation conversation;

  @override
  ConsumerState<ChatInterfaceSettingsPage> createState() =>
      _ChatInterfaceSettingsPageState();
}

class _ChatInterfaceSettingsPageState
    extends ConsumerState<ChatInterfaceSettingsPage> {
  int _tab = 0;
  Timer? _deferredPreviewTimer;
  bool _deferHeavyPreview = true;

  @override
  void initState() {
    super.initState();
    // 转场期间不解码壁纸，先用底色占位，避免进入页面掉帧。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _deferredPreviewTimer = Timer(_kDeferredPreviewWindow, () {
        if (mounted) setState(() => _deferHeavyPreview = false);
      });
    });
  }

  @override
  void dispose() {
    _deferredPreviewTimer?.cancel();
    super.dispose();
  }

  void _editWallpaper(Conversation conv) {
    MoeWorkspace.open(
      context,
      WallpaperEditorPage(
        source: conv.chatBackgroundImage,
        style: resolveChatWallpaperStyle(context, conv),
        defaultStyle: kDefaultChatWallpaperStyle,
        followStyle: MoeWallpaperTheme.maybeOf(context)?.style,
        kind: WallpaperPreviewKind.chat,
        conversation: conv,
        canChangeImage: true,
        onSave: (source, style) => _saveWallpaper(conv.id, source, style),
      ),
    );
  }

  Future<void> _saveWallpaper(
    String id,
    String? source,
    WallpaperStyle? style,
  ) {
    final hasImage = source != null && source.trim().isNotEmpty;
    final framing = style?.encodedFraming;
    return ref
        .read(chatPageConversationActionsProvider)
        .applyConversationEdits(
          id,
          chatBackgroundImage: hasImage ? source.trim() : null,
          clearChatBackgroundImage: !hasImage,
          chatBackgroundMaskOpacity: style?.mask,
          clearChatBackgroundMaskOpacity: style == null,
          chatBackgroundBlurSigma: style?.blur,
          clearChatBackgroundBlurSigma: style == null,
          chatBackgroundFraming: framing,
          clearChatBackgroundFraming: framing == null,
        );
  }

  @override
  Widget build(BuildContext context) {
    final conv =
        ref.watch(resolvedConversationByIdProvider(widget.conversation.id)) ??
        widget.conversation;
    final settings = ref.watch(appSettingsProvider).valueOrNull;
    final globalStyle = settings?.chatDisplayStyle ?? ChatDisplayStyle.bubble;
    final style = conv.effectiveDisplayStyle ?? globalStyle;
    final fallbackColor = resolveChatBackgroundColor(context);

    return MoePageScaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Colors.transparent,
      appBar: const MoeAppBar(title: '聊天界面', showBackButton: true),
      body: MoeWorkspaceBackground(
        background: ChatWallpaperLayer.forConversation(
          key: const ValueKey('chat_interface_wallpaper'),
          conversation: _deferHeavyPreview
              ? conv.copyWith(chatBackgroundImage: null)
              : conv,
          fallbackColor: fallbackColor,
        ),
        child: Column(
          children: [
            Expanded(
              child: ChatViewScope(
                prefs: ChatViewPrefs.resolve(conv, settings),
                child: _MessagePreview(
                  conversation: conv,
                  documentStyle: style == ChatDisplayStyle.document,
                  topInset: MediaQuery.paddingOf(context).top,
                ),
              ),
            ),
            _buildPanel(context, conv, settings),
          ],
        ),
      ),
    );
  }

  Widget _buildPanel(
    BuildContext context,
    Conversation conv,
    AppSettings? settings,
  ) {
    final maxContentHeight = MediaQuery.sizeOf(context).height * 0.34;
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: MoeSettingsContent(
        child: MoeFloatingSurface(
          key: const ValueKey('chat_interface_panel'),
          radius: 24,
          baseline: MoeMaterialBaseline.background,
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              MoeSegmentedControl<int>(
                value: _tab,
                segments: const [
                  MoeSegment(value: 0, label: '界面'),
                  MoeSegment(value: 1, label: '行为'),
                ],
                onChanged: (index) => setState(() => _tab = index),
              ),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxContentHeight),
                child: SingleChildScrollView(
                  key: ValueKey('chat_interface_tab_$_tab'),
                  child: _tab == 0
                      ? _buildInterfaceTab(context, conv, settings)
                      : _buildBehaviorTab(settings),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInterfaceTab(
    BuildContext context,
    Conversation conv,
    AppSettings? settings,
  ) {
    final style =
        conv.effectiveDisplayStyle ??
        settings?.chatDisplayStyle ??
        ChatDisplayStyle.bubble;
    // 三项同高；更多选项的箭头跳到通用设置的「其他」子项。
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _PanelRow(
            label: '消息样式',
            child: MoeSegmentedControl<ChatDisplayStyle>(
              key: const ValueKey('chat_interface_style_toggle'),
              value: style,
              segments: const [
                MoeSegment(value: ChatDisplayStyle.bubble, label: '气泡'),
                MoeSegment(value: ChatDisplayStyle.document, label: '文档'),
              ],
              onChanged: (value) => ref
                  .read(conversationsProvider.notifier)
                  .setConversationChatDisplayStyle(conv.id, value),
            ),
          ),
          _PanelRow(
            key: const ValueKey('chat_interface_edit_wallpaper'),
            label: '壁纸',
            onTap: () => _editWallpaper(conv),
          ),
          _PanelRow(
            key: const ValueKey('chat_interface_more_options'),
            label: '更多选项',
            onTap: () => _openChatUiSettings(ChatUiSettingsTab.other),
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  void _openChatUiSettings(ChatUiSettingsTab tab) {
    MoeWorkspace.open(context, ChatUiSettingsPage(initialTab: tab));
  }

  Widget _buildBehaviorTab(AppSettings? settings) {
    final notifier = ref.read(appSettingsProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MoeSettingsRow(
          key: const ValueKey('auto_scroll_on_send_switch'),
          label: '用户发消息自动回底',
          subtitle: '自己发出消息后回到最新处',
          trailingType: MoeSettingsRowTrailing.switchControl,
          switchValue: settings?.autoScrollOnSend ?? true,
          onSwitchChanged: notifier.setAutoScrollOnSend,
        ),
        MoeSettingsRow(
          key: const ValueKey('auto_scroll_on_ai_reply_switch'),
          label: 'AI 发消息自动回底',
          subtitle: '停在底部时跟着 AI 的回复往下滚',
          trailingType: MoeSettingsRowTrailing.switchControl,
          switchValue: settings?.autoScrollOnAiReply ?? true,
          onSwitchChanged: notifier.setAutoScrollOnAiReply,
        ),
        MoeSettingsRow(
          key: const ValueKey('allow_multi_message_send_switch'),
          label: '允许单次发送多条消息',
          subtitle: '点发送先暂存，点确认再让 AI 回复',
          trailingType: MoeSettingsRowTrailing.switchControl,
          switchValue: settings?.allowMultiMessageSend ?? false,
          onSwitchChanged: notifier.setAllowMultiMessageSend,
        ),
      ],
    );
  }
}

/// 「界面」页的一行：左侧名称，中间可放控件，可点时右侧带跳转箭头。
class _PanelRow extends StatelessWidget {
  const _PanelRow({super.key, required this.label, this.child, this.onTap});

  static const double height = 48;

  final String label;
  final Widget? child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final row = SizedBox(
      height: height,
      child: Row(
        children: [
          SizedBox(
            width: 64,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: MoeFontWeights.emphasis,
                color: colors.text,
              ),
            ),
          ),
          Expanded(child: child ?? const SizedBox.shrink()),
          if (onTap != null)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: colors.textSecondary,
              ),
            ),
        ],
      ),
    );
    if (onTap == null) return row;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: row,
    );
  }
}

/// 示例对话：与壁纸编辑页共用 [WallpaperSampleMessages]，样式调整即时可见。
class _MessagePreview extends StatelessWidget {
  const _MessagePreview({
    required this.conversation,
    required this.documentStyle,
    required this.topInset,
  });

  final Conversation conversation;
  final bool documentStyle;
  final double topInset;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ClipRect(
        child: SingleChildScrollView(
          key: const ValueKey('chat_interface_preview'),
          reverse: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.fromLTRB(8, topInset + 12, 8, 12),
          child: WallpaperSampleMessages(
            conversation: conversation,
            documentStyle: documentStyle,
          ),
        ),
      ),
    );
  }
}
