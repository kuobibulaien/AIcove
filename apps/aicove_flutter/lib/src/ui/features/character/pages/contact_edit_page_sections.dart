part of 'contact_edit_page.dart';

extension _ContactEditPageSections on _ContactEditPageState {
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

  void _openContactContext() {
    Navigator.of(context).push(
      ParallaxSlidePageRoute(
        page: ContactContextPage(
          conversation:
              ref.read(resolvedConversationByIdProvider(widget.conversation.id)) ??
              widget.conversation,
        ),
      ),
    );
  }

  void _openExtraPromptPage() {
    Navigator.of(context).push(
      ParallaxSlidePageRoute(
        page: RoleExtraPromptPage(
          extraPromptController: _extraPromptCtrl,
          extraPromptHint: _isAssistant
              ? '想让她额外注意的事写在这里，会接在系统提示词后面...'
              : '补充在角色提示词之后，可随时调整，不会改动原角色设定...',
          drawingPromptController: _drawingPromptCtrl,
          initialPackId: _drawingPromptPackId,
          drawingPersonaPrompt: _drawingPersonaPrompt(),
          onPackChanged: (packId) {
            _rebuild(() => _drawingPromptPackId = packId);
            _scheduleAutoSave();
          },
        ),
      ),
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

  /// 页面背景：设置壁纸后与聊天页共用同一壁纸层（同一蒙层与模糊），
  /// 宽屏由工作区整窗绘制，不与左侧列表的背景割裂。
  Widget? _buildPageBackground(MoeColors colors) {
    final raw = _chatBackgroundCtrl.text.trim();
    if (_deferHeavyVisuals || raw.isEmpty) return null;
    return ChatWallpaperLayer(
      image: raw,
      fallbackColor: colors.surfaceAlt,
      style: _wallpaperStyle,
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
        MoeSheetAction(
          label: '导出角色卡',
          icon: Icons.upload_outlined,
          onTap: _onExportCharacterCard,
        ),
        MoeSheetAction(
          label: '导入角色卡',
          icon: Icons.download_outlined,
          onTap: _onImportCharacterCard,
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
    return MoeIconButton(
      tooltip: tooltip ?? (icon == Icons.check ? '保存' : '更多'),
      icon: icon,
      color: context.moeColors.primary,
      onTap: onTap,
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
      onChanged: (value) {
        if (mounted) controller.text = value;
      },
      hint: hint,
    );

    if (!mounted || result == null || result == controller.text) return;
    controller.text = result;
    _rebuild(() {});
  }

  // ==================== 图片选择 ====================

  /// 「自定义」：更换立绘与头像，并可进入聊天壁纸编辑页。
  void _openAppearancePage() {
    Navigator.of(context).push(
      ParallaxSlidePageRoute(
        page: CharacterAppearancePage(
          nameCtrl: _nameCtrl,
          avatarCtrl: _avatarCtrl,
          refImageCtrl: _refImageCtrl,
          onPickCharacterImage: _pickCharacterImage,
          onCropAvatarFromCharacter: _cropAvatarFromCharacter,
          onPickAvatar: _pickAvatar,
          onEditWallpaper: _openWallpaperEditor,
        ),
      ),
    );
  }

  /// 上传立绘（两步流程）：
  /// 1. 选择原图 → 保存为立绘（characterImage）
  /// 2. 自动弹出裁剪界面 → 裁剪结果保存为头像（avatarUrl）
  Future<void> _pickCharacterImage() async {
    final file = await _pickImageFile();
    if (file == null) return;

    // 第一步：原图保存为立绘
    _rebuild(() {
      _refImageCtrl.text = buildDataImage(file.bytes!, fileName: file.name);
    });

    // 第二步：自动打开裁剪界面，裁剪为头像
    await _cropAvatar(file.bytes!, file.name);
    _scheduleAutoSave();
  }

  /// 从当前立绘重新裁剪头像。
  Future<void> _cropAvatarFromCharacter() async {
    final source = _refImageCtrl.text.trim();
    if (source.isEmpty) return;
    final bytes = await AvatarHelper(
      characterImage: source,
      displayName: _nameCtrl.text,
    ).getAvatarBytes();
    if (!mounted) return;
    if (bytes == null) {
      MoeToast.error(context, '读取立绘失败，请重新上传立绘');
      return;
    }
    if (await _cropAvatar(bytes, 'avatar.png')) _scheduleAutoSave();
  }

  /// 单独上传一张图片裁剪为头像，不改立绘。
  Future<void> _pickAvatar() async {
    final file = await _pickImageFile();
    if (file == null) return;
    if (await _cropAvatar(file.bytes!, file.name)) _scheduleAutoSave();
  }

  Future<PlatformFile?> _pickImageFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
    );
    final file = result?.files.firstOrNull;
    if (file?.bytes == null) return null;
    return file;
  }

  /// 打开裁剪界面，确认后把结果写成头像；返回是否已更新头像。
  Future<bool> _cropAvatar(Uint8List bytes, String fileName) async {
    if (!mounted) return false;
    final croppedBytes = await Navigator.of(context).push<Uint8List>(
      PageRouteBuilder(
        opaque: false,
        barrierDismissible: false,
        barrierColor: Colors.black,
        transitionDuration: kAnim,
        reverseTransitionDuration: kAnim,
        pageBuilder: (context, animation, secondaryAnimation) =>
            ImageCropDialog(imageBytes: bytes, fileName: fileName),
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
    if (croppedBytes == null || !mounted) return false;
    _rebuild(() {
      _avatarCtrl.text = buildDataImage(croppedBytes, fileName: fileName);
    });
    return true;
  }

  // ==================== 壁纸与样式 ====================

  /// 编辑页示例里显示的头像与名字，取当前未保存的输入。
  Conversation _buildPreviewConversation() {
    final name = _nameCtrl.text.trim();
    final avatar = _avatarCtrl.text.trim();
    return widget.conversation.copyWith(
      displayName: name.isEmpty ? null : name,
      avatarUrl: avatar.isEmpty ? null : avatar,
    );
  }

  /// 「自定义」：在共用的壁纸编辑页里换角色壁纸、调遮罩模糊与截取。
  void _openWallpaperEditor() {
    final raw = _chatBackgroundCtrl.text.trim();
    MoeWorkspace.open(
      context,
      WallpaperEditorPage(
        source: raw.isEmpty ? null : raw,
        style:
            _wallpaperStyle ??
            (raw.isEmpty
                ? MoeWallpaperTheme.maybeOf(context)?.style ??
                      const WallpaperStyle()
                : kDefaultChatWallpaperStyle),
        defaultStyle: kDefaultChatWallpaperStyle,
        followStyle: MoeWallpaperTheme.maybeOf(context)?.style,
        kind: WallpaperPreviewKind.chat,
        conversation: _buildPreviewConversation(),
        canChangeImage: true,
        onSave: (source, style) async {
          if (!mounted) return;
          _rebuild(() {
            _chatBackgroundCtrl.text = source?.trim() ?? '';
            _wallpaperStyle = style;
          });
          if (_enableAutoSave) await autoSave.flush();
        },
      ),
    );
  }

  // ==================== 导入酒馆角色卡 ====================

  Widget _buildTavernCardImportButton() {
    return MoeSecondaryButton(
      onPressed: _importingCard ? null : _showTavernCardImportSheet,
      icon: _importingCard ? null : Icons.file_download_outlined,
      label: _importingCard ? '正在导入…' : '导入酒馆角色卡',
      size: MoeSecondaryButtonSize.sm,
    );
  }

  Widget _buildTavernPresetImportButton() {
    return MoeSecondaryButton(
      onPressed: _importTavernPresetAndBind,
      icon: Icons.tune,
      label: '导入绑定新预设',
      size: MoeSecondaryButtonSize.sm,
    );
  }

  /// 复用酒馆插件页的导入流程，导入后直接绑定到当前角色卡。
  Future<void> _importTavernPresetAndBind() async {
    _rebuild(() => _importingPreset = true);
    try {
      await runTavernAction(context, () async {
        final preset = await importTavernPresetWithPreview(context, ref);
        if (preset == null || !mounted) return;
        _rebuild(() => _selectedRecipeId = preset.id);
        _scheduleAutoSave();
        MoeToast.success(context, '已导入并绑定「${preset.name}」');
      });
    } finally {
      if (mounted) _rebuild(() => _importingPreset = false);
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
    _rebuild(() => _importingCard = true);
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
      if (mounted) _rebuild(() => _importingCard = false);
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
    _rebuild(() {
      _importedCard = card;
      _nameCtrl.text = card.name;
      _personaCtrl.text = card.composePersonaPrompt();
      _cardGreetings = card.greetings;
      _greetingIndex = 0;
      if (image != null) {
        final dataUrl = buildDataImage(image, mimeType: sniffContactImageMime(image));
        _avatarCtrl.text = dataUrl;
        _refImageCtrl.clear();
        _chatBackgroundCtrl.text = dataUrl;
        _wallpaperStyle = const WallpaperStyle(
          mask: kDefaultChatWallpaperMask,
          blur: _kImportedBackgroundBlurSigma,
        );
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
    _rebuild(() => _greetingIndex = index);
  }

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
      result.agentMode?.name ?? '',
      _wallpaperStyle?.toJson(),
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

  // ==================== 退出处理 ====================

  Future<void> _handleBack() async {
    FocusScope.of(context).unfocus();
    if (await autoSave.flush() && mounted) Navigator.of(context).pop();
  }
}
