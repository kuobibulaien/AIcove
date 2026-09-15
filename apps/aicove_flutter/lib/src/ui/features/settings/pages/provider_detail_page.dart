/// ProviderDetailPage - 供应商详情页
///
/// 显示和编辑单个供应商的配置和模型列表。
///
/// 设计特点：
/// - 顶部：品牌头像 + 名称 + 能力标签
/// - 底部双 Tab：「配置」+「模型」
/// - 操作按钮：测试连接、删除
///
/// 更新记录：
/// - 2026-01-21: 创建供应商详情页
library;

export 'multi_key_manager_page.dart' show MultiKeyManagerPage;

import 'dart:collection';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/form/moe_input_decoration.dart';
import 'package:aicove_flutter/src/ui/shared/animations/parallax_slide_page_route.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/settings/app_settings.dart';
import '../../../../features/settings/provider_detail/provider_detail_actions.dart';
import '../../../../features/settings/provider_detail/provider_detail_support.dart';
import '../../../theme/tokens.dart';
import '../../../shared/widgets/index.dart';
import '../widgets/model_row_tile.dart';
import '../widgets/model_picker_sheet.dart';
import '../widgets/model_test_sheet.dart';
import 'multi_key_manager_page.dart';

/// 供应商详情页
class ProviderDetailPage extends ConsumerStatefulWidget {
  const ProviderDetailPage({super.key, required this.providerId});

  /// 供应商 ID
  final String providerId;

  @override
  ConsumerState<ProviderDetailPage> createState() => _ProviderDetailPageState();
}

class _ProviderDetailPageState extends ConsumerState<ProviderDetailPage>
    with MoeAutoSaveState<ProviderDetailPage> {
  int _tabIndex = 0;
  final PageController _pageController = PageController();

  // 配置表单
  late TextEditingController _nameController;
  late TextEditingController _urlController;
  late TextEditingController _pathController;
  late TextEditingController _keyController;
  late FocusNode _nameFocusNode;
  late FocusNode _urlFocusNode;
  late FocusNode _pathFocusNode;
  late FocusNode _keyFocusNode;

  bool _autoSaveReady = false;
  String _lastSavedName = '';
  String _lastSavedUrl = '';
  String _lastSavedPath = '';
  String _lastSavedKey = '';
  String? _cachedModelEntriesSignature;
  List<_ProviderModelEntry>? _cachedModelEntries;

  ProviderDetailActions get _actions => ref.read(providerDetailActionsProvider);

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
    _urlController = TextEditingController();
    _pathController = TextEditingController();
    _keyController = TextEditingController();
    _nameFocusNode = FocusNode();
    _urlFocusNode = FocusNode();
    _pathFocusNode = FocusNode();
    _keyFocusNode = FocusNode();
    _restoreWarmCacheFromLoadedSettings();
  }

  @override
  void dispose() {
    _pageController.dispose();
    _nameController.dispose();
    _urlController.dispose();
    _pathController.dispose();
    _keyController.dispose();
    _nameFocusNode.dispose();
    _urlFocusNode.dispose();
    _pathFocusNode.dispose();
    _keyFocusNode.dispose();
    super.dispose();
  }

  void _restoreWarmCacheFromLoadedSettings() {
    final settings = ref.read(appSettingsProvider).valueOrNull;
    if (settings == null) return;
    final provider = settings.getProvider(widget.providerId);
    if (provider == null) return;
    _adoptWarmCacheIfAvailable(provider, settings.modelDisplayNames);
  }

  bool _adoptWarmCacheIfAvailable(
    ProviderAuth provider,
    Map<String, String> displayNames,
  ) {
    final signature = _buildProviderDetailWarmSignature(provider, displayNames);
    final cached = _ProviderDetailWarmCache.read(
      providerId: provider.id,
      signature: signature,
    );
    if (cached == null) return false;

    _cachedModelEntriesSignature = signature;
    _cachedModelEntries = cached.modelEntries;
    return true;
  }

  String _resolvePrimaryApiKey(ProviderAuth provider) {
    return _actions.resolvePrimaryApiKey(provider);
  }

  void _syncControllersFromProvider(ProviderAuth provider) {
    if (_autoSaveReady && (autoSave.pending || autoSave.saving)) return;
    final desiredName = provider.displayName ?? '';
    final desiredUrl = provider.apiBaseUrl;
    final desiredPath = resolveProviderDetailChatApiPath(provider);
    final desiredKey = _resolvePrimaryApiKey(provider);

    _syncControllerIfNotFocused(_nameController, _nameFocusNode, desiredName);
    _syncControllerIfNotFocused(_urlController, _urlFocusNode, desiredUrl);
    _syncControllerIfNotFocused(_pathController, _pathFocusNode, desiredPath);
    _syncControllerIfNotFocused(_keyController, _keyFocusNode, desiredKey);

    _lastSavedName = desiredName.trim();
    _lastSavedUrl = desiredUrl.trim();
    _lastSavedPath = desiredPath.trim();
    _lastSavedKey = desiredKey.trim();
    autoSave.configure(
      snapshot: () => moeAutoSaveSignature([
        _nameController.text,
        _urlController.text,
        _pathController.text,
        _keyController.text,
      ]),
      fields: [
        _nameController,
        _urlController,
        _pathController,
        _keyController,
      ],
      save: () async {
        final current = ref
            .read(appSettingsProvider)
            .valueOrNull
            ?.getProvider(widget.providerId);
        if (current == null) throw const FormatException('渠道不存在');
        await _autoSave(current);
      },
    );
    _autoSaveReady = true;
  }

  void _syncControllerIfNotFocused(
    TextEditingController controller,
    FocusNode focusNode,
    String value,
  ) {
    if (focusNode.hasFocus) return;
    if (controller.text == value) return;
    controller.value = controller.value.copyWith(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
      composing: TextRange.empty,
    );
  }

  void _scheduleAutoSave(ProviderAuth provider) => autoSave.changed();

  Future<void> _autoSave(ProviderAuth provider) async {
    final multiKeyEnabled = isProviderMultiKeyEnabled(provider);
    final name = _nameController.text.trim();
    final url = _urlController.text.trim();
    final path = _pathController.text.trim();
    final key = _keyController.text.trim();
    final hasChanges =
        name != _lastSavedName ||
        url != _lastSavedUrl ||
        path != _lastSavedPath ||
        (!multiKeyEnabled && key != _lastSavedKey);

    if (!hasChanges) return;

    await _actions.autoSaveProvider(
      provider: provider,
      displayName: name,
      apiBaseUrl: url,
      apiPath: path,
      apiKey: key,
    );
    _lastSavedName = name;
    _lastSavedUrl = url;
    _lastSavedPath = path;
    _lastSavedKey = key;
  }

  void _onTabChanged(int index) {
    setState(() => _tabIndex = index);
    _pageController.animateToPage(
      index,
      duration: kAnim,
      curve: Curves.easeOutCubic,
    );
  }

  void _onPageChanged(int index) {
    setState(() => _tabIndex = index);
  }

  Future<void> _testConnection(ProviderAuth provider) async {
    if (provider.visibleModels.isEmpty) {
      MoeToast.show(context, '当前渠道没有可用模型', type: ToastType.error);
      return;
    }

    final apiKey = _actions.resolvePrimaryApiKey(provider);
    if (apiKey.isEmpty) {
      MoeToast.show(context, '请先配置可用 API Key', type: ToastType.error);
      return;
    }

    await showModelTestSheet(context, ref, provider: provider, apiKey: apiKey);
  }

  Future<void> _deleteProvider(ProviderAuth provider) async {
    final confirmed = await showMeoTalkDialog(
      context: context,
      title: '删除渠道',
      content: Text('确定要删除「${provider.displayName}」吗？此操作无法撤销。'),
      confirmText: '删除',
      cancelText: '取消',
    );
    if (confirmed == true && mounted) {
      await _actions.deleteProvider(provider.id);
      if (mounted) {
        Navigator.of(context).pop();
        MoeToast.show(context, '已删除');
      }
    }
  }

  Future<void> _toggleEnabled(ProviderAuth provider) async {
    await _actions.setProviderEnabled(provider, !provider.enabled);
    HapticFeedback.lightImpact();
  }

  Future<void> _toggleMultiKeyMode(ProviderAuth provider, bool enabled) async {
    await _actions.setProviderMultiKeyMode(provider, enabled: enabled);
    if (!mounted) return;
    MoeToast.show(context, enabled ? '已开启多 Key 模式' : '已关闭多 Key 模式');
  }

  Future<void> _openMultiKeyManager(ProviderAuth provider) async {
    await Navigator.of(context).push(
      ParallaxSlidePageRoute(
        page: MultiKeyManagerPage(providerId: provider.id),
      ),
    );
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _showRequestFormatSheet(ProviderAuth provider) async {
    final settings = ref.read(appSettingsProvider).valueOrNull;
    var selected = resolveProviderDetailRequestFormat(
      provider,
      settings: settings,
    );
    final availableFormats = ProviderDetailRequestFormat.forProvider(
      provider,
      settings: settings,
    );
    if (availableFormats.length <= 1) {
      return;
    }

    await showMoeBottomSheet(
      context: context,
      title: 'API 格式',
      showCloseButton: true,
      isDismissible: false,
      enableDrag: false,
      builder: (context) => MoeAutoSaveForm(
        snapshot: () => selected,
        save: () async {
          final format = selected;
          final nextPath = defaultProviderDetailChatApiPathForFormat(format);
          await _actions.updateRequestFormat(provider, format, nextPath);
          if (!mounted) return;
          _syncControllerIfNotFocused(
            _pathController,
            _pathFocusNode,
            nextPath,
          );
          _lastSavedPath = nextPath;
        },
        builder: (context, setSheetState) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              MoeToggleBar<ProviderDetailRequestFormat>(
                value: selected,
                items: availableFormats
                    .map(
                      (e) => MoeToggleItem<ProviderDetailRequestFormat>(
                        value: e,
                        label: e.label,
                      ),
                    )
                    .toList(),
                onChanged: (value) {
                  setSheetState(() => selected = value);
                },
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _onReorderModels(
    ProviderAuth provider,
    int oldIndex,
    int newIndex,
  ) async {
    if (oldIndex == newIndex) return;

    final visible = _resolveModelEntries(
      provider,
      ref.read(appSettingsProvider).value?.modelDisplayNames ??
          const <String, String>{},
    ).map((entry) => entry.modelId).toList(growable: false);

    // ReorderableListView 的 newIndex 需要调整
    if (newIndex > oldIndex) {
      newIndex -= 1;
    }

    final reordered = List<String>.from(visible);
    final item = reordered.removeAt(oldIndex);
    reordered.insert(newIndex, item);

    // 更新模型顺序
    await _actions.reorderModels(provider: provider, modelIds: reordered);
  }

  Future<void> _showAddCustomModelDialog(ProviderAuth provider) async {
    final modelController = TextEditingController();
    final displayNameController = TextEditingController();

    final confirmed = await showMeoTalkDialog(
      context: context,
      title: '添加自定义模型',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: modelController,
            decoration: const InputDecoration(
              labelText: '模型 ID',
              hintText: '例如: gpt-4o-mini',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: displayNameController,
            decoration: const InputDecoration(
              labelText: '显示名称（可选）',
              hintText: '例如: GPT-4o Mini',
            ),
          ),
        ],
      ),
      confirmText: '添加',
      cancelText: '取消',
    );

    if (confirmed == true && mounted) {
      final modelId = modelController.text.trim();
      if (modelId.isEmpty) {
        MoeToast.show(context, '请输入模型 ID', type: ToastType.error);
        return;
      }

      final displayName = displayNameController.text.trim();

      // 添加自定义模型到供应商
      await _actions.addCustomModel(
        provider: provider,
        modelId: modelId,
        displayName: displayName.isNotEmpty ? displayName : null,
      );

      if (mounted) {
        MoeToast.show(context, '已添加模型: $modelId');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(appSettingsProvider);
    final colors = context.moeColors;

    return settingsAsync.when(
      loading: () => MoePageScaffold(
        backgroundColor: colors.surface,
        appBar: const MoeAppBar(title: '渠道详情', showBackButton: true),
        body: const Center(child: MoeLoadingIndicator()),
      ),
      error: (e, _) => MoePageScaffold(
        backgroundColor: colors.surface,
        appBar: const MoeAppBar(title: '渠道详情', showBackButton: true),
        body: MoeEmptyState(title: '加载失败', description: e.toString()),
      ),
      data: (settings) {
        final provider = settings.providers.firstWhere(
          (p) => p.id == widget.providerId,
          orElse: () => const ProviderAuth(
            id: '',
            displayName: '',
            apiBaseUrl: '',
            apiKeys: [],
          ),
        );

        if (provider.id.isEmpty) {
          return const MoePageScaffold(
            appBar: MoeAppBar(title: '供应商详情'),
            body: MoeEmptyState(title: '供应商不存在'),
          );
        }

        _syncControllersFromProvider(provider);
        final modelEntries = _resolveModelEntries(
          provider,
          settings.modelDisplayNames,
        );

        return _buildContent(context, provider, colors, modelEntries);
      },
    );
  }

  Widget _buildContent(
    BuildContext context,
    ProviderAuth provider,
    MoeColors colors,
    List<_ProviderModelEntry> modelEntries,
  ) {
    const bottomBarPadding = EdgeInsets.fromLTRB(16, 10, 16, 12);
    const bottomTabsHeight = 80.0;
    const bottomTabsWidthFactor = 0.90;

    final safeBottom = MediaQuery.paddingOf(context).bottom;
    final bottomBarBaseHeight =
        safeBottom + bottomBarPadding.vertical + bottomTabsHeight;
    final configBottomPadding = bottomBarBaseHeight + MoeSpacing.xl;
    final modelsBottomPadding =
        bottomBarBaseHeight + MoeButtonSizes.md + MoeSpacing.sm + MoeSpacing.xl;

    return autoSavePage(
      MoePageScaffold(
        backgroundColor: colors.surface,
        // 让内容区域延伸到屏幕底部，这样底部控件才是真“悬浮”在列表上方，而不是用一整块背景把列表截断
        extendBody: true,
        // 固定底部切换框：键盘弹出时不把底部顶上去（与 kelivo 行为一致）
        resizeToAvoidBottomInset: false,
        appBar: MoeAppBar(
          title: '渠道详情',
          showBackButton: true,
          actions: [
            IconButton(
              icon: Icon(Icons.speed_outlined, color: colors.text),
              tooltip: '测试模型',
              onPressed: () => _testConnection(provider),
            ),
            IconButton(
              icon: Icon(Icons.delete_outline, color: colors.text),
              tooltip: '删除',
              onPressed: () => _deleteProvider(provider),
            ),
          ],
        ),
        body: Column(
          children: [
            const SizedBox(height: 8),
            // 顶部信息卡片 - 仍然使用 MoeSettingsGroup 包装以保持一致性
            MoeSettingsGroup(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              padding: const EdgeInsets.all(12),
              children: [
                Row(
                  children: [
                    ProviderAvatar(
                      providerName: provider.displayName ?? provider.id,
                      size: ProviderAvatarSize.lg,
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            provider.displayName ?? provider.id,
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: MoeFontWeights.emphasis,
                              color: colors.text,
                            ),
                          ),
                          const SizedBox(height: 6),
                          CapabilityChips(
                            capabilities: provider.capabilities,
                            size: CapabilityChipSize.md,
                          ),
                        ],
                      ),
                    ),
                    MoeSwitch(
                      value: provider.enabled,
                      onChanged: (_) => _toggleEnabled(provider),
                    ),
                  ],
                ),
              ],
            ),

            const SizedBox(height: 8),

            // 内容区
            Expanded(
              child: PageView(
                controller: _pageController,
                onPageChanged: _onPageChanged,
                children: [
                  _buildConfigTab(
                    context,
                    provider,
                    colors,
                    bottomPadding: configBottomPadding,
                  ),
                  _buildModelsTab(
                    context,
                    provider,
                    colors,
                    modelEntries,
                    bottomPadding: modelsBottomPadding,
                  ),
                ],
              ),
            ),
          ],
        ),
        // 底部导航栏：透明背景悬浮
        bottomNavigationBar: SafeArea(
          top: false,
          child: Padding(
            padding: bottomBarPadding,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 「获取 / 自定义模型」属于二级模型界面：只在模型 Tab 显示
                if (_tabIndex == 1) ...[
                  FractionallySizedBox(
                    widthFactor: 0.90,
                    child: Row(
                      children: [
                        Expanded(
                          child: _ActionButton(
                            icon: Icons.cloud_download_outlined,
                            label: '获取',
                            colors: colors,
                            onTap: () => showModelPickerSheet(
                              context,
                              ref,
                              providerId: provider.id,
                            ),
                          ),
                        ),
                        const SizedBox(width: MoeSpacing.sm),
                        Expanded(
                          child: _ActionButton(
                            icon: Icons.add,
                            label: '自定义模型',
                            colors: colors,
                            isPrimary: true,
                            onTap: () => _showAddCustomModelDialog(provider),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: MoeSpacing.sm),
                ],

                // 底部切换框：使用公共组件 MoeBottomTabs（高度与 kelivo 一致）
                MoeBottomTabs(
                  index: _tabIndex,
                  leftIcon: Icons.settings_outlined,
                  leftLabel: '配置',
                  rightIcon: Icons.list_alt_outlined,
                  rightLabel: '模型',
                  onSelect: _onTabChanged,
                  height: bottomTabsHeight,
                  widthFactor: bottomTabsWidthFactor,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildConfigTab(
    BuildContext context,
    ProviderAuth provider,
    MoeColors colors, {
    required double bottomPadding,
  }) {
    final multiKeyEnabled = isProviderMultiKeyEnabled(provider);
    final settings = ref.read(appSettingsProvider).valueOrNull;
    final requestFormat = resolveProviderDetailRequestFormat(
      provider,
      settings: settings,
    );
    final requestFormatOptions = ProviderDetailRequestFormat.forProvider(
      provider,
      settings: settings,
    );
    final showChatApiPath =
        (settings
                ?.getProviderModelsByType(provider.id, type: ModelType.chat)
                .isNotEmpty ??
            false) ||
        provider.capabilities.contains(ModelType.chat.value);

    // 因为 resizeToAvoidBottomInset: false，不需要监听键盘高度
    // 为底部悬浮操作区预留可滚动空间，避免内容被遮挡
    return SingleChildScrollView(
      padding: EdgeInsets.only(bottom: bottomPadding),
      child: Column(
        children: [
          MoeSettingsGroup(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            title: '基础配置',
            children: [
              MoeSettingsRow(
                label: '显示名称',
                trailingType: MoeSettingsRowTrailing.custom,
                expandTrailing: true,
                trailing: TextField(
                  controller: _nameController,
                  focusNode: _nameFocusNode,
                  style: TextStyle(fontSize: 14, color: colors.text),
                  textAlign: TextAlign.end,
                  decoration: const MoeInputDecoration(
                    isDense: true,
                    contentPadding: EdgeInsets.zero,
                    hintText: '未设置',
                  ),
                  onChanged: (_) => _scheduleAutoSave(provider),
                ),
              ),
              MoeSettingsRow(
                label: '基础 URL',
                trailingType: MoeSettingsRowTrailing.custom,
                expandTrailing: true,
                trailing: TextField(
                  controller: _urlController,
                  focusNode: _urlFocusNode,
                  style: TextStyle(fontSize: 14, color: colors.text),
                  textAlign: TextAlign.end,
                  decoration: const MoeInputDecoration(
                    isDense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                  onChanged: (_) => _scheduleAutoSave(provider),
                ),
              ),
              if (showChatApiPath)
                MoeSettingsRow(
                  label: 'API 路径',
                  trailingType: MoeSettingsRowTrailing.custom,
                  expandTrailing: true,
                  trailing: TextField(
                    controller: _pathController,
                    focusNode: _pathFocusNode,
                    style: TextStyle(fontSize: 14, color: colors.text),
                    textAlign: TextAlign.end,
                    decoration: const MoeInputDecoration(
                      isDense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                    onChanged: (_) => _scheduleAutoSave(provider),
                  ),
                ),
              if (!multiKeyEnabled)
                MoeSettingsRow(
                  label: 'API Key',
                  trailingType: MoeSettingsRowTrailing.custom,
                  expandTrailing: true,
                  trailing: TextField(
                    controller: _keyController,
                    focusNode: _keyFocusNode,
                    style: TextStyle(fontSize: 14, color: colors.text),
                    textAlign: TextAlign.end,
                    obscureText: false,
                    decoration: const MoeInputDecoration(
                      isDense: true,
                      contentPadding: EdgeInsets.zero,
                      hintText: '未设置',
                    ),
                    onChanged: (_) => _scheduleAutoSave(provider),
                  ),
                ),
            ],
          ),
          MoeSettingsGroup(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            title: '高级信息',
            children: [
              MoeSettingsRow(
                label: 'API 格式',
                trailingType: MoeSettingsRowTrailing.text,
                detailText: requestFormat.label,
                onTap: requestFormatOptions.length > 1
                    ? () => _showRequestFormatSheet(provider)
                    : null,
              ),
              MoeSettingsRow(
                label: '多 Key 模式',
                trailingType: MoeSettingsRowTrailing.custom,
                trailing: MoeSwitch(
                  value: multiKeyEnabled,
                  onChanged: (value) => _toggleMultiKeyMode(provider, value),
                ),
              ),
              if (multiKeyEnabled)
                MoeSettingsRow(
                  label: '多 Key 管理',
                  trailingType: MoeSettingsRowTrailing.chevron,
                  onTap: () => _openMultiKeyManager(provider),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildModelsTab(
    BuildContext context,
    ProviderAuth provider,
    MoeColors colors,
    List<_ProviderModelEntry> modelEntries, {
    required double bottomPadding,
  }) {
    final visible = modelEntries;

    // 模型 Tab 时底部有额外按钮，动态预留更大的 padding
    return SingleChildScrollView(
      padding: EdgeInsets.only(left: 16, right: 16, bottom: bottomPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 分组标题
          Padding(
            padding: const EdgeInsets.only(left: 4, top: 8, bottom: 8),
            child: Text(
              '模型列表 (${visible.length})',
              style: TextStyle(
                fontSize: 13,
                fontWeight: MoeFontWeights.emphasis,
                color: colors.textSecondary.withValues(alpha: 0.8),
              ),
            ),
          ),

          if (visible.isEmpty)
            MoeSettingsGroup(
              margin: EdgeInsets.zero,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  child: Center(
                    child: Text(
                      '暂无模型',
                      style: TextStyle(color: colors.muted, fontSize: 14),
                    ),
                  ),
                ),
              ],
            )
          else
            MoeSettingsGroup(
              margin: EdgeInsets.zero,
              padding: EdgeInsets.zero,
              children: [
                ReorderableListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: visible.length,
                  onReorder: (oldIndex, newIndex) =>
                      _onReorderModels(provider, oldIndex, newIndex),
                  buildDefaultDragHandles: false,
                  proxyDecorator: (child, index, animation) {
                    return AnimatedBuilder(
                      animation: animation,
                      builder: (context, child) {
                        final t = Curves.easeInOut.transform(animation.value);
                        final scale = lerpDouble(1.0, 0.98, t) ?? 1.0;
                        return Transform.scale(
                          scale: scale,
                          child: Opacity(opacity: 0.95, child: child),
                        );
                      },
                      child: child,
                    );
                  },
                  itemBuilder: (context, index) {
                    return ReorderableDelayedDragStartListener(
                      key: ValueKey(visible[index].modelId),
                      index: index,
                      child: ModelRowTile(
                        providerId: provider.id,
                        model: visible[index].modelId,
                        displayName: visible[index].displayName,
                      ),
                    );
                  },
                ),
              ],
            ),
        ],
      ),
    );
  }

  List<_ProviderModelEntry> _resolveModelEntries(
    ProviderAuth provider,
    Map<String, String> displayNames,
  ) {
    final signature = _buildProviderDetailWarmSignature(provider, displayNames);
    if (_cachedModelEntriesSignature == signature &&
        _cachedModelEntries != null) {
      return _cachedModelEntries!;
    }

    final cached = _ProviderDetailWarmCache.read(
      providerId: provider.id,
      signature: signature,
    );
    if (cached != null) {
      _cachedModelEntriesSignature = signature;
      _cachedModelEntries = cached.modelEntries;
      return cached.modelEntries;
    }

    final entries =
        provider.visibleModels
            .map(
              (modelId) => _ProviderModelEntry(
                modelId: modelId,
                displayName: displayNames[modelId] ?? '',
              ),
            )
            .toList(growable: false)
          ..sort((a, b) {
            final nameA = a.sortName;
            final nameB = b.sortName;
            return nameA.compareTo(nameB);
          });

    _cachedModelEntriesSignature = signature;
    _cachedModelEntries = List<_ProviderModelEntry>.unmodifiable(entries);
    _ProviderDetailWarmCache.write(
      providerId: provider.id,
      signature: signature,
      modelEntries: _cachedModelEntries!,
    );
    return _cachedModelEntries!;
  }
}

String _buildProviderDetailWarmSignature(
  ProviderAuth provider,
  Map<String, String> displayNames,
) {
  final buffer = StringBuffer()
    ..write(provider.id)
    ..write('|')
    ..write(provider.displayName ?? '')
    ..write('|')
    ..write(provider.enabled ? '1' : '0')
    ..write('|')
    ..write(provider.visibleModels.length);
  for (final modelId in provider.visibleModels) {
    buffer
      ..write('|')
      ..write(modelId)
      ..write('=')
      ..write(displayNames[modelId] ?? '');
  }
  return buffer.toString();
}

class _ProviderModelEntry {
  const _ProviderModelEntry({required this.modelId, required this.displayName});

  final String modelId;
  final String displayName;

  String get sortName =>
      (displayName.isEmpty ? modelId : displayName).toLowerCase();
}

class _ProviderDetailWarmCacheEntry {
  const _ProviderDetailWarmCacheEntry({
    required this.signature,
    required this.modelEntries,
  });

  final String signature;
  final List<_ProviderModelEntry> modelEntries;
}

class _ProviderDetailWarmCache {
  static const int _maxEntries = 8;
  static final LinkedHashMap<String, _ProviderDetailWarmCacheEntry> _entries =
      LinkedHashMap<String, _ProviderDetailWarmCacheEntry>();

  static _ProviderDetailWarmCacheEntry? read({
    required String providerId,
    required String signature,
  }) {
    final cached = _entries[providerId];
    if (cached == null || cached.signature != signature) {
      return null;
    }
    _entries.remove(providerId);
    _entries[providerId] = cached;
    return cached;
  }

  static void write({
    required String providerId,
    required String signature,
    required List<_ProviderModelEntry> modelEntries,
  }) {
    _entries.remove(providerId);
    _entries[providerId] = _ProviderDetailWarmCacheEntry(
      signature: signature,
      modelEntries: List<_ProviderModelEntry>.unmodifiable(modelEntries),
    );
    while (_entries.length > _maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }

  static void clear() {
    _entries.clear();
  }
}

@visibleForTesting
void debugClearProviderDetailWarmCache() {
  _ProviderDetailWarmCache.clear();
}

/// 操作按钮组件
class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.colors,
    required this.onTap,
    this.isPrimary = false,
  });

  final IconData icon;
  final String label;
  final MoeColors colors;
  final VoidCallback onTap;
  final bool isPrimary;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: MoeButtonSurface(
        height: MoeButtonSizes.md,
        radius: MoeSmoothRadii.md,
        tintColor: isPrimary ? colors.primary : Colors.transparent,
        border: Border.all(
          color: isPrimary ? colors.primary : colors.border,
          width: 1,
        ),
        shadows: MoeShadows.soft,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 18,
              color: isPrimary ? colors.text : colors.textSecondary,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                color: isPrimary ? colors.text : colors.textSecondary,
                fontWeight: isPrimary
                    ? MoeFontWeights.emphasis
                    : MoeFontWeights.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
