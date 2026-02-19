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

/// 缂栬緫妯″紡鏋氫妇
/// - create: 鏂板缓瑙掕壊锛堜繚瀛樺悗鐩存帴杩涘叆瀵硅瘽锛?/// - editConversation: 缂栬緫瀵硅瘽涓殑瑙掕壊锛堝彲淇濆瓨涓烘柊瑙掕壊鍗★級
/// - editTemplate: template/favorite role card edit mode
enum EditMode {
  create,
  editConversation,
  editTemplate,
}

/// 鏂板缓/缂栬緫瑙掕壊鍗￠〉闈€?///
/// 閲嶆瀯璇存槑锛?026-02-07锛夛細
/// - 鍘绘帀 AppBar锛屾敼涓烘矇娴稿紡妯＄硦鑳屾櫙甯冨眬锛堝鐢?CharacterDetailPage 椋庢牸锛?/// - 澶村儚 + 瑙掕壊鍚嶇О鏀逛负涓€琛屾樉绀?/// - 鎻愮ず璇嶅拰绠€浠嬮粯璁ゅ彧璇伙紝鐐瑰嚮缂栬緫鍥炬爣寮瑰嚭杩戝叏灞忓簳閮ㄥ脊绐楃紪杈?/// - 搴曢儴鎻掍欢/闊宠壊鍖哄煙淇濇寔涓嶅彉
class ContactEditPage extends ConsumerStatefulWidget {
  final Conversation conversation;
  final EditMode editMode;

  /// 鍏煎鏃?API锛歩sNew=true 绛変环浜?editMode=create
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

  bool get _enableAutoSave => widget.editMode == EditMode.editConversation;
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
      text: (conv.characterImage ?? conv.avatarUrl ?? ''),
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
    } else {
      _selectedPluginIds = {...conv.enabledPlugins!};
    }

    final voice = conv.voiceFile?.trim();
    _boundVoiceId = (voice == null || voice.isEmpty) ? null : voice;

    if (_enableAutoSave) {
      for (final controller in _autoSaveControllers) {
        controller.addListener(_onAutoSaveFieldChanged);
      }
      _lastAutoSavedSignature = _buildEditSignature(_buildEditResult());
    }

    // 棰勭儹妯＄硦鑳屾櫙
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

  /// 鑾峰彇绔嬬粯 ImageProvider锛堢敤浜庤儗鏅ā绯婏級
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
    final statusBarHeight = MediaQuery.paddingOf(context).top;
    final voicePresets = ref.watch(ttsPluginConfigProvider).voicePresets;

    return PopScope(
      canPop: !_enableAutoSave || _allowNativePop,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await _handleBack();
      },
      child: Scaffold(
        backgroundColor: colors.surface,
        body: Stack(
          children: [
            // 1. 妯＄硦鑳屾櫙锛堝浐瀹氫笉鍔級
            Positioned.fill(
              child: _buildBlurredBackground(colors),
            ),

            // 2. 鍙粴鍔ㄥ唴瀹瑰尯
            Positioned.fill(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                child: Column(
                  children: [
                    // 椤堕儴瀹夊叏鍖?                    SizedBox(height: statusBarHeight + 16),

                    // 瀵艰埅鏍忥紙宸﹁繑鍥?+ 鍙虫洿澶氾級
                    _buildNavBar(colors),

                    const SizedBox(height: 24),

                    // 澶村儚 + 鍚嶇О锛堜竴琛屾樉绀猴級
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: _buildAvatarNameRow(colors),
                    ),

                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: _buildChatBackgroundSection(colors),
                    ),
                    const SizedBox(height: 16),

                    // Description section (readonly + edit entry)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: _buildReadonlySection(
                        colors,
                        icon: Icons.notes,
                        title: 'Description',
                        content: _descCtrl.text,
                        placeholder: 'No description yet',
                        onEdit: () => _openFullScreenEditor(
                          title: 'Edit Description',
                          controller: _descCtrl,
                          hint: '涓€鍙ヨ瘽浠嬬粛杩欎釜瑙掕壊锛堝彲閫夛級',
                        ),
                      ),
                    ),

                    const SizedBox(height: 16),

                    // 鎻愮ず璇嶏紙涓昏灞曠ず鍖猴紝鏀惧ぇ + 鍐呴儴鍙粦鍔級
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: _buildPromptSection(colors),
                    ),

                    const SizedBox(height: 16),

                    // 鎻掍欢 + 闊宠壊缁戝畾
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: _buildBottomCard(colors, voicePresets),
                    ),

                    // 搴曢儴鐣欑櫧
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

  // ==================== 妯＄硦鑳屾櫙 ====================

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
        // 鍙犲眰鎻愪寒/鍘嬫殫
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

  // ==================== 鑷姩淇濆瓨 ====================

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

  // ==================== 瀵艰埅鏍?====================

  Widget _buildNavBar(MoeColors colors) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          // 杩斿洖鎸夐挳
          _buildCircleButton(
            icon: Icons.arrow_back,
            onTap: () => unawaited(_handleBack()),
          ),
          const Spacer(),
          // 鍙充晶鎿嶄綔鎸夐挳
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
        ];
      case EditMode.editTemplate:
        return [
          _buildCircleButton(
            icon: Icons.copy_outlined,
            onTap: _onSaveAsNewTemplate,
            tooltip: 'Save As',
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
          label: 'Save as New Card',
          icon: Icons.bookmark_add_outlined,
          onTap: _onSaveAsNewTemplate,
        ),
      ],
    );
  }

  Future<void> _handleBack() async {
    await _flushAutoSave();
    if (!mounted) return;
    if (_enableAutoSave && !_allowNativePop) {
      setState(() {
        _allowNativePop = true;
      });
    }
    Navigator.of(context).pop();
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

  // ==================== 澶村儚 + 鍚嶇О涓€琛?====================

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
        // 澶村儚锛堝渾瑙掔煩褰紝娌跨敤鑱旂郴浜哄崱鐗囬鏍硷級
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
              hintText: 'Enter character name',
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

  // ==================== 鍙鍖哄潡 + 缂栬緫鍏ュ彛 ====================

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
          // 鏍囬琛?+ 缂栬緫鎸夐挳
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
              // 缂栬緫鎸夐挳
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

          // 鍙鏂囨湰鍐呭
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

  // ==================== 鎻愮ず璇嶄富灞曠ず鍖猴紙鏀惧ぇ + 鍙粦鍔級====================

  Widget _buildPromptSection(MoeColors colors) {
    final hasContent = _personaCtrl.text.trim().isNotEmpty;

    void openEditor() => _openFullScreenEditor(
          title: 'Edit Prompt',
          controller: _personaCtrl,
          hint: '璇︾粏鎻忚堪瑙掕壊鐨勬€ф牸銆佽璇濇柟寮忋€佽涓鸿竟鐣屽拰涓栫晫瑙?..',
        );

    return FrostedGlassContainer(
      borderRadius: 16,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 鏍囬琛?+ 缂栬緫鎸夐挳
          Row(
            children: [
              Icon(Icons.auto_awesome, size: 18, color: colors.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Prompt',
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
                        'No character prompt set',
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

  // ==================== 鍏ㄥ睆缂栬緫寮圭獥 ====================

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

  // ==================== 搴曢儴鍗＄墖锛堟彃浠?+ 闊宠壊锛?===================

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
            title: '鎻掍欢',
            subtitle: '榛樿鍏ㄩ儴寮€鍚紝鍙寜瑙掕壊鍗曠嫭璋冩暣',
          ),
          const SizedBox(height: 8),
          // 涓€琛屾樉绀哄凡閫夋暟閲忥紝鐐瑰嚮寮瑰嚭閫夋嫨寮圭獥
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
            title: '缁戝畾闊宠壊',
            subtitle: '鍙负褰撳墠瑙掕壊缁戝畾鐙珛闊宠壊',
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
                          tooltip: '娓呴櫎缁戝畾',
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

  // ==================== 鎻掍欢閫夋嫨 ====================

  String _pluginSummaryText() {
    final total = chatPluginItems.length;
    final selected = _selectedPluginIds
        .where((id) => chatPluginItems.any((p) => p.id == id))
        .length;
    if (selected == total) return 'Enabled all $total plugins';
    if (selected == 0) return 'No plugin enabled';
    return 'Enabled $selected / $total plugins';
  }

  Future<void> _showPluginPicker() async {
    await showMoeBottomSheet(
      context: context,
      title: '閫夋嫨鎻掍欢',
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

  // ==================== 澶嶇敤鐨勫皬缁勪欢 ====================

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

  // ==================== 鍥剧墖閫夋嫨 ====================

  Future<void> _pickAvatarImage() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;

    final file = result.files.first;
    if (file.bytes == null) return;

    Uint8List? finalBytes = file.bytes;

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
            imageBytes: file.bytes!,
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

    if (finalBytes == null) return;

    final dataUrl = buildDataImage(finalBytes, fileName: file.name);
    setState(() {
      _avatarBytes = finalBytes;
      _avatarCtrl.text = dataUrl;
      _refImageCtrl.text = dataUrl;
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

  // ==================== 闊宠壊閫夋嫨 ====================

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
                title: const Text('璺熼殢鍏ㄥ眬闊宠壊'),
                subtitle:
                    const Text('Use the currently selected chat-plugin voice'),
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
      _boundVoiceId = selected == followGlobalToken ? null : selected;
    });
    _scheduleAutoSave();
  }

  String _voiceDisplayName(List<VoicePreset> voicePresets) {
    final id = _boundVoiceId;
    if (id == null || id.isEmpty) {
      return '璺熼殢鍏ㄥ眬闊宠壊';
    }

    for (final preset in voicePresets) {
      if (preset.id == id) return preset.name;
    }

    return '宸茬粦瀹氳嚜瀹氫箟闊宠壊';
  }

  // ==================== 淇濆瓨閫昏緫锛堜繚鎸佷笉鍙橈級====================

  ContactEditResult _buildEditResult() {
    final name = _nameCtrl.text.trim();
    final avatar =
        _avatarCtrl.text.trim().isEmpty ? null : _avatarCtrl.text.trim();

    final refImage = _refImageCtrl.text.trim();
    final characterImage = refImage.isEmpty ? avatar : refImage;
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
      MoeToast.error(context, 'Please enter character name');
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
      Navigator.of(context).pop<ContactEditResult>(result);
    }
  }

  Future<void> _onSaveTemplate() async {
    if (!_validateForm()) return;
    final result = _buildEditResult();

    await _applyResult(widget.conversation.id, result);

    if (!mounted) return;
    MoeToast.success(context, 'Template saved');
    Navigator.of(context).pop();
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
    MoeToast.success(context, 'Saved to My Characters');
    Navigator.of(context).pop();
  }
}
