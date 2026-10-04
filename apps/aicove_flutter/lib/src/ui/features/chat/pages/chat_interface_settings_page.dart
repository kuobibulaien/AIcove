import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/utils/data_image.dart';
import '../../../../features/chat/application/chat_page_conversation_actions.dart';
import '../../../../features/chat/conversation_providers.dart';
import '../../../../features/chat/domain/conversation.dart';
import '../../../../features/chat/domain/message.dart';
import '../../../../features/chat/presentation/widgets/message_bubble.dart';
import '../../../../features/settings/app_settings.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';
import '../widgets/chat_wallpaper_background.dart';

const Duration _kDeferredPreviewWindow = Duration(milliseconds: 420);
const double _kDefaultMaskOpacity = 0.8;
const double _kDefaultBlurSigma = 0.0;

/// 聊天菜单「聊天界面」：上方用真实消息气泡预览当前会话效果，
/// 下方高级材质面板分「壁纸」「行为」两个标签页。
class ChatInterfaceSettingsPage extends ConsumerStatefulWidget {
  const ChatInterfaceSettingsPage({super.key, required this.conversation});

  final Conversation conversation;

  @override
  ConsumerState<ChatInterfaceSettingsPage> createState() =>
      _ChatInterfaceSettingsPageState();
}

class _ChatInterfaceSettingsPageState
    extends ConsumerState<ChatInterfaceSettingsPage>
    with MoeAutoSaveState<ChatInterfaceSettingsPage> {
  String? _backgroundImage;
  late double _maskOpacity;
  late double _blurSigma;
  int _tab = 0;
  Timer? _deferredPreviewTimer;
  bool _deferHeavyPreview = true;

  @override
  void initState() {
    super.initState();
    final raw = widget.conversation.chatBackgroundImage?.trim();
    _backgroundImage = raw == null || raw.isEmpty ? null : raw;
    _maskOpacity =
        (widget.conversation.chatBackgroundMaskOpacity ?? _kDefaultMaskOpacity)
            .clamp(0.0, 1.0);
    _blurSigma =
        (widget.conversation.chatBackgroundBlurSigma ?? _kDefaultBlurSigma)
            .clamp(0.0, 30.0);
    // 转场期间不解码壁纸，先用底色占位，避免进入页面掉帧。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _deferredPreviewTimer = Timer(_kDeferredPreviewWindow, () {
        if (mounted) setState(() => _deferHeavyPreview = false);
      });
    });
    autoSave.configure(
      save: _save,
      snapshot: () =>
          moeAutoSaveSignature([_backgroundImage, _maskOpacity, _blurSigma]),
    );
  }

  @override
  void dispose() {
    _deferredPreviewTimer?.cancel();
    super.dispose();
  }

  bool get _hasBackground =>
      _backgroundImage != null && _backgroundImage!.trim().isNotEmpty;

  Future<void> _pickBackgroundImage() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
    );
    if (!mounted || picked == null || picked.files.isEmpty) return;
    final file = picked.files.first;
    final bytes = file.bytes;
    if (bytes == null || bytes.isEmpty) return;
    setState(
      () => _backgroundImage = buildDataImage(bytes, fileName: file.name),
    );
  }

  void _resetWallpaper() {
    setState(() {
      _backgroundImage = null;
      _maskOpacity = _kDefaultMaskOpacity;
      _blurSigma = _kDefaultBlurSigma;
    });
  }

  Future<void> _save() async {
    final raw = _backgroundImage?.trim();
    final hasBackground = raw != null && raw.isNotEmpty;
    await ref
        .read(chatPageConversationActionsProvider)
        .applyConversationEdits(
          widget.conversation.id,
          chatBackgroundImage: hasBackground ? raw : null,
          clearChatBackgroundImage: !hasBackground,
          chatBackgroundMaskOpacity: hasBackground ? _maskOpacity : null,
          clearChatBackgroundMaskOpacity: !hasBackground,
          chatBackgroundBlurSigma: hasBackground ? _blurSigma : null,
          clearChatBackgroundBlurSigma: !hasBackground,
        );
  }

  @override
  Widget build(BuildContext context) {
    final conv =
        ref.watch(resolvedConversationByIdProvider(widget.conversation.id)) ??
        widget.conversation;
    final settings = ref.watch(appSettingsProvider).valueOrNull;
    final globalStyle = settings?.chatDisplayStyle ?? ChatDisplayStyle.bubble;
    final style = conv.chatDisplayStyle ?? globalStyle;
    final fallbackColor = resolveChatBackgroundColor(
      context,
      settings?.lightChatBackground,
    );

    return autoSavePage(
      MoePageScaffold(
        extendBodyBehindAppBar: true,
        backgroundColor: Colors.transparent,
        appBar: const MoeAppBar(title: '聊天界面', showBackButton: true),
        body: MoeWorkspaceBackground(
          background: ChatWallpaperLayer(
            key: const ValueKey('chat_interface_wallpaper'),
            image: _deferHeavyPreview ? null : _backgroundImage,
            fallbackColor: fallbackColor,
            maskOpacity: _maskOpacity,
            blurSigma: _blurSigma,
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
              MoeSegTabBar(
                currentIndex: _tab,
                tabs: const ['壁纸', '行为'],
                onTap: (index) => setState(() => _tab = index),
              ),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxContentHeight),
                child: SingleChildScrollView(
                  key: ValueKey('chat_interface_tab_$_tab'),
                  child: _tab == 0
                      ? _buildWallpaperTab(context, conv)
                      : _buildBehaviorTab(settings),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildWallpaperTab(BuildContext context, Conversation conv) {
    final colors = context.moeColors;
    final styleChoice = conv.chatDisplayStyle?.name ?? 'follow';
    // 每项一行，面板尽量矮，把高度留给上方的消息预览。
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: MoeSecondaryButton(
                  label: _hasBackground ? '更换图片' : '选择背景图片',
                  size: MoeSecondaryButtonSize.sm,
                  onPressed: _pickBackgroundImage,
                ),
              ),
              if (_hasBackground) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: MoeSecondaryButton(
                    label: '清除',
                    size: MoeSecondaryButtonSize.sm,
                    onPressed: () => setState(() => _backgroundImage = null),
                  ),
                ),
              ],
              IconButton(
                tooltip: '恢复默认壁纸',
                onPressed: _resetWallpaper,
                icon: Icon(
                  Icons.restore,
                  size: 20,
                  color: colors.textSecondary,
                ),
              ),
            ],
          ),
          _sliderRow(
            colors,
            label: '遮罩',
            value: _maskOpacity,
            display: '${(_maskOpacity * 100).round()}%',
            divisions: 20,
            onChanged: (v) => setState(() => _maskOpacity = v),
          ),
          _sliderRow(
            colors,
            label: '模糊',
            value: _blurSigma,
            max: 30,
            display: '${_blurSigma.round()}',
            divisions: 30,
            onChanged: (v) => setState(() => _blurSigma = v),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              SizedBox(width: 40, child: _label(colors, '样式')),
              Expanded(
                child: MoeToggleBar<String>(
                  key: const ValueKey('chat_interface_style_toggle'),
                  value: styleChoice,
                  items: [
                    MoeToggleItem(value: 'follow', label: '默认'),
                    const MoeToggleItem(value: 'bubble', label: '气泡'),
                    const MoeToggleItem(value: 'document', label: '文档'),
                  ],
                  onChanged: (value) => ref
                      .read(conversationsProvider.notifier)
                      .setConversationChatDisplayStyle(
                        conv.id,
                        ChatDisplayStyle.fromValue(value),
                      ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }

  Widget _sliderRow(
    MoeColors colors, {
    required String label,
    required double value,
    required String display,
    required int divisions,
    required ValueChanged<double> onChanged,
    double max = 1.0,
  }) {
    return Row(
      children: [
        SizedBox(width: 40, child: _label(colors, label)),
        Expanded(
          child: MoeSlider(
            value: value,
            max: max,
            divisions: divisions,
            onChanged: _hasBackground ? onChanged : null,
          ),
        ),
        SizedBox(
          width: 40,
          child: Text(
            display,
            textAlign: TextAlign.end,
            style: TextStyle(fontSize: 12, color: colors.textSecondary),
          ),
        ),
      ],
    );
  }

  Widget _buildBehaviorTab(AppSettings? settings) {
    return MoeSettingsRow(
      key: const ValueKey('auto_scroll_on_send_switch'),
      label: '发送消息自动回底',
      subtitle: '对所有会话生效；关闭后发送消息时保持当前阅读位置',
      trailingType: MoeSettingsRowTrailing.switchControl,
      switchValue: settings?.autoScrollOnSend ?? true,
      onSwitchChanged: (value) =>
          ref.read(appSettingsProvider.notifier).setAutoScrollOnSend(value),
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

/// 示例对话：直接用聊天页的 [MessageBubble] 渲染，样式与壁纸调整即时可见。
class _MessagePreview extends StatelessWidget {
  const _MessagePreview({
    required this.conversation,
    required this.documentStyle,
    required this.topInset,
  });

  final Conversation conversation;
  final bool documentStyle;
  final double topInset;

  static final _time = DateTime(2026, 1, 1, 21, 30);
  static final _samples = <Message>[
    Message(
      id: 'preview_user_1',
      role: 'user',
      content: '今天好累呀，想听你说说话',
      createdAt: _time,
    ),
    Message(
      id: 'preview_ai_1',
      role: 'assistant',
      content: '辛苦啦。先坐下来喝口水，我在这儿陪着你。',
      createdAt: _time,
    ),
    Message(
      id: 'preview_ai_2',
      role: 'assistant',
      content: '想从哪件事聊起都可以，慢慢说就好～',
      createdAt: _time,
    ),
    Message(
      id: 'preview_user_2',
      role: 'user',
      content: '嗯，那我先说说今天上班的事',
      createdAt: _time,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final avatar = conversation.avatarUrl ?? conversation.characterImage;
    return IgnorePointer(
      child: ClipRect(
        child: SingleChildScrollView(
          key: const ValueKey('chat_interface_preview'),
          reverse: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.fromLTRB(8, topInset + 12, 8, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < _samples.length; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: MessageBubble(
                    message: _samples[i],
                    isMe: _samples[i].role == 'user',
                    avatarUrl: _samples[i].role == 'user' ? null : avatar,
                    displayName: conversation.displayName,
                    showName: false,
                    // 同一发送方连续消息只在最后一条显示头像与尾角。
                    showAvatar: _isLastOfRun(i),
                    showCorner: _isLastOfRun(i),
                    documentStyle: documentStyle,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  static bool _isLastOfRun(int index) =>
      index == _samples.length - 1 ||
      _samples[index + 1].role != _samples[index].role;
}
