import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/models/block_status.dart';
import '../../../../core/models/message_block.dart';
import '../../../../core/utils/message_formatter.dart';
import '../../../../features/chat/domain/message.dart';
import '../../../../features/chat/presentation/widgets/message_bubble.dart';
import '../../../../features/settings/app_settings.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';
import '../../chat/widgets/chat_message_list_items.dart';
import '../../chat/widgets/chat_wallpaper_background.dart';
import '../widgets/chunk_punctuation_sheet.dart';

/// 面板里的开关行：与滑块行同一左边距和字号，不画分隔线。
const EdgeInsets _kCompactRowPadding = EdgeInsets.symmetric(vertical: 6);
const TextStyle _kCompactRowLabel = TextStyle(fontSize: 13);

/// 通用设置 · 聊天界面：上方用真实消息气泡预览所有聊天的默认效果，下方面板分
/// 「大小」「样式」「其他」三页。这里改的是全局值，单个聊天在聊天菜单的
/// 「聊天界面」里另设过的项不受影响。
class ChatUiSettingsPage extends ConsumerStatefulWidget {
  const ChatUiSettingsPage({
    super.key,
    this.initialTab = ChatUiSettingsTab.size,
  });

  /// 打开时停在哪一页；聊天菜单的「聊天界面」跳过来时直接落到对应子项。
  final ChatUiSettingsTab initialTab;

  @override
  ConsumerState<ChatUiSettingsPage> createState() => _ChatUiSettingsPageState();
}

/// 面板三页，顺序即标签顺序。
enum ChatUiSettingsTab { size, style, other }

class _ChatUiSettingsPageState extends ConsumerState<ChatUiSettingsPage> {
  late int _tab = widget.initialTab.index;

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(appSettingsProvider).valueOrNull;
    final style = settings?.chatDisplayStyle ?? ChatDisplayStyle.bubble;

    return MoePageScaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Colors.transparent,
      appBar: const MoeAppBar(title: '聊天界面', showBackButton: true),
      body: MoeWorkspaceBackground(
        background: ChatWallpaperLayer.forConversation(
          key: const ValueKey('chat_ui_settings_wallpaper'),
          conversation: null,
          fallbackColor: resolveChatBackgroundColor(context),
        ),
        child: Column(
          children: [
            Expanded(
              child: settings == null
                  ? const SizedBox.shrink()
                  : _SettingsPreview(
                      settings: settings,
                      documentStyle: style == ChatDisplayStyle.document,
                      topInset: MediaQuery.paddingOf(context).top,
                    ),
            ),
            _buildPanel(context, settings),
          ],
        ),
      ),
    );
  }

  Widget _buildPanel(BuildContext context, AppSettings? settings) {
    final maxContentHeight = MediaQuery.sizeOf(context).height * 0.34;
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: MoeSettingsContent(
        child: MoeFloatingSurface(
          key: const ValueKey('chat_ui_settings_panel'),
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
                  MoeSegment(value: 0, label: '大小'),
                  MoeSegment(value: 1, label: '样式'),
                  MoeSegment(value: 2, label: '其他'),
                ],
                onChanged: (index) => setState(() => _tab = index),
              ),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxContentHeight),
                child: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
                    child: settings == null
                        ? const SizedBox.shrink()
                        // 三页叠放，面板高度固定取最高的一页；最后一层是
                        // 样式页最满的情形（气泡＋分段子项），只占高度不显示。
                        : IndexedStack(
                            index: _tab,
                            children: [
                              _buildSizeTab(settings),
                              _buildStyleTab(context, settings),
                              _buildOtherTab(settings),
                              ExcludeSemantics(
                                child: IgnorePointer(
                                  child: _buildStyleTab(
                                    context,
                                    settings,
                                    sizing: true,
                                  ),
                                ),
                              ),
                            ],
                          ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSizeTab(AppSettings settings) {
    final notifier = ref.read(appSettingsProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ScaleRow(
          key: const ValueKey('chat_ui_text_scale'),
          label: '字体',
          value: settings.textScaleFactor,
          min: kMinTextScaleFactor,
          max: kMaxTextScaleFactor,
          divisions: 8, // 0.05 步长：(1.2-0.8)/0.05 = 8
          inputTitle: '输入字体大小',
          onChanged: notifier.setTextScaleFactor,
        ),
        _ScaleRow(
          key: const ValueKey('chat_ui_ui_scale'),
          label: '界面',
          value: settings.uiScaleFactor,
          min: kMinUiScaleFactor,
          max: kMaxUiScaleFactor,
          divisions: 6, // 0.05 步长：(1.15-0.85)/0.05 = 6
          inputTitle: '输入界面缩放',
          onChanged: notifier.setUiScaleFactor,
        ),
        _ScaleRow(
          key: const ValueKey('chat_ui_image_scale'),
          label: '图片',
          value: settings.imagePreviewScale,
          min: kMinImagePreviewScale,
          max: kMaxImagePreviewScale,
          divisions: 20, // 0.05 步长：(1.5-0.5)/0.05 = 20
          inputTitle: '输入图片大小',
          onChanged: notifier.setImagePreviewScale,
        ),
      ],
    );
  }

  /// 新会话默认样式，下面紧跟当前样式自己的子项。
  Widget _buildStyleTab(
    BuildContext context,
    AppSettings settings, {
    bool sizing = false,
  }) {
    final colors = context.moeColors;
    final notifier = ref.read(appSettingsProvider.notifier);
    final chunkConfig = settings.messageFormatConfig;
    final isDocument =
        !sizing && settings.chatDisplayStyle == ChatDisplayStyle.document;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            _label(colors, '默认样式'),
            const SizedBox(width: 12),
            Expanded(
              child: MoeSegmentedControl<ChatDisplayStyle>(
                key: const ValueKey('chat_display_style_toggle'),
                value: settings.chatDisplayStyle,
                segments: const [
                  MoeSegment(value: ChatDisplayStyle.bubble, label: '气泡'),
                  MoeSegment(value: ChatDisplayStyle.document, label: '文档'),
                ],
                onChanged: notifier.setChatDisplayStyle,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        if (isDocument)
          _compactSwitch(
            key: const ValueKey('default_document_show_tool_calls_switch'),
            label: '显示工具调用',
            value: settings.documentShowToolCalls,
            onChanged: notifier.setDocumentShowToolCalls,
          )
        else ...[
          _compactSwitch(
            key: const ValueKey('default_chunking_switch'),
            label: '消息分段',
            value: chunkConfig.enableChunking,
            onChanged: (value) => notifier.updateMessageFormatConfig(
              chunkConfig.copyWith(enableChunking: value),
            ),
          ),
          if (sizing || chunkConfig.enableChunking)
            Padding(
              padding: const EdgeInsets.only(left: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  MoeSettingsRow(
                    key: const ValueKey('chunk_punctuation_set_row'),
                    contentPadding: _kCompactRowPadding,
                    labelStyle: _kCompactRowLabel,
                    showDivider: false,
                    label: '分段标点',
                    trailingType: MoeSettingsRowTrailing.text,
                    detailText: _activeSetName(chunkConfig),
                    onTap: () => showChunkPunctuationSheet(context),
                  ),
                  _compactSwitch(
                    key: const ValueKey('filter_punctuation_switch'),
                    label: '省略句末标点',
                    value: chunkConfig.filterPunctuation,
                    onChanged: (value) => notifier.updateMessageFormatConfig(
                      chunkConfig.copyWith(filterPunctuation: value),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ],
    );
  }

  /// 两种样式共用的显示项；思维链一个开关同时管气泡和文档。
  Widget _buildOtherTab(AppSettings settings) {
    final notifier = ref.read(appSettingsProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _compactSwitch(
          key: const ValueKey('default_expand_audio_switch'),
          label: '语音消息默认展开文字',
          value: settings.expandAudioText,
          onChanged: notifier.setExpandAudioText,
        ),
        _compactSwitch(
          key: const ValueKey('default_show_thinking_switch'),
          label: '显示思维链',
          value: settings.bubbleShowThinking && settings.documentShowThinking,
          onChanged: (value) async {
            await notifier.setBubbleShowThinking(value);
            await notifier.setDocumentShowThinking(value);
          },
        ),
        _compactSwitch(
          key: const ValueKey('default_hide_user_avatar_switch'),
          label: '隐藏用户头像',
          value: settings.hideUserAvatar,
          onChanged: notifier.setHideUserAvatar,
        ),
        _compactSwitch(
          key: const ValueKey('single_avatar_per_turn_switch'),
          label: '单轮聊天只显示一次头像',
          value: settings.singleAvatarPerTurn,
          onChanged: notifier.setSingleAvatarPerTurn,
        ),
      ],
    );
  }

  Widget _compactSwitch({
    required Key key,
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return MoeSettingsRow(
      key: key,
      contentPadding: _kCompactRowPadding,
      labelStyle: _kCompactRowLabel,
      showDivider: false,
      label: label,
      trailingType: MoeSettingsRowTrailing.switchControl,
      switchValue: value,
      onSwitchChanged: onChanged,
    );
  }

  String _activeSetName(MessageFormatConfig config) {
    final set = config.activeChunkPunctuationSet;
    if (set == null) return '';
    return chunkPunctuationSetName(
      set,
      config.chunkPunctuationSets.indexOf(set),
    );
  }
}

Widget _label(MoeColors colors, String text) => Text(
  text,
  style: TextStyle(
    fontSize: 13,
    fontWeight: MoeFontWeights.emphasis,
    color: colors.text,
  ),
);

/// 一行滑块：左侧名称，右侧数值，点数值可以直接输入。
class _ScaleRow extends StatelessWidget {
  const _ScaleRow({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.inputTitle,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String inputTitle;
  final Future<void> Function(double) onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final current = value.clamp(min, max).toDouble();
    return Row(
      children: [
        SizedBox(width: 40, child: _label(colors, label)),
        Expanded(
          child: MoeSlider(
            value: current,
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ),
        GestureDetector(
          onTap: () => _showInput(context, current),
          child: MoeButtonSurface(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            radius: 6,
            tintColor: colors.accentColor.withValues(alpha: 0.15),
            child: Text(
              current.toStringAsFixed(2),
              style: TextStyle(
                fontSize: 12,
                fontWeight: MoeFontWeights.emphasis,
                color: colors.accentColor,
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _showInput(BuildContext context, double current) {
    showMoeAutoSaveTextEditor(
      context: context,
      title: inputTitle,
      initialValue: current.toStringAsFixed(2),
      hint: '范围 $min ~ $max',
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      onSave: (text) async {
        final parsed = double.tryParse(text);
        if (parsed == null ||
            !parsed.isFinite ||
            parsed < min ||
            parsed > max) {
          throw const FormatException('请输入范围内的数值');
        }
        await onChanged(parsed);
      },
    );
  }
}

/// 示例对话：走聊天页同一条分段与折叠投影，用 [MessageBubble] 渲染；
/// 图片、语音、思维链、工具调用和分段各有一条，面板里每项改动都看得到。
class _SettingsPreview extends StatelessWidget {
  const _SettingsPreview({
    required this.settings,
    required this.documentStyle,
    required this.topInset,
  });

  final AppSettings settings;
  final bool documentStyle;
  final double topInset;

  static const _avatar = 'assets/characters/images/aicove_assistant.png';

  static final _time = DateTime(2026, 4, 2, 15, 20);

  static final _messages = <Message>[
    Message(
      id: 'chat_ui_preview_user_text',
      role: 'user',
      content: '今天去看樱花啦，给你看看',
      createdAt: _time,
    ),
    Message(
      id: 'chat_ui_preview_user_image',
      role: 'user',
      content: '',
      blocks: [
        ImageBlock(
          messageId: 'chat_ui_preview_user_image',
          localPath: 'assets/wallpapers/sakura_light.webp',
          width: 1536,
          height: 896,
          status: BlockStatus.success,
        ),
      ],
      createdAt: _time,
    ),
    Message(
      id: 'chat_ui_preview_ai_reply',
      role: 'assistant',
      content: '',
      blocks: [
        ThinkingBlock(
          messageId: 'chat_ui_preview_ai_reply',
          content: '她分享了樱花照片，心情很好。先夸照片，再看看这周的天气。',
          status: BlockStatus.success,
        ),
        ToolBlock(
          messageId: 'chat_ui_preview_ai_reply',
          toolName: 'web_search',
          arguments: const {'query': '这周樱花花期 天气'},
          result: const {'summary': '周末晴，花期还有一周左右'},
          status: BlockStatus.success,
        ),
        TextBlock(
          messageId: 'chat_ui_preview_ai_reply',
          content: '哇，拍得真好看！花开得正是时候。\n我查了一下，周末还是晴天，下次也带上我吧。',
        ),
      ],
      createdAt: _time,
    ),
    Message(
      id: 'chat_ui_preview_ai_voice',
      role: 'assistant',
      content: '',
      blocks: [
        AudioBlock(
          messageId: 'chat_ui_preview_ai_voice',
          // 示例语音不会播放；空地址会被当成还在生成，显示加载圈。
          url: 'preview://chat-ui-voice',
          status: BlockStatus.success,
          text: '傍晚风大，记得多穿一件外套哦。',
          durationSeconds: 4,
        ),
      ],
      createdAt: _time,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final items = buildChatMessageListItems(
      messages: _messages,
      config: settings.messageFormatConfig,
      showTimeDividers: false,
      showThinkingFolds: documentStyle
          ? settings.documentShowThinking
          : settings.bubbleShowThinking,
      showToolCallFolds: documentStyle && settings.documentShowToolCalls,
    );
    return IgnorePointer(
      child: ClipRect(
        child: SingleChildScrollView(
          key: const ValueKey('chat_ui_settings_preview'),
          reverse: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.fromLTRB(8, topInset + 12, 8, 12),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final item in items)
                if (_bubble(item) case final bubble?)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: bubble,
                  ),
            ],
          ),
        ),
      ),
    );
  }

  Widget? _bubble(ChatMessageListItem item) {
    final (message, showAvatar, showCorner) = switch (item) {
      ChatMessageItem() => (item.message, item.showAvatar, item.showCorner),
      ChatChunkedMessageItem() => (
        chatChunkDisplayMessage(item),
        item.showAvatar,
        item.showCorner,
      ),
      _ => (null, false, false),
    };
    if (message == null) return null;
    return MessageBubble(
      message: message,
      isMe: message.role == 'user',
      avatarUrl: message.role == 'user' ? null : _avatar,
      showName: false,
      showAvatar: showAvatar,
      showCorner: showCorner,
      documentStyle: documentStyle,
    );
  }
}
