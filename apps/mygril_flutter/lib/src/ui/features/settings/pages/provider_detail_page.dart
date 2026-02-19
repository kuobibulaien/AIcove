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

import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/settings/app_settings.dart';
import '../../../theme/tokens.dart';
import '../../../shared/effects/smooth_clip.dart';
import '../../../shared/widgets/index.dart';
import '../widgets/model_row_tile.dart';
import '../widgets/model_picker_sheet.dart';
import '../../../shared/widgets/provider/capability_selector.dart';
import '../../../shared/widgets/provider/capability_chips.dart';

/// 供应商详情页
class ProviderDetailPage extends ConsumerStatefulWidget {
  const ProviderDetailPage({
    super.key,
    required this.providerId,
  });

  /// 供应商 ID
  final String providerId;

  @override
  ConsumerState<ProviderDetailPage> createState() => _ProviderDetailPageState();
}

class _ProviderDetailPageState extends ConsumerState<ProviderDetailPage> {
  int _tabIndex = 0;
  final PageController _pageController = PageController();

  // 配置表单
  late TextEditingController _nameController;
  late TextEditingController _urlController;
  late TextEditingController _keyController;
  late FocusNode _nameFocusNode;
  late FocusNode _urlFocusNode;
  late FocusNode _keyFocusNode;

  Timer? _autoSaveTimer;
  String _lastSavedName = '';
  String _lastSavedUrl = '';
  String _lastSavedKey = '';
  String? _lastSyncedProviderId;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
    _urlController = TextEditingController();
    _keyController = TextEditingController();
    _nameFocusNode = FocusNode();
    _urlFocusNode = FocusNode();
    _keyFocusNode = FocusNode();
  }

  @override
  void dispose() {
    _autoSaveTimer?.cancel();
    _pageController.dispose();
    _nameController.dispose();
    _urlController.dispose();
    _keyController.dispose();
    _nameFocusNode.dispose();
    _urlFocusNode.dispose();
    _keyFocusNode.dispose();
    super.dispose();
  }

  void _syncControllersFromProvider(ProviderAuth provider) {
    final desiredName = provider.displayName ?? '';
    final desiredUrl = provider.apiBaseUrl;
    final desiredKey = provider.apiKeys.isNotEmpty ? provider.apiKeys.first : '';

    _syncControllerIfNotFocused(_nameController, _nameFocusNode, desiredName);
    _syncControllerIfNotFocused(_urlController, _urlFocusNode, desiredUrl);
    _syncControllerIfNotFocused(_keyController, _keyFocusNode, desiredKey);

    _lastSavedName = desiredName.trim();
    _lastSavedUrl = desiredUrl.trim();
    _lastSavedKey = desiredKey.trim();
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

  void _scheduleAutoSave(ProviderAuth provider) {
    _autoSaveTimer?.cancel();

    final name = _nameController.text.trim();
    final url = _urlController.text.trim();
    final key = _keyController.text.trim();
    final hasChanges = name != _lastSavedName || url != _lastSavedUrl || key != _lastSavedKey;

    if (!hasChanges) return;

    _autoSaveTimer = Timer(const Duration(milliseconds: 650), () async {
      await _autoSave(provider);
    });
  }

  Future<void> _autoSave(ProviderAuth provider) async {
    final name = _nameController.text.trim();
    final url = _urlController.text.trim();
    final key = _keyController.text.trim();
    final hasChanges = name != _lastSavedName || url != _lastSavedUrl || key != _lastSavedKey;

    if (!hasChanges) return;

    try {
      final notifier = ref.read(appSettingsProvider.notifier);
      await notifier.editProvider(
        providerId: provider.id,
        displayName: name,
        apiBaseUrl: url,
        apiKeys: [key],
      );
      _lastSavedName = name;
      _lastSavedUrl = url;
      _lastSavedKey = key;
    } catch (e) {
      if (!mounted) return;
      MoeToast.show(context, '自动保存失败: $e', type: ToastType.error);
    }
  }

  String _getDisplayName(Map<String, String> displayNames, String model) {
    return displayNames[model] ?? '';
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
    final notifier = ref.read(appSettingsProvider.notifier);
    MoeToast.show(context, '正在测试连接...');
    try {
      final result = await notifier.previewProviderModels(
        providerId: provider.id,
        apiKey: provider.apiKeys.isNotEmpty ? provider.apiKeys.first : '',
        apiBaseUrl: provider.apiBaseUrl,
      );
      if (mounted) {
        MoeToast.show(context, '连接成功，发现 ${result.length} 个模型');
      }
    } catch (e) {
      if (mounted) {
        MoeToast.show(context, '连接失败: $e', type: ToastType.error);
      }
    }
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
      final notifier = ref.read(appSettingsProvider.notifier);
      await notifier.deleteProvider(provider.id);
      if (mounted) {
        Navigator.of(context).pop();
        MoeToast.show(context, '已删除');
      }
    }
  }

  Future<void> _toggleEnabled(ProviderAuth provider) async {
    final notifier = ref.read(appSettingsProvider.notifier);
    await notifier.setProviderEnabled(provider.id, !provider.enabled);
    HapticFeedback.lightImpact();
  }

  /// 弹出标签选择器，用于编辑渠道的 capabilities（多选）
  Future<void> _showCapabilitySheet(ProviderAuth provider) async {
    // 使用临时状态来管理多选
    var selected = Set<String>.from(provider.capabilities);
    if (selected.isEmpty) selected.add('chat');

    await showMoeBottomSheet(
      context: context,
      title: '编辑用途标签',
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              CapabilitySelector(
                selected: selected,
                compact: true,
                onChanged: (newSet) {
                  setSheetState(() => selected = newSet);
                },
              ),
              const SizedBox(height: 24),
              MoePrimaryButton(
                label: '保存',
                onPressed: () async {
                  Navigator.of(context).pop();
                  // 保存到数据库
                  final notifier = ref.read(appSettingsProvider.notifier);
                  await notifier.editProvider(
                    providerId: provider.id,
                    capabilities: selected.toList(),
                  );
                  if (mounted) {
                    MoeToast.show(this.context, '已更新用途标签');
                  }
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _refreshModels(ProviderAuth provider) async {
    final notifier = ref.read(appSettingsProvider.notifier);
    MoeToast.show(context, '正在刷新模型列表...');
    try {
      final result = await notifier.previewProviderModels(
        providerId: provider.id,
        apiKey: provider.apiKeys.isNotEmpty ? provider.apiKeys.first : '',
        apiBaseUrl: provider.apiBaseUrl,
      );
      if (mounted && result.isNotEmpty) {
        if (!mounted) return;
        await notifier.updateProviderModels(
          providerId: provider.id,
          allModels: result,
        );
        if (!mounted) return;
        MoeToast.show(context, '已刷新，共 ${result.length} 个模型');
      }
    } catch (e) {
      if (mounted) {
        MoeToast.show(context, '刷新失败: $e', type: ToastType.error);
      }
    }
  }

  Future<void> _onReorderModels(ProviderAuth provider, int oldIndex, int newIndex) async {
    if (oldIndex == newIndex) return;
    
    final visible = _sortedModels(provider.visibleModels, ref.read(appSettingsProvider).value?.modelDisplayNames ?? {});
    
    // ReorderableListView 的 newIndex 需要调整
    if (newIndex > oldIndex) {
      newIndex -= 1;
    }
    
    final reordered = List<String>.from(visible);
    final item = reordered.removeAt(oldIndex);
    reordered.insert(newIndex, item);
    
    // 更新模型顺序
    final notifier = ref.read(appSettingsProvider.notifier);
    await notifier.reorderProviderModels(
      providerId: provider.id,
      modelIds: reordered,
    );
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
      
      final notifier = ref.read(appSettingsProvider.notifier);
      final displayName = displayNameController.text.trim();
      
      // 添加自定义模型到供应商
      await notifier.addCustomModel(
        providerId: provider.id,
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
      loading: () => Scaffold(
        backgroundColor: colors.surface,
        appBar: const MoeAppBar(title: '渠道详情', showBackButton: true),
        body: const Center(child: MoeLoadingIndicator()),
      ),
      error: (e, _) => Scaffold(
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
          return const Scaffold(
            appBar: MoeAppBar(title: '供应商详情'),
            body: MoeEmptyState(title: '供应商不存在'),
          );
        }

        // 只在首次加载或 provider 变更时同步控制器，避免每次 rebuild 都执行
        if (_lastSyncedProviderId != provider.id) {
          _syncControllersFromProvider(provider);
          _lastSyncedProviderId = provider.id;
        }
        final displayNames = settings.modelDisplayNames;

        return _buildContent(context, provider, colors, displayNames);
      },
    );
  }

  Widget _buildContent(
    BuildContext context,
    ProviderAuth provider,
    MoeColors colors,
    Map<String, String> displayNames,
  ) {
    const bottomBarPadding = EdgeInsets.fromLTRB(16, 10, 16, 12);
    const bottomTabsHeight = 80.0;
    const bottomTabsWidthFactor = 0.90;

    final safeBottom = MediaQuery.paddingOf(context).bottom;
    final bottomBarBaseHeight = safeBottom + bottomBarPadding.vertical + bottomTabsHeight;
    final configBottomPadding = bottomBarBaseHeight + MoeSpacing.xl;
    final modelsBottomPadding = bottomBarBaseHeight + MoeButtonSizes.md + MoeSpacing.sm + MoeSpacing.xl;

    return Scaffold(
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
            tooltip: '测试连接',
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
                _buildConfigTab(context, provider, colors, bottomPadding: configBottomPadding),
                _buildModelsTab(context, provider, colors, displayNames, bottomPadding: modelsBottomPadding),
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
                          onTap: () => showModelPickerSheet(context, ref, providerId: provider.id),
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
    );
  }

  Widget _buildConfigTab(
    BuildContext context,
    ProviderAuth provider,
    MoeColors colors, {
    required double bottomPadding,
  }) {
    // 因为 resizeToAvoidBottomInset: false，不需要监听键盘高度
    // 为底部悬浮操作区预留可滚动空间，避免内容被遮挡
    return SingleChildScrollView(
      padding: EdgeInsets.only(bottom: bottomPadding),
      child: Column(
        children: [
          MoeSettingsGroup(
            title: '基础配置',
            children: [
              MoeSettingsRow(
                icon: Icons.badge_outlined,
                label: '显示名称',
                trailingType: MoeSettingsRowTrailing.custom,
                trailing: SizedBox(
                  width: 180,
                  child: TextField(
                    controller: _nameController,
                    focusNode: _nameFocusNode,
                    style: TextStyle(fontSize: 14, color: colors.text),
                    textAlign: TextAlign.end,
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: EdgeInsets.zero,
                      hintText: '未设置',
                    ),
                    onChanged: (_) => _scheduleAutoSave(provider),
                  ),
                ),
              ),
              MoeSettingsRow(
                icon: Icons.link_outlined,
                label: 'API 地址',
                trailingType: MoeSettingsRowTrailing.custom,
                trailing: SizedBox(
                  width: 200,
                  child: TextField(
                    controller: _urlController,
                    focusNode: _urlFocusNode,
                    style: TextStyle(fontSize: 14, color: colors.text),
                    textAlign: TextAlign.end,
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                    onChanged: (_) => _scheduleAutoSave(provider),
                  ),
                ),
              ),
              MoeSettingsRow(
                icon: Icons.key_outlined,
                label: 'API Key',
                trailingType: MoeSettingsRowTrailing.custom,
                trailing: SizedBox(
                  width: 180,
                  child: TextField(
                    controller: _keyController,
                    focusNode: _keyFocusNode,
                    style: TextStyle(fontSize: 14, color: colors.text),
                    textAlign: TextAlign.end,
                    obscureText: true,
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: EdgeInsets.zero,
                      hintText: '未设置',
                    ),
                    onChanged: (_) => _scheduleAutoSave(provider),
                  ),
                ),
              ),
            ],
          ),
          
          MoeSettingsGroup(
            title: '高级信息',
            children: [
              MoeSettingsRow(
                icon: Icons.category_outlined,
                label: '用途标签',
                trailingType: MoeSettingsRowTrailing.custom,
                trailing: CapabilityChips(
                  capabilities: provider.capabilities,
                  size: CapabilityChipSize.sm,
                ),
                onTap: () => _showCapabilitySheet(provider),
              ),
              MoeSettingsRow(
                icon: Icons.fingerprint,
                label: 'ID',
                trailingType: MoeSettingsRowTrailing.text,
                detailText: provider.id,
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
    Map<String, String> displayNames, {
    required double bottomPadding,
  }) {
    final visible = _sortedModels(provider.visibleModels, displayNames);

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
                    child: Text('暂无模型', style: TextStyle(color: colors.muted, fontSize: 14)),
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
                  onReorder: (oldIndex, newIndex) => _onReorderModels(provider, oldIndex, newIndex),
                  buildDefaultDragHandles: false,
                  proxyDecorator: (child, index, animation) {
                    return AnimatedBuilder(
                      animation: animation,
                      builder: (context, child) {
                        final t = Curves.easeInOut.transform(animation.value);
                        final scale = lerpDouble(1.0, 0.98, t) ?? 1.0;
                        return Transform.scale(
                          scale: scale,
                          child: Opacity(
                            opacity: 0.95,
                            child: child,
                          ),
                        );
                      },
                      child: child,
                    );
                  },
                  itemBuilder: (context, index) {
                    return ReorderableDelayedDragStartListener(
                      key: ValueKey(visible[index]),
                      index: index,
                      child: ModelRowTile(
                        providerId: provider.id,
                        model: visible[index],
                        displayName: _getDisplayName(displayNames, visible[index]),
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

  String _extractDomain(String url) {
    try {
      final uri = Uri.parse(url);
      return uri.host;
    } catch (_) {
      return url;
    }
  }

  String _maskKey(String key) {
    if (key.isEmpty) return '未设置';
    if (key.length <= 8) return '••••••••';
    return '${key.substring(0, 4)}••••${key.substring(key.length - 4)}';
  }

  List<String> _sortedModels(List<String> models, Map<String, String> displayNames) {
    final list = List<String>.from(models);
    list.sort((a, b) {
      final nameA = displayNames[a] ?? a;
      final nameB = displayNames[b] ?? b;
      return nameA.toLowerCase().compareTo(nameB.toLowerCase());
    });
    return list;
  }
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
      child: Container(
        height: MoeButtonSizes.md,
        decoration: MoeG2Decoration(
          radius: MoeSmoothRadii.md,
          color: isPrimary ? colors.primary : colors.componentBackground,
          border: Border.all(
            color: isPrimary ? colors.primary : colors.border,
            width: 1,
          ),
          boxShadow: MoeShadows.soft,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 18,
              color: isPrimary ? colors.headerContentColor : colors.textSecondary,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                color: isPrimary ? colors.headerContentColor : colors.textSecondary,
                fontWeight: isPrimary ? MoeFontWeights.emphasis : MoeFontWeights.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
