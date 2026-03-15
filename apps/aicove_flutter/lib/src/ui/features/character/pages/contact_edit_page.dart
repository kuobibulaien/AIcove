import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/utils/blurred_background_service.dart';
import '../../../../core/utils/data_image.dart';
import '../../../../features/chat/domain/conversation.dart';
import '../../../../features/chat/domain/persona_prompt_codec.dart';
import '../../../../features/chat/presentation/widgets/contact_edit_dialog.dart';
import '../../../../features/chat/providers2.dart';
import '../../../../features/plugins/image/image_config.dart';
import '../../../../features/plugins/plugin_providers.dart';
import '../../../../ui/features/settings/pages/chat_plugin_settings_page.dart';
import '../widgets/avatar_name_section.dart';

import '../widgets/character_text_editor_sheet.dart';
import '../widgets/chat_background_section.dart';
import '../widgets/drawing_prompt_section.dart';
import '../widgets/plugin_voice_section.dart';
import '../widgets/prompt_section.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/widgets/index.dart';

/// 编辑模式枚举
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

class ContactEditPage extends ConsumerStatefulWidget {
  final Conversation conversation;
  final EditMode editMode;

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
  late final TextEditingController _customDrawingPromptCtrl;
  late String _selectedToolPresetName;
  late bool _followGlobalArtistPreset;
  String? _selectedArtistPresetName;
  late final TextEditingController _selfAddressCtrl;
  late final TextEditingController _addressUserCtrl;
  late final TextEditingController _avatarCtrl;
  late final TextEditingController _refImageCtrl;
  late final TextEditingController _chatBackgroundCtrl;

  Uint8List? _chatBackgroundBytes;
  late Set<String> _selectedPluginIds;
  String? _boundVoiceId;
  Timer? _autoSaveDebounce;
  bool _isAutoSaving = false;
  bool _autoSaveQueued = false;
  String? _lastAutoSavedSignature;
  bool _allowNativePop = false;
  String? _scheduledBlurSource;

  bool get _enableAutoSave => false;
  List<TextEditingController> get _autoSaveControllers => [
        _nameCtrl,
        _descCtrl,
        _personaCtrl,
        _customDrawingPromptCtrl,
        _selfAddressCtrl,
        _addressUserCtrl,
        _chatBackgroundCtrl,
      ];

  @override
  void initState() {
    super.initState();
    final conv = widget.conversation;
    final personaParts = PersonaPromptCodec.parse(conv.personaPrompt);
    final imageConfig = ref.read(imagePluginConfigProvider);
    final fallbackToolPresetName = imageConfig.selectedSystemPromptPresetName ??
        (imageConfig.systemPromptPresets.isNotEmpty
            ? imageConfig.systemPromptPresets.first.name
            : '');

    _nameCtrl = TextEditingController(text: conv.displayName);
    _descCtrl = TextEditingController(text: conv.description ?? '');
    _personaCtrl = TextEditingController(text: personaParts.userPrompt);
    _customDrawingPromptCtrl = TextEditingController(
      text: personaParts.customDrawingPrompt,
    );
    _selectedToolPresetName = _pickValidToolPresetName(
          personaParts.drawingToolPresetName,
          imageConfig,
        ) ??
        fallbackToolPresetName;
    final initialArtistBinding = personaParts.drawingArtistPresetName;
    if (PersonaPromptCodec.isArtistPresetDisabledBinding(
        initialArtistBinding)) {
      _followGlobalArtistPreset = false;
      _selectedArtistPresetName = null;
    } else {
      _selectedArtistPresetName = _pickValidArtistPresetName(
        initialArtistBinding,
        imageConfig,
      );
      _followGlobalArtistPreset = _selectedArtistPresetName == null;
    }
    _selfAddressCtrl = TextEditingController(text: conv.selfAddress ?? '');
    _addressUserCtrl = TextEditingController(text: conv.addressUser ?? '');
    _avatarCtrl = TextEditingController(text: conv.avatarUrl ?? '');
    _refImageCtrl = TextEditingController(
      text: (conv.characterImage ?? ''),
    );
    _chatBackgroundCtrl = TextEditingController(
      text: conv.chatBackgroundImage ?? '',
    );

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

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduleBlurEnsure();
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
    _customDrawingPromptCtrl.dispose();
    _selfAddressCtrl.dispose();
    _addressUserCtrl.dispose();
    _avatarCtrl.dispose();
    _refImageCtrl.dispose();
    _chatBackgroundCtrl.dispose();
    super.dispose();
  }

  String? _getBackgroundSource() {
    return BlurredBackgroundService.pickPreferredSource(
      characterImage:
          _refImageCtrl.text.trim().isEmpty ? null : _refImageCtrl.text.trim(),
      avatarUrl:
          _avatarCtrl.text.trim().isEmpty ? null : _avatarCtrl.text.trim(),
    );
  }

  void _scheduleBlurEnsure() {
    final source = _getBackgroundSource();
    if (source == null || _scheduledBlurSource == source) return;
    _scheduledBlurSource = source;
    unawaited(
      BlurredBackgroundService.ensureBlur(source).then((provider) {
        if (!mounted) return;
        if (provider == null && _scheduledBlurSource == source) {
          _scheduledBlurSource = null;
        }
      }),
    );
  }

  // ==================== build ====================

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
                    SafeArea(
                      bottom: false,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: _buildNavBar(colors),
                      ),
                    ),

                    const SizedBox(height: 24),

                    // 立绘 + 名称（合并区域）
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: AvatarNameSection(
                        nameCtrl: _nameCtrl,
                        avatarCtrl: _avatarCtrl,
                        refImageCtrl: _refImageCtrl,
                        onPickCharacterImage: _pickCharacterImage,
                        onClearCharacterImage: _clearCharacterImage,
                      ),
                    ),
                    const SizedBox(height: 16),

                    // 角色描述
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: ReadonlyEditCard(
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

                    // 提示词
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: PromptPreviewCard(
                        personaCtrl: _personaCtrl,
                        onEdit: () => _openFullScreenEditor(
                          title: '编辑提示词',
                          controller: _personaCtrl,
                          hint: '详细描述角色的性格、说话方式、行为边界和世界观...',
                        ),
                      ),
                    ),

                    const SizedBox(height: 16),

                    // 插件 + 音色 + 聊天背景
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Column(
                        children: [
                          PluginVoiceSection(
                            selectedPluginIds: _selectedPluginIds,
                            boundVoiceId: _boundVoiceId,
                            voicePresets: voicePresets,
                            onPluginIdsChanged: (newIds) {
                              setState(() => _selectedPluginIds = newIds);
                              _scheduleAutoSave();
                            },
                            onVoiceChanged: (voiceId) {
                              setState(() {
                                _boundVoiceId = voiceId;
                                // 绑定音色后自动启用 TTS 插件
                                if (voiceId != null) {
                                  _selectedPluginIds.add('tts');
                                }
                              });
                              _scheduleAutoSave();
                            },
                          ),
                          const SizedBox(height: 16),
                          ChatBackgroundSection(
                            chatBackgroundCtrl: _chatBackgroundCtrl,
                            chatBackgroundBytes: _chatBackgroundBytes,
                            onPick: _pickChatBackgroundImage,
                            onClear: _clearChatBackgroundImage,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),

                    // 专属绘图提示（工具提示词预设 + 个性化绘图提示词）
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: DrawingPromptSection(
                        customDrawingPromptCtrl: _customDrawingPromptCtrl,
                        followsGlobalArtistPreset: _followGlobalArtistPreset,
                        selectedToolPresetName: _selectedToolPresetName,
                        selectedArtistPresetName: _selectedArtistPresetName,
                        onToolPresetChanged: (name) {
                          setState(() => _selectedToolPresetName = name);
                          _scheduleAutoSave();
                        },
                        onArtistPresetFollowGlobal: () {
                          setState(() {
                            _followGlobalArtistPreset = true;
                            _selectedArtistPresetName = null;
                          });
                          _scheduleAutoSave();
                        },
                        onArtistPresetDisable: () {
                          setState(() {
                            _followGlobalArtistPreset = false;
                            _selectedArtistPresetName = null;
                          });
                          _scheduleAutoSave();
                        },
                        onArtistPresetSelected: (name) {
                          setState(() {
                            _followGlobalArtistPreset = false;
                            _selectedArtistPresetName = name;
                          });
                          _scheduleAutoSave();
                        },
                        onEdit: () => _openFullScreenEditor(
                          title: '编辑个性化绘图提示',
                          controller: _customDrawingPromptCtrl,
                          hint:
                              '可在此设定男女主外貌标签优先使用 Danbooru，也可用自然语言描述，以及对生图的要求。\n\n示例：女主纳西妲，danbooru标签"nahida_(genshin_impact)",男主danbooru标签"aether_(genshin_impact)"，默认生图视角为男主第一视角，少数情况使用第三视角出现男主全身。',
                        ),
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
    final source = _getBackgroundSource();
    if (source == null) {
      return Container(color: colors.surface);
    }
    _scheduleBlurEnsure();

    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Stack(
      fit: StackFit.expand,
      children: [
        _buildGradientFallback(colors, isDark),
        ValueListenableBuilder<int>(
          valueListenable: BlurredBackgroundService.ticker,
          builder: (context, _, __) {
            final provider = BlurredBackgroundService.getBlurProvider(source);
            return AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child: _buildBlurLayer(source, provider),
            );
          },
        ),
        Container(
          color: isDark
              ? Colors.black.withValues(alpha: 0.25)
              : Colors.white.withValues(alpha: 0.22),
        ),
      ],
    );
  }

  Widget _buildBlurLayer(String source, ImageProvider? provider) {
    final blurAsset = BlurredBackgroundService.deriveBlurAssetPath(source);

    if (blurAsset != null) {
      return SizedBox.expand(
        key: ValueKey('asset:$blurAsset'),
        child: Image.asset(
          blurAsset,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          filterQuality: FilterQuality.medium,
          errorBuilder: (_, __, ___) => provider == null
              ? const SizedBox.shrink(key: ValueKey('empty'))
              : _buildBlurImage(provider, key: ValueKey('file:$source')),
        ),
      );
    }

    if (provider == null) {
      return const SizedBox.shrink(key: ValueKey('empty'));
    }

    return _buildBlurImage(provider, key: ValueKey('file:$source'));
  }

  Widget _buildBlurImage(ImageProvider provider, {required Key key}) {
    return SizedBox.expand(
      key: key,
      child: Image(
        image: provider,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        filterQuality: FilterQuality.medium,
      ),
    );
  }

  Widget _buildGradientFallback(MoeColors colors, bool isDark) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colors.surface,
            colors.primary.withValues(alpha: isDark ? 0.18 : 0.1),
            isDark ? const Color(0xFF12161C) : Colors.white,
          ],
        ),
      ),
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

  // ==================== 导航栏 ====================

  Widget _buildNavBar(MoeColors colors) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          _buildCircleButton(
            icon: Icons.arrow_back,
            onTap: () => unawaited(_handleBack()),
          ),
          const Spacer(),
          ..._buildNavActions(colors),
        ],
      ),
    );
  }

  List<Widget> _buildNavActions(MoeColors colors) {
    switch (widget.editMode) {
      case EditMode.create:
        return [
          _buildCircleButton(icon: Icons.check, onTap: _onSave),
        ];
      case EditMode.editConversation:
        return [
          _buildCircleButton(
            icon: Icons.more_horiz,
            onTap: () => _showMoreMenu(colors),
          ),
          const SizedBox(width: 8),
          _buildCircleButton(icon: Icons.check, onTap: _onSave),
        ];
      case EditMode.editTemplate:
        return [
          _buildCircleButton(
            icon: Icons.copy_outlined,
            onTap: _onSaveAsNewTemplate,
            tooltip: '另存为',
          ),
          const SizedBox(width: 8),
          _buildCircleButton(icon: Icons.check, onTap: _onSaveTemplate),
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

  // ==================== 退出处理 ====================

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

  // ==================== 图片选择 ====================

  /// 上传立绘（两步流程）：
  /// 1. 选择原图 → 保存为立绘（characterImage）
  /// 2. 自动弹出裁剪界面 → 裁剪结果保存为头像（avatarUrl）
  Future<void> _pickCharacterImage() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;

    final file = result.files.first;
    if (file.bytes == null) return;
    final originalBytes = file.bytes!;

    // 第一步：原图保存为立绘
    final characterDataUrl = buildDataImage(originalBytes, fileName: file.name);
    setState(() {
      _refImageCtrl.text = characterDataUrl;
    });

    // 第二步：自动打开裁剪界面，裁剪为头像
    if (!mounted) return;
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

    if (croppedBytes != null && mounted) {
      final avatarDataUrl = buildDataImage(croppedBytes, fileName: file.name);
      setState(() {
        _avatarCtrl.text = avatarDataUrl;
      });
    }

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

  // ==================== 保存逻辑 ====================

  String? _pickValidToolPresetName(String? value, ImageConfig config) {
    final name = value?.trim();
    if (name == null || name.isEmpty) return null;
    final exists = config.systemPromptPresets.any((p) => p.name == name);
    return exists ? name : null;
  }

  String? _pickValidArtistPresetName(String? value, ImageConfig config) {
    final name = value?.trim();
    if (name == null || name.isEmpty) return null;
    final exists = config.artistPresets.any((p) => p.name == name);
    return exists ? name : null;
  }

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
    final personaPrompt = PersonaPromptCodec.compose(
      userPrompt: _personaCtrl.text.trim(),
      customDrawingPrompt: _customDrawingPromptCtrl.text.trim(),
      drawingToolPresetName: _selectedToolPresetName,
      drawingArtistPresetName: _followGlobalArtistPreset
          ? null
          : (_selectedArtistPresetName ??
              PersonaPromptCodec.artistPresetDisabledBinding),
    );
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
      personaPrompt: personaPrompt,
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
