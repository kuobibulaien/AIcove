import '../../../../features/conversation_state/domain/mvu_content.dart';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../../../shared/animations/parallax_slide_page_route.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/utils/blurred_background_service.dart';
import '../../../../core/utils/data_image.dart';
import '../../../../features/agent_context/data/silly_tavern_character_card_loader.dart';
import '../../../../features/agent_context/domain/silly_tavern_character_card.dart';
import '../../../../features/agent_context/providers/preset_recipe_provider.dart';
import '../../../../features/chat/application/chat_page_conversation_actions.dart';
import '../../../../features/chat/domain/conversation.dart';
import '../../../../features/chat/domain/persona_prompt_codec.dart';
import '../../../../features/chat/presentation/widgets/contact_edit_dialog.dart';
import '../../../../features/chat/providers2.dart';
import '../../../../features/plugins/plugin_providers.dart';
import '../../../../ui/features/settings/pages/chat_plugin_settings_page.dart';
import '../../plugins/widgets/tavern_common.dart';
import '../widgets/avatar_name_section.dart';
import 'contact_memory_page.dart';
import '../services/contact_edit_snapshot_store.dart';

import '../widgets/background_info_section.dart';
import '../widgets/character_plugins_section.dart';
import '../widgets/character_text_editor_sheet.dart';
import '../widgets/tavern_greeting_picker_sheet.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/widgets/index.dart';

/// 编辑模式枚举
/// - editTemplate: template/favorite role card edit mode
enum EditMode { create, editConversation, editTemplate }

const Duration _kContactEditDeferredVisualWindow = Duration(milliseconds: 420);

/// 导入酒馆角色卡时背景默认叠加的薄模糊。
const double _kImportedBackgroundBlurSigma = 6.0;

class ContactEditPage extends ConsumerStatefulWidget {
  final Conversation conversation;
  final EditMode editMode;
  final ContactEditSnapshot? initialSnapshot;

  const ContactEditPage({
    super.key,
    required this.conversation,
    this.initialSnapshot,
    @Deprecated('Use editMode instead') bool isNew = false,
    EditMode? editMode,
  }) : editMode =
           editMode ?? (isNew ? EditMode.create : EditMode.editConversation);

  @override
  ConsumerState<ContactEditPage> createState() => _ContactEditPageState();
}

class _ContactEditPageState extends ConsumerState<ContactEditPage>
    with MoeAutoSaveState<ContactEditPage> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _descCtrl;
  late final TextEditingController _personaCtrl;
  late final TextEditingController _customDrawingPromptCtrl;
  String? _drawingPresetId;
  late PersonaPromptParts _legacyDrawingParts;
  bool _drawingBindingChanged = false;
  late final TextEditingController _selfAddressCtrl;
  late final TextEditingController _addressUserCtrl;
  late final TextEditingController _avatarCtrl;
  late final TextEditingController _refImageCtrl;
  late final TextEditingController _chatBackgroundCtrl;

  Uint8List? _chatBackgroundBytes;

  /// 仅导入角色卡时写入；null 表示沿用会话已有的模糊值。
  double? _chatBackgroundBlurSigma;
  bool _importingCard = false;
  bool _importingPreset = false;
  bool _submitting = false;

  /// 创建成功后记下 ID，后续步骤失败重试时不再新建角色。
  String? _createdId;

  /// 导入的角色卡；创建时把卡内正则与世界书并入角色专用组合。
  SillyTavernCharacterCard? _importedCard;

  /// 导入角色卡带来的开场白；创建角色时把选中的一套写成第一条角色消息。
  List<String> _cardGreetings = const [];
  int _greetingIndex = 0;
  late Set<String> _selectedPluginIds;
  String? _boundVoiceId;
  String? _selectedRecipeId;
  String? _scheduledBlurSource;
  Timer? _deferredVisualsTimer;
  bool _deferHeavyVisuals = true;
  bool _backgroundInfoExpanded = false;

  bool get _enableAutoSave => widget.editMode != EditMode.create;
  List<TextEditingController> get _autoSaveControllers => [
    _nameCtrl,
    _avatarCtrl,
    _refImageCtrl,
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
    final conv = _resolveInitialConversation();
    final personaParts = PersonaPromptCodec.parse(conv.personaPrompt);
    _legacyDrawingParts = personaParts;
    _drawingPresetId = personaParts.drawingPresetId;

    _nameCtrl = TextEditingController(text: conv.displayName);
    _descCtrl = TextEditingController(text: conv.description ?? '');
    _personaCtrl = TextEditingController(text: personaParts.userPrompt);
    _customDrawingPromptCtrl = TextEditingController(
      text: personaParts.customDrawingPrompt,
    );
    _selfAddressCtrl = TextEditingController(text: conv.selfAddress ?? '');
    _addressUserCtrl = TextEditingController(text: conv.addressUser ?? '');
    _avatarCtrl = TextEditingController(text: conv.avatarUrl ?? '');
    _refImageCtrl = TextEditingController(text: (conv.characterImage ?? ''));
    _chatBackgroundCtrl = TextEditingController(
      text: conv.chatBackgroundImage ?? '',
    );

    final allPluginIds = conversationScopedChatPluginItems
        .map((e) => e.id)
        .toSet();
    if (widget.editMode == EditMode.create) {
      // 新建角色默认不开启任何插件，由用户在「管理开启的插件」中逐项开启
      _selectedPluginIds = {};
    } else if (conv.enabledPlugins == null) {
      _selectedPluginIds = {...allPluginIds};
    } else {
      _selectedPluginIds = {
        for (final id in conv.enabledPlugins!)
          if (allPluginIds.contains(id)) id,
      };
    }

    final voice = conv.voiceFile?.trim();
    _boundVoiceId = (voice == null || voice.isEmpty) ? null : voice;

    _selectedRecipeId = conv.recipeId;

    if (_enableAutoSave) {
      autoSave.configure(
        save: () async {
          final result = _buildEditResult();
          if (result.displayName.trim().isEmpty) {
            throw const FormatException('请输入角色名称');
          }
          await _applyResult(widget.conversation.id, result);
        },
        snapshot: () => _buildEditSignature(_buildEditResult()),
        fields: _autoSaveControllers,
      );
    }
    if (widget.initialSnapshot != null) {
      _deferHeavyVisuals = false;
      _chatBackgroundBytes = _decodeInitialBackgroundBytes();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _scheduleBlurEnsure();
      });
    } else {
      _scheduleDeferredVisualActivation();
    }
  }

  @override
  void dispose() {
    _deferredVisualsTimer?.cancel();
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
      characterImage: _refImageCtrl.text.trim().isEmpty
          ? null
          : _refImageCtrl.text.trim(),
      avatarUrl: _avatarCtrl.text.trim().isEmpty
          ? null
          : _avatarCtrl.text.trim(),
    );
  }

  Conversation _resolveInitialConversation() {
    final snapshot = widget.initialSnapshot;
    if (snapshot == null) return widget.conversation;
    return widget.conversation.copyWith(
      displayName: snapshot.displayName,
      avatarUrl: snapshot.avatarUrl,
      characterImage: snapshot.characterImage,
      chatBackgroundImage: snapshot.chatBackgroundImage,
      selfAddress: snapshot.selfAddress,
      addressUser: snapshot.addressUser,
      voiceFile: snapshot.voiceFile,
      description: snapshot.description,
      personaPrompt: snapshot.personaPrompt,
      enabledPlugins: snapshot.enabledPlugins == null
          ? null
          : List<String>.from(snapshot.enabledPlugins!),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        snapshot.sourceUpdatedAtMs,
      ),
    );
  }

  Uint8List? _decodeInitialBackgroundBytes() {
    final rawBackground = _chatBackgroundCtrl.text.trim();
    if (rawBackground.isEmpty) return null;
    return decodeDataImage(rawBackground);
  }

  void _scheduleDeferredVisualActivation() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _deferredVisualsTimer?.cancel();
      _deferredVisualsTimer = Timer(
        _kContactEditDeferredVisualWindow,
        _activateHeavyVisuals,
      );
    });
  }

  void _activateHeavyVisuals() {
    if (!mounted || !_deferHeavyVisuals) return;

    final rawBackground = _chatBackgroundCtrl.text.trim();
    final decodedBackgroundBytes = rawBackground.isEmpty
        ? null
        : decodeDataImage(rawBackground);

    setState(() {
      _chatBackgroundBytes = decodedBackgroundBytes;
      _deferHeavyVisuals = false;
    });
    _scheduleBlurEnsure();
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

    return autoSavePage(
      MoePageScaffold(
        extendBodyBehindAppBar: true,
        backgroundColor: colors.surfaceAlt,
        appBar: MoeAppBar(
          title: widget.editMode == EditMode.create ? '新建角色' : '编辑角色',
          titleWidget: _buildNameField(colors),
          centerTitle: true,
          showBackButton: true,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            tooltip: '返回',
            onPressed: () => unawaited(_handleBack()),
          ),
          actions: _buildNavActions(colors),
        ),
        body: Stack(
          children: [
            // 纯色背景与固定标题栏首帧呈现，较重的表单仍延后挂载。
            // 设置壁纸后本页与聊天页共用同一张背景图。
            Positioned.fill(child: _buildPageBackground(colors)),

            // 2. 可滚动内容区
            Positioned.fill(
              child: _deferHeavyVisuals
                  ? _buildDeferredShell(colors)
                  : _buildEditorScrollContent(colors),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEditorScrollContent(MoeColors colors) {
    final voicePresets = ref.watch(ttsPluginConfigProvider).voicePresets;

    return Builder(
      builder: (context) => SingleChildScrollView(
        padding: moeUnderBarPadding(context),
        physics: const BouncingScrollPhysics(),
        child: Column(
          children: [
            const SizedBox(height: 24),

            // 角色立绘 + 名称
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

            // 酒馆预设、已开启插件列表，末尾为管理开启的插件开关列表
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: CharacterPluginsSection(
                selectedPluginIds: _selectedPluginIds,
                boundVoiceId: _boundVoiceId,
                voicePresets: voicePresets,
                drawingPersonaPrompt: _drawingPersonaPrompt(),
                selectedRecipeId: _selectedRecipeId,
                memoryDocAvailable:
                    widget.editMode == EditMode.editConversation,
                onOpenMemoryDoc: _openMemoryDoc,
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
                onDrawingPresetChanged: (id) {
                  setState(() {
                    _drawingPresetId = id;
                    _drawingBindingChanged = true;
                  });
                  _scheduleAutoSave();
                },
                onRecipeChanged: (recipeId) {
                  setState(() => _selectedRecipeId = recipeId);
                  _scheduleAutoSave();
                },
              ),
            ),

            const SizedBox(height: 16),

            // 角色卡信息：人设提示词 + 绘图提示
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: BackgroundInfoSection(
                expanded: _backgroundInfoExpanded,
                onToggle: () => setState(
                  () => _backgroundInfoExpanded = !_backgroundInfoExpanded,
                ),
                personaText: _personaCtrl.text,
                drawingText: _customDrawingPromptCtrl.text,
                onEditPersona: () => _openFullScreenEditor(
                  title: '编辑人设提示词',
                  controller: _personaCtrl,
                  hint: '详细描述角色的性格、说话方式、行为边界和世界观...',
                ),
                onEditDrawing: () => _openFullScreenEditor(
                  title: '编辑绘图提示',
                  controller: _customDrawingPromptCtrl,
                  hint:
                      '可在此设定男女主外貌标签优先使用 Danbooru，也可用自然语言描述，以及对生图的要求。\n\n示例：女主纳西妲，danbooru标签"nahida_(genshin_impact)",男主danbooru标签"aether_(genshin_impact)"，默认生图视角为男主第一视角，少数情况使用第三视角出现男主全身。',
                ),
              ),
            ),

            if (widget.editMode == EditMode.create) ...[
              const SizedBox(height: 16),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
                  _buildTavernCardImportButton(),
                  _buildTavernPresetImportButton(),
                ],
              ),
              if (_cardGreetings.length > 1) ...[
                const SizedBox(height: 8),
                Center(child: _buildGreetingPickerButton()),
              ],
            ],

            // 底部留白
            const SizedBox(height: 48),
          ],
        ),
      ),
    );
  }

  /// 标题栏内的角色名输入，取代固定的页面标题。
  Widget _buildNameField(MoeColors colors) {
    final style = TextStyle(
      fontSize: 18,
      fontWeight: FontWeight.w600,
      color: colors.headerContentColor,
    );
    return TextField(
      controller: _nameCtrl,
      textAlign: TextAlign.center,
      maxLines: 1,
      style: style,
      decoration: InputDecoration.collapsed(
        hintText: '输入角色名称',
        hintStyle: style.copyWith(
          fontWeight: FontWeight.normal,
          color: colors.muted,
        ),
      ),
    );
  }

  String _drawingPersonaPrompt() {
    return PersonaPromptCodec.compose(
      userPrompt: '',
      drawingPresetId: _drawingPresetId,
      drawingToolPresetName: _drawingBindingChanged
          ? null
          : _legacyDrawingParts.drawingToolPresetName,
      drawingArtistPresetName: _drawingBindingChanged
          ? null
          : _legacyDrawingParts.drawingArtistPresetName,
    );
  }

  void _openMemoryDoc() {
    Navigator.of(context).push(
      ParallaxSlidePageRoute(
        page: ContactMemoryPage(
          ownerId: widget.conversation.id,
          displayName: _nameCtrl.text.trim(),
        ),
      ),
    );
  }

  /// 页面背景：上传壁纸后与聊天页共用同一张图，叠加蒙层保证内容可读。
  Widget _buildPageBackground(MoeColors colors) {
    final raw = _chatBackgroundCtrl.text.trim();
    final image = _deferHeavyVisuals ? null : _resolveWallpaperImage(raw);
    if (image == null) {
      return ColoredBox(color: colors.surfaceAlt);
    }
    final maskOpacity = (widget.conversation.chatBackgroundMaskOpacity ?? 0.8)
        .clamp(0.0, 1.0);
    return ColoredBox(
      color: colors.surfaceAlt,
      child: Stack(
        fit: StackFit.expand,
        children: [
          image,
          IgnorePointer(
            child: ColoredBox(
              color: colors.surfaceAlt.withValues(alpha: maskOpacity),
            ),
          ),
        ],
      ),
    );
  }

  Widget? _resolveWallpaperImage(String raw) {
    if (raw.isEmpty) return null;

    final bytes = _chatBackgroundBytes ?? decodeDataImage(raw);
    if (bytes != null) {
      return Image.memory(
        bytes,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
      );
    }
    if (raw.startsWith('data:image')) return null;
    if (raw.startsWith('http://') || raw.startsWith('https://')) {
      return Image.network(
        raw,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
      );
    }
    if (raw.startsWith('assets/') || raw.startsWith('packages/')) {
      return Image.asset(
        raw,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
      );
    }
    return Image.file(
      File(raw),
      fit: BoxFit.cover,
      gaplessPlayback: true,
      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
    );
  }

  Widget _buildDeferredShell(MoeColors colors) {
    return Builder(
      builder: (context) => SingleChildScrollView(
        padding: moeUnderBarPadding(context),
        physics: const NeverScrollableScrollPhysics(),
        child: Column(
          children: [
            const SizedBox(height: 24),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: _buildShellCard(colors, height: 320),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: _buildShellCard(colors, height: 384),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: _buildShellCard(colors, height: 60),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: colors.text,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  '正在准备编辑界面',
                  style: TextStyle(color: colors.textSecondary, fontSize: 13),
                ),
              ],
            ),
            const SizedBox(height: 48),
          ],
        ),
      ),
    );
  }

  Widget _buildShellCard(MoeColors colors, {required double height}) {
    // 与真实卡片（ContactEditCard / MoeSettingsGroup）同色，避免骨架屏闪出第三种背景色
    return MoeContentSurface(
      border: BorderSide(
        color: colors.border.withValues(alpha: 0.06),
        width: 0.6,
      ),
      child: SizedBox(height: height),
    );
  }

  // ==================== 自动保存 ====================

  void _scheduleAutoSave() => autoSave.changed();

  Future<bool> _flushAutoSave() => autoSave.flush();

  String _buildEditSignature(ContactEditResult result) {
    final plugins = result.enabledPlugins?.join(',') ?? '__all__';
    return moeAutoSaveSignature([
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
      result.recipeId ?? '',
      '${result.clearAvatarUrl}',
      '${result.clearCharacterImage}',
      '${result.clearChatBackgroundImage}',
      '${result.clearSelfAddress}',
      '${result.clearAddressUser}',
      '${result.clearVoiceFile}',
      '${result.clearDescription}',
      '${result.clearEnabledPlugins}',
      '${result.clearRecipeId}',
    ]);
  }

  // ==================== 导航栏 ====================

  List<Widget> _buildNavActions(MoeColors colors) {
    switch (widget.editMode) {
      case EditMode.create:
        return [
          _buildCircleButton(
            icon: Icons.check,
            onTap: _importingCard || _importingPreset || _submitting
                ? null
                : _onSave,
            tooltip: '创建角色',
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
            tooltip: '另存为',
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

  /// Circular translucent action button
  Widget _buildCircleButton({
    required IconData icon,
    required VoidCallback? onTap,
    String? tooltip,
  }) {
    return IconButton(
      tooltip: tooltip ?? (icon == Icons.check ? '保存' : '更多'),
      icon: Icon(icon, color: context.moeColors.primary),
      onPressed: onTap,
    );
  }

  // ==================== 退出处理 ====================

  Future<void> _handleBack() async {
    FocusScope.of(context).unfocus();
    if (await autoSave.flush() && mounted) Navigator.of(context).pop();
  }

  void _allowAndPop<T extends Object?>([T? result]) {
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
      onChanged: (value) {
        if (mounted) controller.text = value;
      },
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
            ImageCropDialog(imageBytes: originalBytes, fileName: file.name),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final fadeAnimation = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOut,
          );
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

  // ==================== 导入酒馆角色卡 ====================

  Widget _buildTavernCardImportButton() {
    return OutlinedButton.icon(
      onPressed: _importingCard ? null : _showTavernCardImportSheet,
      icon: _importingCard
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.file_download_outlined),
      label: Text(_importingCard ? '正在导入…' : '导入酒馆角色卡'),
    );
  }

  Widget _buildTavernPresetImportButton() {
    return OutlinedButton.icon(
      onPressed: _importTavernPresetAndBind,
      icon: const Icon(Icons.tune),
      label: const Text('导入绑定新预设'),
    );
  }

  /// 复用酒馆插件页的导入流程，导入后直接绑定到当前角色卡。
  Future<void> _importTavernPresetAndBind() async {
    setState(() => _importingPreset = true);
    try {
      await runTavernAction(context, () async {
        final preset = await importTavernPresetWithPreview(context, ref);
        if (preset == null || !mounted) return;
        setState(() => _selectedRecipeId = preset.id);
        _scheduleAutoSave();
        MoeToast.success(context, '已导入并绑定「${preset.name}」');
      });
    } finally {
      if (mounted) setState(() => _importingPreset = false);
    }
  }

  void _showTavernCardImportSheet() {
    showMoeActionSheet(
      context: context,
      actions: [
        MoeSheetAction(
          label: '从图片导入',
          subtitle: 'PNG 角色卡或角色卡 JSON',
          icon: Icons.image_outlined,
          onTap: () => unawaited(_importTavernCardFromFile()),
        ),
        MoeSheetAction(
          label: '从链接导入',
          subtitle: '角色卡直链或 chub.ai 角色页',
          icon: Icons.link,
          onTap: () => unawaited(_importTavernCardFromUrl()),
        ),
      ],
    );
  }

  Future<void> _importTavernCardFromFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['png', 'json'],
      withData: true,
    );
    final bytes = result?.files.firstOrNull?.bytes;
    if (bytes == null) return;
    await _runTavernCardImport(
      () async => SillyTavernCharacterCard.parseBytes(bytes),
    );
  }

  Future<void> _importTavernCardFromUrl() async {
    final urlCtrl = TextEditingController();
    final confirmed = await showMeoTalkDialog(
      context: context,
      title: '从链接导入',
      confirmText: '导入',
      content: MoeTextField(
        controller: urlCtrl,
        hint: 'https://…',
        autofocus: true,
        keyboardType: TextInputType.url,
      ),
    );
    final url = urlCtrl.text.trim();
    urlCtrl.dispose();
    if (confirmed != true || url.isEmpty) return;
    await _runTavernCardImport(
      () => SillyTavernCharacterCardLoader().load(url),
    );
  }

  Future<void> _runTavernCardImport(
    Future<SillyTavernCharacterCard> Function() load,
  ) async {
    setState(() => _importingCard = true);
    try {
      final card = await load();
      if (!mounted) return;
      _applyTavernCard(card);
      if (card.greetings.length > 1) await _pickGreeting();
      if (!mounted) return;
      MoeToast.success(context, _cardImportedMessage(card));
    } catch (e) {
      if (!mounted) return;
      MoeToast.error(context, e is FormatException ? e.message : '导入失败：$e');
    } finally {
      if (mounted) setState(() => _importingCard = false);
    }
  }

  static String _cardImportedMessage(SillyTavernCharacterCard card) {
    final resources = [
      if (card.regexScripts.isNotEmpty) '${card.regexScripts.length} 条正则',
      if (card.characterBook != null) '世界书',
    ];
    if (resources.isEmpty) return '已导入「${card.name}」';
    return '已导入「${card.name}」，创建时卡内${resources.join('和')}会放进角色专用预设';
  }

  /// 角色卡图片直接用作头像与聊天背景，背景默认叠一层薄模糊。
  void _applyTavernCard(SillyTavernCharacterCard card) {
    final image = card.imageBytes;
    setState(() {
      _importedCard = card;
      if (card.usesMvu) _selectedPluginIds.add(mvuPluginId);
      _nameCtrl.text = card.name;
      _personaCtrl.text = card.composePersonaPrompt();
      _cardGreetings = card.greetings;
      _greetingIndex = 0;
      if (image != null) {
        final dataUrl = buildDataImage(image, mimeType: _sniffImageMime(image));
        _avatarCtrl.text = dataUrl;
        _refImageCtrl.clear();
        _chatBackgroundCtrl.text = dataUrl;
        _chatBackgroundBytes = image;
        _chatBackgroundBlurSigma = _kImportedBackgroundBlurSigma;
      }
    });
    _scheduleBlurEnsure();
  }

  Widget _buildGreetingPickerButton() {
    return TextButton.icon(
      onPressed: _pickGreeting,
      icon: const Icon(Icons.chat_bubble_outline, size: 18),
      label: Text(
        '开场白：第 ${_greetingIndex + 1} 套（共 ${_cardGreetings.length} 套）',
      ),
    );
  }

  /// 关闭弹窗视为沿用当前所选（默认主开场白）。
  Future<void> _pickGreeting() async {
    final index = await showTavernGreetingPicker(
      context,
      greetings: _cardGreetings,
      selectedIndex: _greetingIndex,
    );
    if (index == null || !mounted) return;
    setState(() => _greetingIndex = index);
  }

  static String _sniffImageMime(Uint8List bytes) {
    if (SillyTavernCharacterCard.isPng(bytes)) return 'image/png';
    if (bytes.length > 2 && bytes[0] == 0xFF && bytes[1] == 0xD8) {
      return 'image/jpeg';
    }
    if (bytes.length > 12 &&
        String.fromCharCodes(bytes.sublist(8, 12)) == 'WEBP') {
      return 'image/webp';
    }
    if (bytes.length > 3 &&
        String.fromCharCodes(bytes.sublist(0, 3)) == 'GIF') {
      return 'image/gif';
    }
    return 'image/png';
  }

  // ==================== 保存逻辑 ====================

  ContactEditResult _buildEditResult() {
    final name = _nameCtrl.text.trim();
    final avatar = _avatarCtrl.text.trim().isEmpty
        ? null
        : _avatarCtrl.text.trim();

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
    final description = _descCtrl.text.trim().isEmpty
        ? null
        : _descCtrl.text.trim();
    final personaPrompt = PersonaPromptCodec.compose(
      userPrompt: _personaCtrl.text.trim(),
      customDrawingPrompt: _customDrawingPromptCtrl.text.trim(),
      drawingPresetId: _drawingPresetId,
      drawingToolPresetName: _drawingBindingChanged
          ? null
          : _legacyDrawingParts.drawingToolPresetName,
      drawingArtistPresetName: _drawingBindingChanged
          ? null
          : _legacyDrawingParts.drawingArtistPresetName,
    );
    final voiceFile = (_boundVoiceId == null || _boundVoiceId!.trim().isEmpty)
        ? null
        : _boundVoiceId!.trim();
    final enabledPlugins = _buildEnabledPlugins();
    final recipeId = _selectedRecipeId;

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
      recipeId: recipeId,
      clearAvatarUrl: avatar == null,
      clearCharacterImage: characterImage == null,
      clearChatBackgroundImage: chatBackgroundImage == null,
      clearSelfAddress: selfAddress == null,
      clearAddressUser: addressUser == null,
      clearVoiceFile: voiceFile == null,
      clearDescription: description == null,
      clearEnabledPlugins: enabledPlugins == null,
      clearRecipeId: recipeId == null && widget.conversation.recipeId != null,
    );
  }

  List<String>? _buildEnabledPlugins() {
    final allKnown = conversationScopedChatPluginItems.map((e) => e.id).toSet();
    final unknown = [
      for (final id in _selectedPluginIds)
        if (!allKnown.contains(id)) id,
    ];
    final selectedKnownCount = _selectedPluginIds
        .where(allKnown.contains)
        .length;

    if (selectedKnownCount == allKnown.length && unknown.isEmpty) {
      return null;
    }

    final ordered = <String>[
      for (final item in conversationScopedChatPluginItems)
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
    await ref.read(conversationsProvider.future);
    await ref
        .read(conversationsProvider.notifier)
        .applyContactEdit(
          id,
          displayName: result.displayName,
          avatarUrl: result.avatarUrl,
          clearAvatarUrl: result.clearAvatarUrl,
          characterImage: result.characterImage,
          clearCharacterImage: result.clearCharacterImage,
          chatBackgroundImage: result.chatBackgroundImage,
          clearChatBackgroundImage: result.clearChatBackgroundImage,
          clearChatBackgroundMaskOpacity: result.clearChatBackgroundImage,
          chatBackgroundBlurSigma: result.clearChatBackgroundImage
              ? null
              : _chatBackgroundBlurSigma,
          clearChatBackgroundBlurSigma: result.clearChatBackgroundImage,
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
          recipeId: result.recipeId,
          clearRecipeId: result.clearRecipeId,
        );
  }

  Future<void> _onSave() async {
    if (_submitting || _importingCard || _importingPreset) return;
    if (!_validateForm()) return;
    final result = _buildEditResult();

    if (widget.editMode != EditMode.create) {
      _allowAndPop<ContactEditResult>(result);
      return;
    }
    setState(() => _submitting = true);
    try {
      await _createRole(result);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// 创建角色；角色落库后，专用预设与开场白任一步失败只提示，不阻止进入聊天。
  Future<void> _createRole(ContactEditResult result) async {
    // 提交开始即冻结本次要用的卡与开场白，导入中途改动不影响这次提交。
    final card = _importedCard;
    final greeting = _cardGreetings.isEmpty
        ? null
        : _cardGreetings[_greetingIndex];
    final controller = ref.read(presetRecipeImportControllerProvider.notifier);
    final withResources = card != null && card.hasPresetResources;

    final notifier = ref.read(conversationsProvider.notifier);
    final String id;
    try {
      id = _createdId ??= await notifier.createNew();
      await _applyResult(id, result);
    } catch (e) {
      if (mounted) MoeToast.error(context, '创建角色失败，请重试：$e');
      return;
    }

    final problems = <String>[];
    var recipeId = result.recipeId;
    if (withResources) {
      try {
        final created = await controller.createCardPreset(
          explicitBaseId: result.recipeId,
          name: '${result.displayName} 专用',
          regexScripts: card.regexScripts,
          characterBook: card.characterBook,
          // 导入卡即视为要用卡内正则：直接允许运行，之后在预设里逐条管理。
          regexAuthorized: card.regexScripts.isNotEmpty ? true : null,
        );
        try {
          await notifier.applyContactEdit(id, recipeId: created.preset.id);
          recipeId = created.preset.id;
          problems.addAll(created.warnings);
          if (created.skippedRegexCount > 0) {
            problems.add('${created.skippedRegexCount} 条卡内正则与原预设重复或无效，已跳过');
          }
        } catch (e) {
          await controller.deletePreset(created.preset.id).catchError((_) {});
          problems.add('专用预设绑定失败：$e');
        }
      } catch (e) {
        problems.add('专用预设未建立：$e');
      }
    }
    if (card != null && card.hasHelperScripts) {
      problems.add('卡内酒馆助手脚本（变量系统、状态栏）无法运行');
    }
    if (greeting != null) {
      try {
        await ref
            .read(chatPageConversationActionsProvider)
            .appendCharacterGreeting(
              id,
              greeting: greeting,
              charName: result.displayName,
              recipeId: recipeId,
            );
      } catch (e) {
        problems.add('开场白未写入：$e');
      }
    }

    ref.read(activeConversationIdProvider.notifier).state = id;
    if (!mounted) return;
    if (problems.isNotEmpty) {
      MoeToast.warning(context, '角色已创建。${problems.join('；')}');
    }
    final conversation = ref.read(resolvedConversationByIdProvider(id));
    context.replace('/chat/$id', extra: conversation);
  }

  Future<void> _onSaveAsNewTemplate() async {
    if (_enableAutoSave) {
      if (!await _flushAutoSave()) return;
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
