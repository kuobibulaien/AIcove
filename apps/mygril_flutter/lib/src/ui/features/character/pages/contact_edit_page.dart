import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/utils/avatar_helper.dart';
import '../../../../core/utils/blurred_background_cache.dart';
import '../../../../core/utils/data_image.dart';
import '../../../../features/chat/domain/conversation.dart';
import '../../../../features/chat/presentation/widgets/contact_edit_dialog.dart';
import '../../../../features/chat/providers2.dart';
import '../../../../features/plugins/plugin_providers.dart';
import '../../../../features/plugins/tts/tts_config.dart';
import '../../../../features/settings/app_settings.dart';
import '../../../../ui/features/settings/pages/chat_plugin_settings_page.dart';
import '../widgets/character_text_editor_sheet.dart';
import '../../../../ui/shared/effects/frosted_glass_card.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/theme/tokens.dart';

/// 编辑模式枚举
/// 注释已清理乱码
/// - editTemplate: template/favorite role card edit mode
enum EditMode {
  create,
  editConversation,
  editTemplate,
}

enum _ExitAction {
  discard,
  save,
  cancel,
}

/// 注释已清理乱码
/// 注释已清理乱码
/// 注释已清理乱码
class ContactEditPage extends ConsumerStatefulWidget {
  final Conversation conversation;
  final EditMode editMode;

  /// 注释已清理乱码
  const ContactEditPage({
    super.key,
    required this.conversation,
    @Deprecated('Use editMode instead') bool isNew = false,
    EditMode? editMode,
  }) : editMode =
            editMode ?? (isNew ? EditMode.create : EditMode.editConversation);

  @override
  ConsumerState<ContactEditPage> createState() => _ContactEditPageState();
}

class _ContactEditPageState extends ConsumerState<ContactEditPage> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _descCtrl;
  late final TextEditingController _personaCtrl;
  late final TextEditingController _selfAddressCtrl;
  late final TextEditingController _addressUserCtrl;
  late final TextEditingController _avatarCtrl;
  late final TextEditingController _refImageCtrl;
  late final TextEditingController _chatBackgroundCtrl;

  Uint8List? _avatarBytes;
  Uint8List? _chatBackgroundBytes;
  late Set<String> _selectedPluginIds;
  String? _boundVoiceId;
  Timer? _autoSaveDebounce;
  bool _isAutoSaving = false;
  bool _autoSaveQueued = false;
  String? _lastAutoSavedSignature;
  bool _allowNativePop = false;

  bool get _enableAutoSave => false;
  List<TextEditingController> get _autoSaveControllers => [
        _nameCtrl,
        _descCtrl,
        _personaCtrl,
        _selfAddressCtrl,
        _addressUserCtrl,
        _chatBackgroundCtrl,
      ];

  @override
  void initState() {
    super.initState();
    final conv = widget.conversation;

    _nameCtrl = TextEditingController(text: conv.displayName);
    _descCtrl = TextEditingController(text: conv.description ?? '');
    _personaCtrl = TextEditingController(text: conv.personaPrompt);
    _selfAddressCtrl = TextEditingController(text: conv.selfAddress ?? '');
    _addressUserCtrl = TextEditingController(text: conv.addressUser ?? '');
    _avatarCtrl = TextEditingController(text: conv.avatarUrl ?? '');
    _refImageCtrl = TextEditingController(
      text: (conv.characterImage ?? ''),
    );
    _chatBackgroundCtrl = TextEditingController(
      text: conv.chatBackgroundImage ?? '',
    );

    if (_avatarCtrl.text.isNotEmpty) {
      _avatarBytes = decodeDataImage(_avatarCtrl.text);
    }
    if (_chatBackgroundCtrl.text.isNotEmpty) {
      _chatBackgroundBytes = decodeDataImage(_chatBackgroundCtrl.text);
    }

    final allPluginIds = chatPluginItems.map((e) => e.id).toSet();
    if (conv.enabledPlugins == null) {
      _selectedPluginIds = {...allPluginIds};
      // 新建角色时，默认不启用 TTS 插件（需用户手动绑定音色后才开启）
      if (widget.editMode == EditMode.create) {
        _selectedPluginIds.remove('tts');
      }
    } else {
      _selectedPluginIds = {...conv.enabledPlugins!};
    }

    final voice = conv.voiceFile?.trim();
    _boundVoiceId = (voice == null || voice.isEmpty) ? null : voice;

    if (_enableAutoSave) {
      for (final controller in _autoSaveControllers) {
        controller.addListener(_onAutoSaveFieldChanged);
      }
    }
    _lastAutoSavedSignature = _buildEditSignature(_buildEditResult());

    // 注释已清理乱码
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final provider = _getImageProvider();
      if (provider != null) {
        BlurredBackgroundCache.warm(
          widget.conversation.id,
          provider,
          context,
        );
      }
    });
  }

  @override
  void dispose() {
    _autoSaveDebounce?.cancel();
    if (_enableAutoSave) {
      for (final controller in _autoSaveControllers) {
        controller.removeListener(_onAutoSaveFieldChanged);
      }
    }
    _nameCtrl.dispose();
    _descCtrl.dispose();
    _personaCtrl.dispose();
    _selfAddressCtrl.dispose();
    _addressUserCtrl.dispose();
    _avatarCtrl.dispose();
    _refImageCtrl.dispose();
    _chatBackgroundCtrl.dispose();
    super.dispose();
  }

  /// 获取立绘 ImageProvider（用于背景模糊）
  ImageProvider? _getImageProvider() {
    final helper = AvatarHelper(
      avatarUrl:
          _avatarCtrl.text.trim().isEmpty ? null : _avatarCtrl.text.trim(),
      characterImage:
          _refImageCtrl.text.trim().isEmpty ? null : _refImageCtrl.text.trim(),
      displayName: _nameCtrl.text,
    );
    return helper.getCharacterProvider();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final voicePresets = ref.watch(ttsPluginConfigProvider).voicePresets;

    return PopScope(
      canPop: _allowNativePop,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await _handleBack();
      },
      child: Scaffold(
        backgroundColor: colors.surface,
        body: Stack(
          children: [
            // 1. 模糊背景（固定不动）
            Positioned.fill(
              child: _buildBlurredBackground(colors),
            ),

            // 2. 可滚动内容区
            Positioned.fill(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                child: Column(
                  children: [
                    // 注释已清理乱码

                    // 注释已清理乱码
                    SafeArea(
                      bottom: false,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: _buildNavBar(colors),
                      ),
                    ),

                    const SizedBox(height: 24),

                    // 头像 + 名称（一行显示）
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: _buildAvatarNameRow(colors),
                    ),
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: _buildCharacterImageSection(colors),
                    ),
                    const SizedBox(height: 16),

                    // Description section (readonly + edit entry)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: _buildReadonlySection(
                        colors,
                        icon: Icons.notes,
                        title: '角色描述',
                        content: _descCtrl.text,
                        placeholder: '暂无描述',
                        onEdit: () => _openFullScreenEditor(
                          title: '编辑描述',
                          controller: _descCtrl,
                          hint: '一句话介绍这个角色（可选）',
                        ),
                      ),
                    ),

                    const SizedBox(height: 16),

                    // 提示词（主要展示区，放大 + 内部可滑动）
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: _buildPromptSection(colors),
                    ),

                    const SizedBox(height: 16),

                    // 注释已清理乱码
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Column(
                        children: [
                          _buildBottomCard(colors, voicePresets),
                          const SizedBox(height: 16),
                          _buildChatBackgroundSection(colors),
                        ],
                      ),
                    ),

                    // 底部留白
                    const SizedBox(height: 48),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ==================== 模糊背景 ====================

  Widget _buildBlurredBackground(MoeColors colors) {
    final provider = _getImageProvider();
    if (provider == null) {
      return Container(color: colors.surface);
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Try prebuilt blurred asset first
    final charImage =
        _refImageCtrl.text.trim().isEmpty ? null : _refImageCtrl.text.trim();
    final blurAsset = _deriveBlurAssetPath(charImage);

    return Stack(
      fit: StackFit.expand,
      children: [
        Container(color: colors.surface),
        if (blurAsset != null)
          Image.asset(
            blurAsset,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            filterQuality: FilterQuality.medium,
            errorBuilder: (_, __, ___) => _buildGeneratedBlur(provider),
          )
        else
          _buildGeneratedBlur(provider),
        // 叠层提亮/压暗
        Container(
          color: isDark
              ? Colors.black.withValues(alpha: 0.25)
              : Colors.white.withValues(alpha: 0.22),
        ),
      ],
    );
  }

  String? _deriveBlurAssetPath(String? originalAssetPath) {
    if (originalAssetPath == null) return null;
    final trimmed = originalAssetPath.trim();
    if (!trimmed.startsWith('assets/')) return null;
    final dot = trimmed.lastIndexOf('.');
    if (dot <= 0) return null;
    return '${trimmed.substring(0, dot)}_blur${trimmed.substring(dot)}';
  }

  Widget _buildGeneratedBlur(ImageProvider provider) {
    return ValueListenableBuilder<int>(
      valueListenable: BlurredBackgroundCache.ticker,
      builder: (context, _, __) {
        final (bgProvider, isFallback) = BlurredBackgroundCache.getOrFallback(
          widget.conversation.id,
          provider,
        );

        final displayProvider = isFallback
            ? ResizeImage(
                bgProvider,
                width: 96,
                height: 96,
                policy: ResizeImagePolicy.fit,
              )
            : bgProvider;

        final baseImage = Image(
          image: displayProvider,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          filterQuality: isFallback ? FilterQuality.none : FilterQuality.medium,
        );

        if (isFallback) {
          return Transform.scale(scale: 1.2, child: baseImage);
        }
        return baseImage;
      },
    );
  }

  // ==================== 自动保存 ====================

  void _onAutoSaveFieldChanged() {
    _scheduleAutoSave();
  }

  void _scheduleAutoSave() {
    if (!_enableAutoSave) return;
    _autoSaveDebounce?.cancel();
    _autoSaveDebounce = Timer(const Duration(milliseconds: 450), () {
      unawaited(_saveCurrentIfNeeded());
    });
  }

  Future<void> _flushAutoSave() async {
    if (!_enableAutoSave) return;
    _autoSaveDebounce?.cancel();
    while (_isAutoSaving) {
      _autoSaveQueued = true;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await _saveCurrentIfNeeded();
  }

  String _buildEditSignature(ContactEditResult result) {
    final plugins = result.enabledPlugins?.join(',') ?? '__all__';
    return [
      result.displayName,
      result.avatarUrl ?? '',
      result.characterImage ?? '',
      result.chatBackgroundImage ?? '',
      result.selfAddress ?? '',
      result.addressUser ?? '',
      result.voiceFile ?? '',
      result.description ?? '',
      result.personaPrompt,
      plugins,
      '${result.clearAvatarUrl}',
      '${result.clearCharacterImage}',
      '${result.clearChatBackgroundImage}',
      '${result.clearSelfAddress}',
      '${result.clearAddressUser}',
      '${result.clearVoiceFile}',
      '${result.clearDescription}',
      '${result.clearEnabledPlugins}',
    ].join('|');
  }

  Future<void> _saveCurrentIfNeeded() async {
    if (!_enableAutoSave || !mounted) return;
    final result = _buildEditResult();
    if (result.displayName.trim().isEmpty) return;

    final signature = _buildEditSignature(result);
    if (signature == _lastAutoSavedSignature) return;

    if (_isAutoSaving) {
      _autoSaveQueued = true;
      return;
    }

    _isAutoSaving = true;
    try {
      await _applyResult(widget.conversation.id, result);
      _lastAutoSavedSignature = signature;
    } finally {
      _isAutoSaving = false;
      if (_autoSaveQueued) {
        _autoSaveQueued = false;
        unawaited(_saveCurrentIfNeeded());
      }
    }
  }

  // 注释已清理乱码

  Widget _buildNavBar(MoeColors colors) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          // 注释已清理乱码
          _buildCircleButton(
            icon: Icons.arrow_back,
            onTap: () => unawaited(_handleBack()),
          ),
          const Spacer(),
          // 注释已清理乱码
          ..._buildNavActions(colors),
        ],
      ),
    );
  }

  List<Widget> _buildNavActions(MoeColors colors) {
    switch (widget.editMode) {
      case EditMode.create:
        return [
          _buildCircleButton(
            icon: Icons.check,
            onTap: _onSave,
          ),
        ];
      case EditMode.editConversation:
        return [
          _buildCircleButton(
            icon: Icons.more_horiz,
            onTap: () => _showMoreMenu(colors),
          ),
          const SizedBox(width: 8),
          _buildCircleButton(
            icon: Icons.check,
            onTap: _onSave,
          ),
        ];
      case EditMode.editTemplate:
        return [
          _buildCircleButton(
            icon: Icons.copy_outlined,
            onTap: _onSaveAsNewTemplate,
            tooltip: '另存为',
          ),
          const SizedBox(width: 8),
          _buildCircleButton(
            icon: Icons.check,
            onTap: _onSaveTemplate,
          ),
        ];
    }
  }

  void _showMoreMenu(MoeColors colors) {
    showMoeActionSheet(
      context: context,
      actions: [
        MoeSheetAction(
          label: '保存为新角色卡',
          icon: Icons.bookmark_add_outlined,
          onTap: _onSaveAsNewTemplate,
        ),
      ],
    );
  }

  Future<void> _handleBack() async {
    final action = await _confirmExitAction();
    if (!mounted || action == _ExitAction.cancel) return;

    if (action == _ExitAction.save) {
      await _saveCurrentAndExit();
      return;
    }

    _allowAndPop();
  }

  bool _hasUnsavedChanges() {
    final baseline = _lastAutoSavedSignature;
    if (baseline == null) return false;
    final current = _buildEditSignature(_buildEditResult());
    return current != baseline;
  }

  Future<_ExitAction> _confirmExitAction() async {
    if (!_hasUnsavedChanges()) return _ExitAction.discard;

    final result = await showMeoTalkDialog(
      context: context,
      title: '退出编辑',
      content: const Text('当前有未保存的修改，是否先保存？'),
      cancelText: '不保存',
      confirmText: '保存',
    );

    if (result == null) return _ExitAction.cancel;
    return result ? _ExitAction.save : _ExitAction.discard;
  }

  Future<void> _saveCurrentAndExit() async {
    switch (widget.editMode) {
      case EditMode.create:
      case EditMode.editConversation:
        await _onSave();
        return;
      case EditMode.editTemplate:
        await _onSaveTemplate();
        return;
    }
  }

  void _allowAndPop<T extends Object?>([T? result]) {
    if (!_allowNativePop) {
      setState(() {
        _allowNativePop = true;
      });
    }
    Navigator.of(context).pop<T>(result);
  }

  /// Circular translucent action button
  Widget _buildCircleButton({
    required IconData icon,
    required VoidCallback onTap,
    String? tooltip,
  }) {
    final button = Material(
      color: Colors.black38,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          width: 44,
          height: 44,
          alignment: Alignment.center,
          child: Icon(icon, color: Colors.white, size: 22),
        ),
      ),
    );
    if (tooltip != null) {
      return Tooltip(message: tooltip, child: button);
    }
    return button;
  }

  // 注释已清理乱码

  Widget _buildAvatarNameRow(MoeColors colors) {
    final helper = AvatarHelper(
      avatarUrl:
          _avatarCtrl.text.trim().isEmpty ? null : _avatarCtrl.text.trim(),
      characterImage:
          _refImageCtrl.text.trim().isEmpty ? null : _refImageCtrl.text.trim(),
      displayName: _nameCtrl.text,
    );

    // Avatar + name in one row
    return Row(
      children: [
        // 注释已清理乱码
        GestureDetector(
          onTap: _pickAvatarImage,
          child: Container(
            width: 72,
            height: 72,
            decoration: MoeG2Decoration(
              radius: radiusBubble.x,
              color: colors.surface,
              border: Border.all(color: colors.borderLight, width: 0.5),
            ),
            child: MoeG2ClipRRect(
              radius: radiusBubble.x,
              child: _avatarBytes != null
                  ? Image.memory(_avatarBytes!, fit: BoxFit.cover)
                  : helper.buildAvatarWidget(
                      fit: BoxFit.cover,
                      fallback: Center(
                        child: Icon(
                          Icons.add_a_photo_outlined,
                          color: colors.muted,
                          size: 28,
                        ),
                      ),
                    ),
            ),
          ),
        ),
        const SizedBox(width: 16),
        // Name field (left aligned, larger)
        Expanded(
          child: TextField(
            controller: _nameCtrl,
            style: TextStyle(
              fontSize: 20,
              fontWeight: MoeFontWeights.emphasis,
              color: colors.text,
            ),
            decoration: InputDecoration(
              hintText: '输入角色名称',
              hintStyle: TextStyle(
                fontSize: 20,
                fontWeight: MoeFontWeights.normal,
                color: colors.muted,
              ),
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCharacterImageSection(MoeColors colors) {
    final helper = AvatarHelper(
      avatarUrl:
          _avatarCtrl.text.trim().isEmpty ? null : _avatarCtrl.text.trim(),
      characterImage:
          _refImageCtrl.text.trim().isEmpty ? null : _refImageCtrl.text.trim(),
      displayName: _nameCtrl.text,
    );
    final hasCharacterImage = _refImageCtrl.text.trim().isNotEmpty;

    return FrostedGlassContainer(
      borderRadius: 16,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionTitle(
            colors,
            icon: Icons.portrait_outlined,
            title: '角色立绘',
            subtitle: '立绘用于角色卡和详情展示，不等同于头像',
          ),
          const SizedBox(height: 8),
          MoeG2ClipRRect(
            radius: 12,
            child: Container(
              width: double.infinity,
              height: 180,
              decoration: MoeG2Decoration(
                radius: 12,
                color: colors.surfaceAlt.withValues(alpha: 0.25),
                border: Border.all(color: colors.borderLight, width: 0.5),
              ),
              child: Center(
                child: AspectRatio(
                  aspectRatio: 3 / 4,
                  child: MoeG2ClipRRect(
                    radius: 10,
                    child: helper.buildCharacterWidget(
                      fit: BoxFit.cover,
                      fallback: Container(
                        color: colors.surface,
                        alignment: Alignment.center,
                        child: Icon(
                          Icons.image_outlined,
                          color: colors.muted,
                          size: 28,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _pickCharacterImage,
                  icon: const Icon(Icons.photo_library_outlined),
                  label: Text(hasCharacterImage ? '更换立绘' : '上传立绘'),
                ),
              ),
              if (hasCharacterImage) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _clearCharacterImage,
                    icon: const Icon(Icons.close),
                    label: const Text('清空立绘'),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildChatBackgroundSection(MoeColors colors) {
    final hasBackground = _chatBackgroundCtrl.text.trim().isNotEmpty;

    return FrostedGlassContainer(
      borderRadius: 16,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionTitle(
            colors,
            icon: Icons.image_outlined,
            title: '聊天背景',
            subtitle: '为当前会话设置单独背景图',
          ),
          const SizedBox(height: 8),
          if (hasBackground) ...[
            MoeG2ClipRRect(
              radius: 12,
              child: Container(
                width: double.infinity,
                height: 120,
                decoration: MoeG2Decoration(
                  radius: 12,
                  color: colors.surfaceAlt.withValues(alpha: 0.25),
                  border: Border.all(color: colors.borderLight, width: 0.5),
                ),
                child: _buildChatBackgroundPreview(colors),
              ),
            ),
            const SizedBox(height: 8),
          ],
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _pickChatBackgroundImage,
                  icon: const Icon(Icons.photo_library_outlined),
                  label: Text(hasBackground ? '更换背景' : '选择背景'),
                ),
              ),
              if (hasBackground) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _clearChatBackgroundImage,
                    icon: const Icon(Icons.close),
                    label: const Text('清除'),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildChatBackgroundPreview(MoeColors colors) {
    final raw = _chatBackgroundCtrl.text.trim();

    if (_chatBackgroundBytes != null) {
      return Image.memory(_chatBackgroundBytes!, fit: BoxFit.cover);
    }

    final bytes = decodeDataImage(raw);
    if (bytes != null) {
      return Image.memory(bytes, fit: BoxFit.cover);
    }

    if (raw.startsWith('http://') || raw.startsWith('https://')) {
      return Image.network(
        raw,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _buildChatBackgroundFallback(colors),
      );
    }

    if (raw.startsWith('assets/') || raw.startsWith('packages/')) {
      return Image.asset(
        raw,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _buildChatBackgroundFallback(colors),
      );
    }

    final file = File(raw);
    return Image.file(
      file,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => _buildChatBackgroundFallback(colors),
    );
  }

  Widget _buildChatBackgroundFallback(MoeColors colors) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.image_not_supported_outlined,
              size: 24, color: colors.muted),
          const SizedBox(height: 4),
          Text(
            '背景预览不可用',
            style: TextStyle(fontSize: 12, color: colors.muted),
          ),
        ],
      ),
    );
  }

  // ==================== 只读区块 + 编辑入口 ====================

  Widget _buildReadonlySection(
    MoeColors colors, {
    required IconData icon,
    required String title,
    required String content,
    required String placeholder,
    required VoidCallback onEdit,
  }) {
    final hasContent = content.trim().isNotEmpty;

    return FrostedGlassContainer(
      borderRadius: 16,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 注释已清理乱码
          Row(
            children: [
              Icon(icon, size: 18, color: colors.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: MoeFontWeights.emphasis,
                    color: colors.text,
                  ),
                ),
              ),
              // 注释已清理乱码
              GestureDetector(
                onTap: onEdit,
                child: Container(
                  width: 32,
                  height: 32,
                  decoration: MoeG2Decoration(
                    radius: 8,
                    color: colors.primary.withValues(alpha: 0.1),
                  ),
                  child: Icon(
                    Icons.edit_outlined,
                    size: 16,
                    color: colors.primary,
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 10),

          // 只读文本内容
          GestureDetector(
            onTap: onEdit,
            child: SizedBox(
              width: double.infinity,
              child: Text(
                hasContent ? content : placeholder,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.5,
                  color: hasContent
                      ? colors.text.withValues(alpha: 0.85)
                      : colors.muted,
                ),
                maxLines: 6,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ==================== 提示词主展示区（放大 + 可滑动）====================

  Widget _buildPromptSection(MoeColors colors) {
    final hasContent = _personaCtrl.text.trim().isNotEmpty;

    void openEditor() => _openFullScreenEditor(
          title: '编辑提示词',
          controller: _personaCtrl,
          hint: '详细描述角色的性格、说话方式、行为边界和世界观...',
        );

    return FrostedGlassContainer(
      borderRadius: 16,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 注释已清理乱码
          Row(
            children: [
              Icon(Icons.auto_awesome, size: 18, color: colors.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '提示词',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: MoeFontWeights.emphasis,
                    color: colors.text,
                  ),
                ),
              ),
              GestureDetector(
                onTap: openEditor,
                child: Container(
                  width: 32,
                  height: 32,
                  decoration: MoeG2Decoration(
                    radius: 8,
                    color: colors.primary.withValues(alpha: 0.1),
                  ),
                  child: Icon(
                    Icons.edit_outlined,
                    size: 16,
                    color: colors.primary,
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 10),

          // Scrollable prompt preview area
          GestureDetector(
            onTap: openEditor,
            child: Container(
              height: 320,
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: MoeG2Decoration(
                radius: 10,
                color: colors.surfaceAlt.withValues(alpha: 0.2),
              ),
              child: hasContent
                  ? Scrollbar(
                      child: SingleChildScrollView(
                        physics: const BouncingScrollPhysics(),
                        child: Text(
                          _personaCtrl.text,
                          style: TextStyle(
                            fontSize: 14,
                            height: 1.6,
                            color: colors.text.withValues(alpha: 0.85),
                          ),
                        ),
                      ),
                    )
                  : Center(
                      child: Text(
                        '暂无角色提示词',
                        style: TextStyle(
                          fontSize: 14,
                          color: colors.muted,
                        ),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  // ==================== 全屏编辑弹窗 ====================

  Future<void> _openFullScreenEditor({
    required String title,
    required TextEditingController controller,
    required String hint,
  }) async {
    final result = await showCharacterTextEditorSheet(
      context: context,
      title: title,
      initialValue: controller.text,
      hint: hint,
    );

    if (!mounted || result == null || result == controller.text) return;
    controller.text = result;
    setState(() {});
  }

  // 注释已清理乱码

  Widget _buildBottomCard(MoeColors colors, List<VoicePreset> voicePresets) {
    return FrostedGlassContainer(
      borderRadius: 16,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionTitle(
            colors,
            icon: Icons.extension_outlined,
            title: '插件',
            subtitle: '默认全部开启，可按角色单独调整',
          ),
          const SizedBox(height: 8),
          // 一行显示已选数量，点击弹出选择弹窗
          MoeG2ClipRRect(
            radius: 12,
            child: Material(
              color: colors.surfaceAlt.withValues(alpha: 0.35),
              child: InkWell(
                onTap: _showPluginPicker,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  child: Row(
                    children: [
                      Icon(Icons.extension_outlined,
                          color: colors.primary, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _pluginSummaryText(),
                          style: TextStyle(fontSize: 14, color: colors.text),
                        ),
                      ),
                      Icon(Icons.chevron_right, color: colors.muted),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Divider(height: 1, color: colors.borderLight.withValues(alpha: 0.35)),
          const SizedBox(height: 16),
          _buildSectionTitle(
            colors,
            icon: Icons.record_voice_over_outlined,
            title: '绑定音色',
            subtitle: '可为当前角色绑定独立音色',
          ),
          const SizedBox(height: 8),
          MoeG2ClipRRect(
            radius: 12,
            child: Material(
              color: colors.surfaceAlt.withValues(alpha: 0.35),
              child: InkWell(
                onTap: () => _showVoicePicker(voicePresets),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  child: Row(
                    children: [
                      Icon(Icons.graphic_eq, color: colors.primary, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _voiceDisplayName(voicePresets),
                          style: TextStyle(fontSize: 14, color: colors.text),
                        ),
                      ),
                      if (_boundVoiceId != null)
                        IconButton(
                          icon:
                              Icon(Icons.close, size: 18, color: colors.muted),
                          onPressed: () {
                            setState(() => _boundVoiceId = null);
                            _scheduleAutoSave();
                          },
                          tooltip: '清除绑定',
                        ),
                      Icon(Icons.chevron_right, color: colors.muted),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ==================== 插件选择 ====================

  String _pluginSummaryText() {
    final total = chatPluginItems.length;
    final selected = _selectedPluginIds
        .where((id) => chatPluginItems.any((p) => p.id == id))
        .length;
    if (selected == total) return '已启用全部 $total 个插件';
    if (selected == 0) return '未启用任何插件';
    return '已启用 $selected / $total 个插件';
  }

  Future<void> _showPluginPicker() async {
    await showMoeBottomSheet(
      context: context,
      title: '选择插件',
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            final colors = ctx.moeColors;
            return ListView.builder(
              shrinkWrap: true,
              itemCount: chatPluginItems.length,
              itemBuilder: (_, index) {
                final item = chatPluginItems[index];
                final selected = _selectedPluginIds.contains(item.id);
                final globallyEnabled = _isPluginGloballyEnabled(item.id);

                return ListTile(
                  leading: Icon(
                    item.icon,
                    size: 20,
                    color: globallyEnabled ? colors.primary : colors.muted,
                  ),
                  title: Text(
                    item.name,
                    style: TextStyle(
                      color: globallyEnabled ? colors.text : colors.muted,
                    ),
                  ),
                  trailing: Switch.adaptive(
                    value: selected,
                    activeColor: colors.primary,
                    onChanged: globallyEnabled
                        ? (value) {
                            setState(() {
                              if (value) {
                                _selectedPluginIds.add(item.id);
                              } else {
                                _selectedPluginIds.remove(item.id);
                              }
                            });
                            setSheetState(() {});
                          }
                        : null,
                  ),
                  onTap: globallyEnabled
                      ? () {
                          setState(() {
                            if (selected) {
                              _selectedPluginIds.remove(item.id);
                            } else {
                              _selectedPluginIds.add(item.id);
                            }
                          });
                          setSheetState(() {});
                        }
                      : null,
                );
              },
            );
          },
        );
      },
    );
  }

  // ==================== 复用的小组件 ====================

  Widget _buildPluginChip(MoeColors colors, ChatPluginItem item) {
    final selected = _selectedPluginIds.contains(item.id);
    final globallyEnabled = _isPluginGloballyEnabled(item.id);

    return FilterChip(
      selected: selected,
      showCheckmark: false,
      avatar: Icon(item.icon,
          size: 15, color: globallyEnabled ? colors.text : colors.muted),
      label: Text(item.name),
      labelStyle:
          TextStyle(color: globallyEnabled ? colors.text : colors.muted),
      backgroundColor: colors.surfaceAlt.withValues(alpha: 0.25),
      selectedColor: colors.primary.withValues(alpha: 0.18),
      side: BorderSide(
        color: selected
            ? colors.primary.withValues(alpha: 0.45)
            : colors.borderLight,
      ),
      onSelected: globallyEnabled
          ? (value) {
              setState(() {
                if (value) {
                  _selectedPluginIds.add(item.id);
                } else {
                  _selectedPluginIds.remove(item.id);
                }
              });
              _scheduleAutoSave();
            }
          : null,
    );
  }

  bool _isPluginGloballyEnabled(String pluginId) {
    switch (pluginId) {
      case 'memory':
        return ref.watch(memoryPluginConfigProvider).enabled;
      case 'tts':
        return ref.watch(ttsPluginConfigProvider).enabled;
      case 'trigger':
        return ref.watch(triggerPluginConfigProvider).enabled;
      case 'sticker':
        return ref.watch(stickerPluginConfigProvider).enabled;
      case 'image':
        return ref.watch(appSettingsProvider).value?.imageGenerationEnabled ??
            true;
      default:
        return true;
    }
  }

  Widget _buildSectionTitle(
    MoeColors colors, {
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 18, color: colors.primary),
            const SizedBox(width: 8),
            Text(
              title,
              style: TextStyle(
                fontSize: 15,
                fontWeight: MoeFontWeights.emphasis,
                color: colors.text,
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(subtitle, style: TextStyle(fontSize: 12, color: colors.muted)),
      ],
    );
  }

  // ==================== 图片选择 ====================

  Future<void> _pickAvatarImage() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;

    final file = result.files.first;
    if (file.bytes == null) return;
    final originalBytes = file.bytes!;

    Uint8List finalBytes = originalBytes;

    if (mounted) {
      final croppedBytes = await Navigator.of(context).push<Uint8List>(
        PageRouteBuilder(
          opaque: false,
          barrierDismissible: false,
          barrierColor: Colors.black,
          transitionDuration: kAnim,
          reverseTransitionDuration: kAnim,
          pageBuilder: (context, animation, secondaryAnimation) =>
              ImageCropDialog(
            imageBytes: originalBytes,
            fileName: file.name,
          ),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            final fadeAnimation =
                CurvedAnimation(parent: animation, curve: Curves.easeOut);
            final scaleAnimation = Tween<double>(begin: 0.95, end: 1.0).animate(
              CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
            );
            return FadeTransition(
              opacity: fadeAnimation,
              child: ScaleTransition(scale: scaleAnimation, child: child),
            );
          },
        ),
      );
      if (croppedBytes != null) {
        finalBytes = croppedBytes;
      } else {
        return;
      }
    }

    final avatarDataUrl = buildDataImage(finalBytes, fileName: file.name);
    final characterDataUrl = buildDataImage(originalBytes, fileName: file.name);
    final prevAvatar = _avatarCtrl.text.trim();
    final prevRefImage = _refImageCtrl.text.trim();
    setState(() {
      _avatarBytes = finalBytes;
      _avatarCtrl.text = avatarDataUrl;
      // 头像上传时，立绘应保存原图而不是裁剪图；
      // 仅在“立绘未独立设置”时同步，避免覆盖用户单独配置的立绘。
      if (prevRefImage.isEmpty || prevRefImage == prevAvatar) {
        _refImageCtrl.text = characterDataUrl;
      }
    });
    _scheduleAutoSave();
  }

  Future<void> _pickCharacterImage() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;

    final file = result.files.first;
    final bytes = file.bytes;
    if (bytes == null) return;

    final dataUrl = buildDataImage(bytes, fileName: file.name);
    setState(() {
      _refImageCtrl.text = dataUrl;
    });
    _scheduleAutoSave();
  }

  void _clearCharacterImage() {
    setState(() {
      _refImageCtrl.clear();
    });
    _scheduleAutoSave();
  }

  Future<void> _pickChatBackgroundImage() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;

    final file = result.files.first;
    final bytes = file.bytes;
    if (bytes == null) return;

    final dataUrl = buildDataImage(bytes, fileName: file.name);
    setState(() {
      _chatBackgroundBytes = bytes;
      _chatBackgroundCtrl.text = dataUrl;
    });
    _scheduleAutoSave();
  }

  void _clearChatBackgroundImage() {
    setState(() {
      _chatBackgroundBytes = null;
      _chatBackgroundCtrl.clear();
    });
    _scheduleAutoSave();
  }

  // 注释已清理乱码

  Future<void> _showVoicePicker(List<VoicePreset> voicePresets) async {
    const followGlobalToken = '__follow_global__';

    final selected = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        final colors = context.moeColors;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(Icons.sync, color: colors.primary),
                title: const Text('跟随全局音色'),
                subtitle: const Text('使用当前聊天插件里选择的音色'),
                trailing: _boundVoiceId == null
                    ? Icon(Icons.check, color: colors.primary)
                    : null,
                onTap: () => Navigator.of(context).pop(followGlobalToken),
              ),
              const Divider(height: 1),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: voicePresets.length,
                  itemBuilder: (context, index) {
                    final preset = voicePresets[index];
                    final selected = _boundVoiceId == preset.id;
                    return ListTile(
                      leading: const Icon(Icons.graphic_eq),
                      title: Text(preset.name),
                      subtitle: Text(preset.providerDisplayName),
                      trailing: selected
                          ? Icon(Icons.check, color: colors.primary)
                          : null,
                      onTap: () => Navigator.of(context).pop(preset.id),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );

    if (!mounted || selected == null) return;
    setState(() {
      if (selected == followGlobalToken) {
        _boundVoiceId = null;
      } else {
        _boundVoiceId = selected;
        // 绑定音色后自动启用 TTS 插件
        _selectedPluginIds.add('tts');
      }
    });
    _scheduleAutoSave();
  }

  String _voiceDisplayName(List<VoicePreset> voicePresets) {
    final id = _boundVoiceId;
    if (id == null || id.isEmpty) {
      return '跟随全局音色';
    }

    for (final preset in voicePresets) {
      if (preset.id == id) return preset.name;
    }

    return '已绑定自定义音色';
  }

  // ==================== 保存逻辑（保持不变）====================

  ContactEditResult _buildEditResult() {
    final name = _nameCtrl.text.trim();
    final avatar =
        _avatarCtrl.text.trim().isEmpty ? null : _avatarCtrl.text.trim();

    final refImage = _refImageCtrl.text.trim();
    final characterImage = refImage.isEmpty ? null : refImage;
    final chatBackgroundImage = _chatBackgroundCtrl.text.trim().isEmpty
        ? null
        : _chatBackgroundCtrl.text.trim();

    final selfAddress = _selfAddressCtrl.text.trim().isEmpty
        ? null
        : _selfAddressCtrl.text.trim();
    final addressUser = _addressUserCtrl.text.trim().isEmpty
        ? null
        : _addressUserCtrl.text.trim();
    final description =
        _descCtrl.text.trim().isEmpty ? null : _descCtrl.text.trim();
    final voiceFile = (_boundVoiceId == null || _boundVoiceId!.trim().isEmpty)
        ? null
        : _boundVoiceId!.trim();
    final enabledPlugins = _buildEnabledPlugins();

    return ContactEditResult(
      displayName: name,
      avatarUrl: avatar,
      characterImage: characterImage,
      chatBackgroundImage: chatBackgroundImage,
      selfAddress: selfAddress,
      addressUser: addressUser,
      voiceFile: voiceFile,
      description: description,
      personaPrompt: _personaCtrl.text.trim(),
      enabledPlugins: enabledPlugins,
      clearAvatarUrl: avatar == null,
      clearCharacterImage: characterImage == null,
      clearChatBackgroundImage: chatBackgroundImage == null,
      clearSelfAddress: selfAddress == null,
      clearAddressUser: addressUser == null,
      clearVoiceFile: voiceFile == null,
      clearDescription: description == null,
      clearEnabledPlugins: enabledPlugins == null,
    );
  }

  List<String>? _buildEnabledPlugins() {
    final allKnown = chatPluginItems.map((e) => e.id).toSet();
    final unknown = [
      for (final id in _selectedPluginIds)
        if (!allKnown.contains(id)) id,
    ];
    final selectedKnownCount =
        _selectedPluginIds.where(allKnown.contains).length;

    if (selectedKnownCount == allKnown.length && unknown.isEmpty) {
      return null;
    }

    final ordered = <String>[
      for (final item in chatPluginItems)
        if (_selectedPluginIds.contains(item.id)) item.id,
      ...unknown,
    ];
    return ordered;
  }

  bool _validateForm() {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      MoeToast.error(context, '请输入角色名称');
      return false;
    }
    return true;
  }

  Future<void> _applyResult(String id, ContactEditResult result) async {
    await ref.read(conversationsProvider.notifier).applyContactEdit(
          id,
          displayName: result.displayName,
          avatarUrl: result.avatarUrl,
          clearAvatarUrl: result.clearAvatarUrl,
          characterImage: result.characterImage,
          clearCharacterImage: result.clearCharacterImage,
          chatBackgroundImage: result.chatBackgroundImage,
          clearChatBackgroundImage: result.clearChatBackgroundImage,
          clearChatBackgroundMaskOpacity: result.clearChatBackgroundImage,
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
  }

  Future<void> _onSave() async {
    if (!_validateForm()) return;
    final result = _buildEditResult();

    if (widget.editMode == EditMode.create) {
      final notifier = ref.read(conversationsProvider.notifier);
      final id = await notifier.createNew();
      await _applyResult(id, result);

      ref.read(activeConversationIdProvider.notifier).state = id;
      if (!mounted) return;
      context.go('/chat/$id');
    } else {
      _allowAndPop<ContactEditResult>(result);
    }
  }

  Future<void> _onSaveTemplate() async {
    if (!_validateForm()) return;
    final result = _buildEditResult();

    await _applyResult(widget.conversation.id, result);

    if (!mounted) return;
    MoeToast.success(context, '角色卡已保存');
    _allowAndPop();
  }

  Future<void> _onSaveAsNewTemplate() async {
    if (_enableAutoSave) {
      await _flushAutoSave();
    }
    if (!_validateForm()) return;
    final result = _buildEditResult();

    final notifier = ref.read(conversationsProvider.notifier);
    final id = await notifier.createNew();
    await _applyResult(id, result);
    await notifier.updateConversationSettings(id, isFavorite: true);

    if (!mounted) return;
    MoeToast.success(context, '已保存到我的角色卡');
    _allowAndPop();
  }
}
