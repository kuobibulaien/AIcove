import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/chat/application/chat_page_conversation_actions.dart';
import '../../../../features/chat/conversation_providers.dart';
import '../../../../features/chat/domain/conversation.dart';
import '../../../../features/settings/app_settings.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';
import '../../wallpaper/pages/wallpaper_editor_page.dart';
import '../../wallpaper/widgets/wallpaper_preview_samples.dart';
import '../widgets/chat_wallpaper_background.dart';

const Duration _kDeferredPreviewWindow = Duration(milliseconds: 420);

/// 聊天菜单「聊天界面」：上方用真实消息气泡预览当前会话效果，
/// 下方高级材质面板分「界面」「行为」两个标签页；壁纸的图片、遮罩、模糊与截取
/// 在与全局壁纸共用的 [WallpaperEditorPage] 里调，样式下的「更多选项」
/// 只列当前样式（气泡或文档）的细节。
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
  bool _styleOptionsExpanded = false;
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
    final fallbackColor = resolveChatBackgroundColor(
      context,
      settings?.lightChatBackground,
    );

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
              child: _MessagePreview(
                conversation: conv,
                documentStyle: style == ChatDisplayStyle.document,
                topInset: MediaQuery.paddingOf(context).top,
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
    final maxContentHeight = MediaQuery.sizeOf(context).height * 0.3;
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
    final colors = context.moeColors;
    final style = conv.effectiveDisplayStyle ??
        settings?.chatDisplayStyle ??
        ChatDisplayStyle.bubble;
    final hasImage = conv.chatBackgroundImage?.trim().isNotEmpty ?? false;
    // 每项一行，面板尽量矮，把高度留给上方的消息预览。
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SizedBox(width: 40, child: _label(colors, '壁纸')),
              Expanded(
                child: Text(
                  hasImage ? '专属壁纸' : '跟随全局壁纸',
                  style: TextStyle(fontSize: 13, color: colors.textSecondary),
                ),
              ),
              MoeSecondaryButton(
                key: const ValueKey('chat_interface_edit_wallpaper'),
                label: hasImage ? '编辑壁纸' : '设置专属壁纸',
                size: MoeSecondaryButtonSize.sm,
                onPressed: () => _editWallpaper(conv),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              SizedBox(width: 40, child: _label(colors, '样式')),
              Expanded(
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
            ],
          ),
          const SizedBox(height: 4),
          _buildStyleOptionsHeader(colors, style),
          if (_styleOptionsExpanded && settings != null)
            ..._buildStyleOptions(style, settings),
          const SizedBox(height: 6),
        ],
      ),
    );
  }

  Widget _buildStyleOptionsHeader(MoeColors colors, ChatDisplayStyle style) {
    final styleName = style == ChatDisplayStyle.document ? '文档' : '气泡';
    return InkWell(
      key: const ValueKey('chat_interface_style_options'),
      borderRadius: BorderRadius.circular(8),
      onTap: () =>
          setState(() => _styleOptionsExpanded = !_styleOptionsExpanded),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            const SizedBox(width: 40),
            Expanded(
              child: Text(
                '$styleName样式更多选项',
                style: TextStyle(fontSize: 13, color: colors.textSecondary),
              ),
            ),
            AnimatedRotation(
              turns: _styleOptionsExpanded ? 0.25 : 0,
              duration: const Duration(milliseconds: 160),
              child: Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: colors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 当前样式的细节开关，所有聊天共用。
  List<Widget> _buildStyleOptions(
    ChatDisplayStyle style,
    AppSettings settings,
  ) {
    final notifier = ref.read(appSettingsProvider.notifier);
    if (style == ChatDisplayStyle.document) {
      return [
        MoeSettingsRow(
          key: const ValueKey('document_show_thinking_switch'),
          label: '显示思维链',
          subtitle: '收在折叠段里，点开查看',
          trailingType: MoeSettingsRowTrailing.switchControl,
          switchValue: settings.documentShowThinking,
          onSwitchChanged: notifier.setDocumentShowThinking,
        ),
        MoeSettingsRow(
          key: const ValueKey('document_show_tool_calls_switch'),
          label: '显示工具调用',
          subtitle: '工具名、参数和结果，收在折叠段里',
          trailingType: MoeSettingsRowTrailing.switchControl,
          switchValue: settings.documentShowToolCalls,
          onSwitchChanged: notifier.setDocumentShowToolCalls,
        ),
      ];
    }
    final format = settings.messageFormatConfig;
    return [
      MoeSettingsRow(
        key: const ValueKey('bubble_chunking_switch'),
        label: '消息分段',
        subtitle: '长回复拆成多条气泡',
        trailingType: MoeSettingsRowTrailing.switchControl,
        switchValue: format.enableChunking,
        onSwitchChanged: (value) => notifier.updateMessageFormatConfig(
          format.copyWith(enableChunking: value),
        ),
      ),
      MoeSettingsRow(
        key: const ValueKey('bubble_filter_punctuation_switch'),
        label: '过滤句末标点',
        trailingType: MoeSettingsRowTrailing.switchControl,
        switchValue: format.filterPunctuation,
        onSwitchChanged: (value) => notifier.updateMessageFormatConfig(
          format.copyWith(filterPunctuation: value),
        ),
      ),
      MoeSettingsRow(
        key: const ValueKey('bubble_show_thinking_switch'),
        label: '显示思维链',
        subtitle: '单独成一个折叠气泡',
        trailingType: MoeSettingsRowTrailing.switchControl,
        switchValue: settings.bubbleShowThinking,
        onSwitchChanged: notifier.setBubbleShowThinking,
      ),
    ];
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
      ],
    );
  }

  Widget _label(MoeColors colors, String text) => Text(
    text,
    style: TextStyle(
      fontSize: 13,
      fontWeight: MoeFontWeights.emphasis,
      color: colors.text,
    ),
  );
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
