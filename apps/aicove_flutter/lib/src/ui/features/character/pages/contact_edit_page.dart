import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../../../shared/animations/parallax_slide_page_route.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../features/chat/conversation_providers.dart';
import '../../../../features/backup/backup_providers.dart';
import '../../../../features/backup/models/export_format.dart';
import '../../backup/pages/export_character_page.dart';
import '../../backup/pages/import_file_page.dart';
import '../../debug/pages/contact_context_page.dart';
import '../../../../core/utils/avatar_helper.dart';
import '../../../../core/utils/blurred_background_service.dart';
import '../../../../core/utils/data_image.dart';
import '../../../../features/agent_context/data/silly_tavern_character_card_loader.dart';
import '../../../../features/agent_context/domain/silly_tavern_character_card.dart';
import '../../../../features/assistant/domain/assistant_onboarding.dart'
    show kAicoveAssistantId;
import '../../../../features/chat/domain/conversation.dart';
import '../../../../features/chat/domain/role_agent_mode.dart';
import '../../../../features/chat/domain/persona_prompt_codec.dart';
import '../../../../features/chat/presentation/widgets/contact_edit_dialog.dart';
import '../../../../features/chat/providers2.dart';
import '../../../../features/plugins/plugin_providers.dart';
import '../../../../ui/features/settings/pages/chat_plugin_settings_page.dart';
import '../../plugins/widgets/tavern_common.dart';
import '../../chat/widgets/chat_wallpaper_background.dart';
import '../../wallpaper/pages/wallpaper_editor_page.dart';
import '../../wallpaper/widgets/wallpaper_preview_samples.dart';
import '../widgets/avatar_name_section.dart';
import 'character_appearance_page.dart';
import 'contact_memory_page.dart';
import '../services/contact_edit_snapshot_store.dart';
import '../../../../features/chat/application/contact_edit_role_actions.dart';

import '../widgets/role_prompt_section.dart';
import 'role_extra_prompt_page.dart';
import '../widgets/character_agent_mode_section.dart';
import '../widgets/character_plugins_section.dart';
import '../widgets/character_text_editor_sheet.dart';
import '../widgets/tavern_greeting_picker_sheet.dart';
import '../../../../features/plugins/mcp/mcp_connector.dart';
import '../../../../features/plugins/packages/aicove_package.dart';
import '../../../../features/plugins/time_awareness/time_awareness_role_options.dart';
import '../../../../features/stickers/sticker_pack_grants.dart';
import '../../../../features/workspace/domain/workspace_grants.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/widgets/index.dart';

part 'contact_edit_page_sections.dart';

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

  /// Starts importing a character card as soon as the page opens: from
  /// [importCardUrl] when given, else from a file the user picks.
  final bool importCardOnOpen;
  final String? importCardUrl;

  const ContactEditPage({
    super.key,
    required this.conversation,
    this.initialSnapshot,
    this.importCardOnOpen = false,
    this.importCardUrl,
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
  late final TextEditingController _extraPromptCtrl;
  late final TextEditingController _drawingPromptCtrl;
  String? _drawingPromptPackId;
  String? _drawingPresetId;
  late PersonaPromptParts _legacyDrawingParts;
  bool _drawingBindingChanged = false;
  late final TextEditingController _selfAddressCtrl;
  late final TextEditingController _addressUserCtrl;
  late final TextEditingController _avatarCtrl;
  late final TextEditingController _refImageCtrl;
  late final TextEditingController _chatBackgroundCtrl;

  /// 角色壁纸的遮罩、模糊与截取，与 [_chatBackgroundCtrl] 一起保存；
  /// 为 null 表示没调过（有图取聊天默认值，跟随全局壁纸时沿用全局的）。
  late WallpaperStyle? _wallpaperStyle;
  bool _importingCard = false;
  bool _exportingCard = false;
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
  late RoleAgentMode _agentMode;
  String? _boundVoiceId;
  String? _selectedRecipeId;
  String? _scheduledBlurSource;
  Timer? _deferredVisualsTimer;
  bool _deferHeavyVisuals = true;

  bool get _enableAutoSave => widget.editMode != EditMode.create;
  List<TextEditingController> get _autoSaveControllers => [
    _nameCtrl,
    _avatarCtrl,
    _refImageCtrl,
    _descCtrl,
    _personaCtrl,
    _extraPromptCtrl,
    _drawingPromptCtrl,
    _selfAddressCtrl,
    _addressUserCtrl,
    _chatBackgroundCtrl,
  ];

  @override
  void initState() {
    super.initState();
    if (widget.importCardOnOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final url = widget.importCardUrl;
        unawaited(
          url == null
              ? _importTavernCardFromFile()
              : _runTavernCardImport(
                  () => SillyTavernCharacterCardLoader().load(url),
                ),
        );
      });
    }
    final conv = _resolveInitialConversation();
    final personaParts = PersonaPromptCodec.parse(conv.personaPrompt);
    _legacyDrawingParts = personaParts;
    _drawingPresetId = personaParts.drawingPresetId;
    _drawingPromptPackId = personaParts.drawingPromptPackId;

    _nameCtrl = TextEditingController(text: conv.displayName);
    _descCtrl = TextEditingController(text: conv.description ?? '');
    _personaCtrl = TextEditingController(text: personaParts.userPrompt);
    _extraPromptCtrl = TextEditingController(text: personaParts.extraPrompt);
    _drawingPromptCtrl = TextEditingController(
      text: personaParts.customDrawingPrompt,
    );
    _selfAddressCtrl = TextEditingController(text: conv.selfAddress ?? '');
    _addressUserCtrl = TextEditingController(text: conv.addressUser ?? '');
    _avatarCtrl = TextEditingController(text: conv.avatarUrl ?? '');
    _refImageCtrl = TextEditingController(text: (conv.characterImage ?? ''));
    _chatBackgroundCtrl = TextEditingController(
      text: conv.chatBackgroundImage ?? '',
    );
    _wallpaperStyle = chatWallpaperOwnStyleOf(conv);
    _agentMode = conv.effectiveAgentMode;

    final allPluginIds = conversationScopedChatPluginItems
        .map((e) => e.id)
        .toSet();
    if (widget.editMode == EditMode.create) {
      // 新建角色默认只开记忆和时间感知，其余在「管理插件」中逐项开启
      _selectedPluginIds = {...kDefaultRolePluginIds};
    } else if (conv.enabledPlugins == null) {
      _selectedPluginIds = {...allPluginIds};
    } else {
      _selectedPluginIds = {
        for (final id in conv.enabledPlugins!)
          if (allPluginIds.contains(id) ||
              McpToolNaming.isConnectorPluginId(id) ||
              AicovePackage.isPackagePluginId(id) ||
              // 本机没有的工作区也保留授权（ADR0087 第 1 条）
              WorkspaceGrants.isGrantId(id) ||
              StickerPackGrants.isGrantId(id) ||
              TimeAwarenessRoleOptions.isOptionId(id))
            id,
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
    _extraPromptCtrl.dispose();
    _drawingPromptCtrl.dispose();
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
      agentMode: RoleAgentMode.fromValue(snapshot.agentMode) ??
          widget.conversation.agentMode,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        snapshot.sourceUpdatedAtMs,
      ),
    );
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

    setState(() {
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
        background: _buildPageBackground(colors),
        appBar: MoeAppBar(
          title: widget.editMode == EditMode.create ? '新建角色' : '编辑角色',
          titleWidget: _buildNameField(colors),
          centerTitle: true,
          showBackButton: true,
          leading: MoeIconButton(
            icon: Icons.arrow_back,
            tooltip: '返回',
            onTap: () => unawaited(_handleBack()),
          ),
          actions: _buildNavActions(colors),
        ),
        // 纯色背景与固定标题栏首帧呈现，较重的表单与壁纸仍延后挂载。
        body: _deferHeavyVisuals
            ? _buildDeferredShell(colors)
            : _buildEditorScrollContent(colors),
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
                onCustomize: _openAppearancePage,
              ),
            ),

            const SizedBox(height: 16),

            // 酒馆预设、已开启插件列表，末尾为「管理插件」按钮（底部弹窗逐项开关）
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: CharacterPluginsSection(
                selectedPluginIds: _selectedPluginIds,
                boundVoiceId: _boundVoiceId,
                voicePresets: voicePresets,
                drawingPersonaPrompt: _drawingPersonaPrompt(),
                selectedRecipeId: _selectedRecipeId,
                conversationId: widget.editMode == EditMode.editConversation
                    ? widget.conversation.id
                    : null,
                roleName: _nameCtrl.text,
                memoryDocAvailable:
                    widget.editMode == EditMode.editConversation,
                onOpenMemoryDoc: _openMemoryDoc,
                builtInWorkspaceIds: WorkspaceGrants.builtInFor(
                  widget.conversation.id,
                ),
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

            // 角色提示词、附加提示词（含生图偏好）
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: RolePromptSection(
                onViewSystemPrompt: _isAssistant
                    ? () => showCharacterTextEditorSheet(
                        context: context,
                        title: '系统提示词',
                        initialValue: _personaCtrl.text,
                        hint: '',
                        readOnly: true,
                      )
                    : null,
                onEditRolePrompt: () => _openFullScreenEditor(
                  title: '编辑角色提示词',
                  controller: _personaCtrl,
                  hint: '详细描述角色的性格、说话方式、行为边界和世界观...',
                ),
                onEditExtraPrompt: _openExtraPromptPage,
              ),
            ),

            // 角色模式（ADR0097）
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: CharacterAgentModeSection(
                mode: _agentMode,
                locked: _agentModeLocked,
                onChanged: (mode) {
                  setState(() => _agentMode = mode);
                  _scheduleAutoSave();
                },
              ),
            ),

            if (widget.editMode == EditMode.create) ...[
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildTavernCardImportButton(),
                    const SizedBox(height: 8),
                    _buildTavernPresetImportButton(),
                  ],
                ),
              ),
              if (_cardGreetings.length > 1) ...[
                const SizedBox(height: 8),
                Center(child: _buildGreetingPickerButton()),
              ],
            ],

            if (widget.editMode == EditMode.editConversation) ...[
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: MoeSettingsGroup(
                  margin: EdgeInsets.zero,
                  children: [
                    MoeSettingsRow(
                      label: ContactContextListPage.title,
                      showDivider: false,
                      onTap: _openContactContext,
                    ),
                  ],
                ),
              ),
            ],

            // 底部留白
            const SizedBox(height: 48),
          ],
        ),
      ),
    );
  }

  String _drawingPersonaPrompt() {
    return PersonaPromptCodec.compose(
      userPrompt: '',
      drawingPromptPackId: _drawingPromptPackId,
      drawingPresetId: _drawingPresetId,
      drawingToolPresetName: _drawingBindingChanged
          ? null
          : _legacyDrawingParts.drawingToolPresetName,
      drawingArtistPresetName: _drawingBindingChanged
          ? null
          : _legacyDrawingParts.drawingArtistPresetName,
    );
  }

  // ==================== 自动保存 ====================

  void _scheduleAutoSave() => autoSave.changed();

  void _rebuild(VoidCallback fn) => setState(fn);

  Future<bool> _flushAutoSave() => autoSave.flush();

  void _allowAndPop<T extends Object?>([T? result]) {
    Navigator.of(context).pop<T>(result);
  }

  // ==================== 保存逻辑 ====================

  bool get _isAssistant => widget.conversation.id == kAicoveAssistantId;

  bool get _agentModeLocked => _isAssistant;

  /// [mergeExtraPrompt]: fold the extra prompt into the editable persona when
  /// copying a role whose base prompt is read-only (AIcove酱).
  ContactEditResult _buildEditResult({bool mergeExtraPrompt = false}) {
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
    final extraPrompt = PersonaPromptCodec.stripMarkers(
      _extraPromptCtrl.text,
    ).trim();
    final customDrawingPrompt = PersonaPromptCodec.stripMarkers(
      _drawingPromptCtrl.text,
    ).trim();
    final shouldMergeExtra = mergeExtraPrompt && _isAssistant;
    final personaPrompt = PersonaPromptCodec.compose(
      userPrompt: shouldMergeExtra
          ? PersonaPromptParts(
              userPrompt: _personaCtrl.text,
              extraPrompt: extraPrompt,
              customDrawingPrompt: '',
            ).rolePrompt
          : _personaCtrl.text.trim(),
      extraPrompt: shouldMergeExtra ? null : extraPrompt,
      customDrawingPrompt: customDrawingPrompt,
      drawingPromptPackId: _drawingPromptPackId,
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
      // AIcove酱的模式固定，不随保存写入
      agentMode: _agentModeLocked ? null : _agentMode,
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
          chatBackgroundMaskOpacity: _wallpaperStyle?.mask,
          clearChatBackgroundMaskOpacity: _wallpaperStyle == null,
          chatBackgroundBlurSigma: _wallpaperStyle?.blur,
          clearChatBackgroundBlurSigma: _wallpaperStyle == null,
          chatBackgroundFraming: _wallpaperStyle?.encodedFraming,
          clearChatBackgroundFraming: _wallpaperStyle?.encodedFraming == null,
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
          agentMode: result.agentMode,
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
    final greeting = _cardGreetings.isEmpty
        ? null
        : _cardGreetings[_greetingIndex];
    final ContactRoleCreation created;
    try {
      created = await ref
          .read(contactEditRoleActionsProvider)
          .createRole(
            existingId: _createdId,
            onCreated: (id) => _createdId = id,
            applyEdit: (id) => _applyResult(id, result),
            displayName: result.displayName,
            recipeId: result.recipeId,
            agentMode: result.agentMode,
            isActive: () => mounted,
            card: _importedCard,
            greeting: greeting,
          );
    } catch (e) {
      if (mounted) MoeToast.error(context, '创建角色失败，请重试：$e');
      return;
    }

    if (!mounted) return;
    if (created.problems.isNotEmpty) {
      MoeToast.warning(context, '角色已创建。${created.problems.join('；')}');
    }
    final conversation = ref.read(resolvedConversationByIdProvider(created.id));
    context.replace('/chat/${created.id}', extra: conversation);
  }

  Future<void> _onSaveAsNewTemplate() async {
    if (_enableAutoSave) {
      if (!await _flushAutoSave()) return;
    }
    if (!_validateForm()) return;
    final result = _buildEditResult(mergeExtraPrompt: true);

    final notifier = ref.read(conversationsProvider.notifier);
    final id = await ref
        .read(contactEditRoleActionsProvider)
        .createConversation(result.agentMode);
    await _applyResult(id, result);
    await notifier.updateConversationSettings(id, isFavorite: true);

    if (!mounted) return;
    MoeToast.success(context, '已保存到我的角色卡');
    _allowAndPop();
  }

  /// 只打包当前角色的角色卡（含头像、立绘），不带聊天记录。
  Future<void> _onExportCharacterCard() async {
    if (_exportingCard) return;
    if (_enableAutoSave && !await _flushAutoSave()) return;
    if (!mounted) return;
    setState(() => _exportingCard = true);
    try {
      final result = await ref
          .read(conversationExporterProvider)
          .exportConversations(
            conversationIds: [widget.conversation.id],
            options: const ExportOptions(scopes: [SyncScope.characterCards]),
          );
      if (!mounted) return;
      await showExportSuccessDialog(context, result, encrypted: false);
    } catch (e) {
      if (mounted) MoeToast.error(context, '导出失败: $e');
    } finally {
      if (mounted) setState(() => _exportingCard = false);
    }
  }

  Future<void> _onImportCharacterCard() async {
    if (_enableAutoSave && !await _flushAutoSave()) return;
    if (!mounted) return;
    final id = widget.conversation.id;
    final before = ref.read(resolvedConversationByIdProvider(id));
    await Navigator.of(
      context,
    ).push(ParallaxSlidePageRoute(page: const ImportFilePage()));
    if (!mounted) return;
    await ref.read(conversationsProvider.future);
    if (!mounted) return;
    final after = ref.read(resolvedConversationByIdProvider(id));
    if (after == null || after == before) return;
    // 导入合并或覆盖了当前角色：用新数据重开本页，避免旧表单经自动保存写回。
    Navigator.of(context).pushReplacement(
      ParallaxSlidePageRoute(
        page: ContactEditPage(
          conversation: after,
          initialSnapshot: ContactEditSnapshot.fromConversation(after),
          editMode: EditMode.editConversation,
        ),
      ),
    );
  }
}
