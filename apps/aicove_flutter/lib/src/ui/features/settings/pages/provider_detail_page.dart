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

import 'dart:async';
import 'dart:collection';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/api/providers/google_api_mode.dart';
import '../../../../features/settings/app_settings.dart';
import '../../../../features/settings/provider_detail/provider_detail_actions.dart';
import '../../../../features/settings/provider_detail/provider_detail_support.dart';
import '../../../theme/tokens.dart';
import '../../../shared/effects/smooth_clip.dart';
import '../../../shared/widgets/index.dart';
import '../widgets/model_row_tile.dart';
import '../widgets/model_picker_sheet.dart';
import 'multi_key_manager_page.dart';

const Duration _kProviderDetailDeferredContentWindow =
    Duration(milliseconds: 420);

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
  Timer? _deferredContentTimer;
  String _lastSavedName = '';
  String _lastSavedUrl = '';
  String _lastSavedKey = '';
  bool _deferHeavyContent = true;
  String? _cachedModelEntriesSignature;
  List<_ProviderModelEntry>? _cachedModelEntries;

  ProviderDetailActions get _actions => ref.read(providerDetailActionsProvider);

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
    _urlController = TextEditingController();
    _keyController = TextEditingController();
    _nameFocusNode = FocusNode();
    _urlFocusNode = FocusNode();
    _keyFocusNode = FocusNode();
    _restoreWarmCacheFromLoadedSettings();
    _scheduleDeferredContentActivation();
  }

  @override
  void dispose() {
    _autoSaveTimer?.cancel();
    _deferredContentTimer?.cancel();
    _pageController.dispose();
    _nameController.dispose();
    _urlController.dispose();
    _keyController.dispose();
    _nameFocusNode.dispose();
    _urlFocusNode.dispose();
    _keyFocusNode.dispose();
    super.dispose();
  }

  void _scheduleDeferredContentActivation() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _deferredContentTimer?.cancel();
      _deferredContentTimer = Timer(
        _kProviderDetailDeferredContentWindow,
        _activateHeavyContent,
      );
    });
  }

  void _activateHeavyContent() {
    if (!mounted || !_deferHeavyContent) return;
    setState(() => _deferHeavyContent = false);
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
    final signature = _buildProviderDetailWarmSignature(
      provider,
      displayNames,
    );
    final cached = _ProviderDetailWarmCache.read(
      providerId: provider.id,
      signature: signature,
    );
    if (cached == null) return false;

    _cachedModelEntriesSignature = signature;
    _cachedModelEntries = cached.modelEntries;
    _deferHeavyContent = false;
    return true;
  }

  String _resolvePrimaryApiKey(ProviderAuth provider) {
    return _actions.resolvePrimaryApiKey(provider);
  }

  void _syncControllersFromProvider(ProviderAuth provider) {
    final desiredName = provider.displayName ?? '';
    final desiredUrl = provider.apiBaseUrl;
    final desiredKey = _resolvePrimaryApiKey(provider);

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

  Widget _buildLockedUrlPreview(
    MoeColors colors, {
    required TextEditingController controller,
    required double width,
  }) {
    return SizedBox(
      width: width,
      child: ValueListenableBuilder<TextEditingValue>(
        valueListenable: controller,
        builder: (context, value, _) {
          return Align(
            alignment: Alignment.centerRight,
            child: Text(
              value.text.trim().isEmpty ? '-' : value.text.trim(),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
              style: TextStyle(fontSize: 14, color: colors.text),
            ),
          );
        },
      ),
    );
  }

  void _scheduleAutoSave(ProviderAuth provider) {
    _autoSaveTimer?.cancel();

    final multiKeyEnabled = isProviderMultiKeyEnabled(provider);
    final name = _nameController.text.trim();
    final url = _urlController.text.trim();
    final key = _keyController.text.trim();
    final hasChanges = name != _lastSavedName ||
        url != _lastSavedUrl ||
        (!multiKeyEnabled && key != _lastSavedKey);

    if (!hasChanges) return;

    _autoSaveTimer = Timer(const Duration(milliseconds: 650), () async {
      await _autoSave(provider);
    });
  }

  Future<void> _autoSave(ProviderAuth provider) async {
    final multiKeyEnabled = isProviderMultiKeyEnabled(provider);
    final name = _nameController.text.trim();
    final url = _urlController.text.trim();
    final key = _keyController.text.trim();
    final hasChanges = name != _lastSavedName ||
        url != _lastSavedUrl ||
        (!multiKeyEnabled && key != _lastSavedKey);

    if (!hasChanges) return;

    try {
      await _actions.autoSaveProvider(
        provider: provider,
        displayName: name,
        apiBaseUrl: url,
        apiKey: key,
      );
      _lastSavedName = name;
      _lastSavedUrl = url;
      _lastSavedKey = key;
    } catch (e) {
      if (!mounted) return;
      MoeToast.show(context, '自动保存失败: $e', type: ToastType.error);
    }
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
    final models = provider.visibleModels;
    if (models.isEmpty) {
      MoeToast.show(context, '当前渠道没有可用模型', type: ToastType.error);
      return;
    }

    final displayNames =
        ref.read(appSettingsProvider).value?.modelDisplayNames ?? {};
    final apiKey = _actions.resolvePrimaryApiKey(provider);
    if (apiKey.isEmpty) {
      MoeToast.show(context, '请先配置可用 API Key', type: ToastType.error);
      return;
    }

    // 每个模型的测试状态：null=空闲, true=成功, false=失败
    // 用 Map<String, _TestState> 管理
    final testStates = <String, _ModelTestState>{};
    // 待测试队列
    final queue = <String>[];
    var isTesting = false;

    await showMoeBottomSheet(
      context: context,
      title: '测试模型',
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            // 按顺序执行队列中的测试
            Future<void> processQueue() async {
              if (isTesting) return;
              isTesting = true;
              while (queue.isNotEmpty) {
                final modelId = queue.removeAt(0);
                setSheetState(() {
                  testStates[modelId] = _ModelTestState.loading;
                });
                try {
                  await _actions.testModel(
                    provider: provider,
                    apiKey: apiKey,
                    modelId: modelId,
                  );
                  setSheetState(() {
                    testStates[modelId] = _ModelTestState.success;
                  });
                } catch (_) {
                  setSheetState(() {
                    testStates[modelId] = _ModelTestState.failure;
                  });
                }
              }
              isTesting = false;
            }

            final colors = sheetContext.moeColors;

            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 全选按钮
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      GestureDetector(
                        onTap: () {
                          // 把所有未测试/未排队的模型加入队列
                          for (final m in models) {
                            final st = testStates[m];
                            if (st == null && !queue.contains(m)) {
                              queue.add(m);
                              setSheetState(() {
                                testStates[m] = _ModelTestState.queued;
                              });
                            }
                          }
                          processQueue();
                        },
                        child: Text(
                          '全部测试',
                          style: TextStyle(
                              fontSize: 13,
                              color: colors.primary,
                              fontWeight: FontWeight.w500),
                        ),
                      ),
                    ],
                  ),
                ),
                // 模型列表
                ListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                  itemCount: models.length,
                  itemBuilder: (context, index) {
                    final modelId = models[index];
                    final displayName = displayNames[modelId];
                    final state = testStates[modelId];

                    return ListTile(
                      dense: true,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      title: Text(
                        displayName?.isNotEmpty == true
                            ? displayName!
                            : modelId,
                        style: TextStyle(fontSize: 14, color: colors.text),
                      ),
                      subtitle: displayName?.isNotEmpty == true
                          ? Text(modelId,
                              style:
                                  TextStyle(fontSize: 11, color: colors.muted))
                          : null,
                      trailing: _buildTestStateIcon(state, colors),
                      onTap: () {
                        // 空闲或已有结果时，点击（重新）加入队列
                        if (state == null ||
                            state == _ModelTestState.success ||
                            state == _ModelTestState.failure) {
                          queue.add(modelId);
                          setSheetState(() {
                            testStates[modelId] = _ModelTestState.queued;
                          });
                          processQueue();
                        }
                      },
                    );
                  },
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildTestStateIcon(_ModelTestState? state, MoeColors colors) {
    switch (state) {
      case null:
        return const SizedBox(width: 24, height: 24);
      case _ModelTestState.queued:
        return Icon(Icons.schedule, size: 20, color: colors.muted);
      case _ModelTestState.loading:
        return SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: colors.primary,
          ),
        );
      case _ModelTestState.success:
        return const Icon(Icons.check_circle,
            size: 20, color: Color(0xFF4CAF50));
      case _ModelTestState.failure:
        return const Icon(Icons.cancel, size: 20, color: Color(0xFFE53935));
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
      MaterialPageRoute(
        builder: (context) => MultiKeyManagerPage(providerId: provider.id),
      ),
    );
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _showRequestFormatSheet(ProviderAuth provider) async {
    final settings = ref.read(appSettingsProvider).valueOrNull;
    var selected =
        resolveProviderDetailRequestFormat(provider, settings: settings);
    final availableFormats =
        ProviderDetailRequestFormat.forProvider(provider, settings: settings);

    await showMoeBottomSheet(
      context: context,
      title: 'API 格式',
      builder: (context) => StatefulBuilder(
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
              MoePrimaryButton(
                label: '保存',
                onPressed: () async {
                  final current = resolveProviderDetailRequestFormat(provider,
                      settings: settings);
                  if (current == selected) {
                    Navigator.of(this.context).pop();
                    return;
                  }
                  await _actions.updateRequestFormat(provider, selected);
                  if (!mounted) return;
                  Navigator.of(this.context).pop();
                  MoeToast.show(this.context, '已更新 API 格式');
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _toggleVertexExpress(ProviderAuth provider, bool enabled) async {
    final nextBaseUrl = googleSuggestedBaseUrl(vertexExpress: enabled);
    _syncControllerIfNotFocused(_urlController, _urlFocusNode, nextBaseUrl);

    await _actions.setVertexExpressMode(provider, enabled: enabled);
    if (!mounted) return;
    MoeToast.show(context, enabled ? '已切到 Vertex Express' : '已切回 Gemini');
  }

  Future<void> _onReorderModels(
      ProviderAuth provider, int oldIndex, int newIndex) async {
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

        if (_deferHeavyContent) {
          _adoptWarmCacheIfAvailable(provider, settings.modelDisplayNames);
        }

        if (_deferHeavyContent) {
          return _buildDeferredContent(colors, provider);
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

  Widget _buildDeferredContent(MoeColors colors, ProviderAuth provider) {
    final providerName = provider.displayName ?? provider.id;

    return Scaffold(
      backgroundColor: colors.surface,
      appBar: const MoeAppBar(
        title: '渠道详情',
        showBackButton: true,
      ),
      body: ListView(
        key: const ValueKey<String>('provider_detail_deferred_shell'),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          MoeSettingsGroup(
            margin: EdgeInsets.zero,
            padding: const EdgeInsets.all(12),
            children: [
              Row(
                children: [
                  ProviderAvatar(
                    providerName: providerName,
                    size: ProviderAvatarSize.lg,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          providerName,
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: MoeFontWeights.emphasis,
                            color: colors.text,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Container(
                          width: 144,
                          height: 12,
                          decoration: BoxDecoration(
                            color: colors.surfaceAlt.withValues(alpha: 0.62),
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    width: 42,
                    height: 24,
                    decoration: BoxDecoration(
                      color: colors.surfaceAlt.withValues(alpha: 0.62),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          _buildDeferredGroupShell(colors, rowHeights: const [60, 60, 60]),
          const SizedBox(height: 12),
          _buildDeferredGroupShell(colors, rowHeights: const [60, 60, 60]),
          const SizedBox(height: 18),
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
                '正在准备渠道详情',
                style: TextStyle(
                  color: colors.textSecondary,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          child: FractionallySizedBox(
            widthFactor: 0.90,
            child: Container(
              height: 80,
              decoration: MoeG2Decoration(
                radius: MoeSmoothRadii.xl,
                color: colors.componentBackground.withValues(alpha: 0.96),
                border: Border.all(
                  color: colors.border.withValues(alpha: 0.35),
                  width: borderWidth,
                ),
                boxShadow: MoeShadows.soft,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDeferredGroupShell(
    MoeColors colors, {
    required List<double> rowHeights,
  }) {
    return MoeSettingsGroup(
      margin: EdgeInsets.zero,
      padding: EdgeInsets.zero,
      children: [
        for (var index = 0; index < rowHeights.length; index++)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              border: index == rowHeights.length - 1
                  ? null
                  : Border(
                      bottom: BorderSide(
                        color: colors.borderLight,
                        width: borderWidth,
                      ),
                    ),
            ),
            child: Container(
              height: rowHeights[index] - 28,
              decoration: BoxDecoration(
                color: colors.surfaceAlt.withValues(alpha: 0.62),
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
      ],
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
                _buildConfigTab(context, provider, colors,
                    bottomPadding: configBottomPadding),
                _buildModelsTab(context, provider, colors, modelEntries,
                    bottomPadding: modelsBottomPadding),
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
                          onTap: () => showModelPickerSheet(context, ref,
                              providerId: provider.id),
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
    final multiKeyEnabled = isProviderMultiKeyEnabled(provider);
    final vertexExpress = isProviderDetailVertexExpressMode(provider);
    final showVertexAddress = vertexExpress &&
        resolveProviderDetailRequestFormat(
              provider,
              settings: ref.read(appSettingsProvider).valueOrNull,
            ) ==
            ProviderDetailRequestFormat.gemini;

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
                trailing: showVertexAddress
                    ? Opacity(
                        opacity: 0.45,
                        child: _buildLockedUrlPreview(
                          colors,
                          controller: _urlController,
                          width: 200,
                        ),
                      )
                    : SizedBox(
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
              if (showVertexAddress)
                MoeSettingsRow(
                  icon: Icons.hub_outlined,
                  label: 'Vertex 地址',
                  trailingType: MoeSettingsRowTrailing.custom,
                  trailing: SizedBox(
                    width: 220,
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
              if (!multiKeyEnabled)
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
                      obscureText: false,
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
                icon: Icons.swap_horiz_outlined,
                label: 'API 格式',
                trailingType: MoeSettingsRowTrailing.text,
                detailText: resolveProviderDetailRequestFormat(
                  provider,
                  settings: ref.read(appSettingsProvider).valueOrNull,
                ).label,
                onTap: () => _showRequestFormatSheet(provider),
              ),
              if (resolveProviderDetailRequestFormat(
                    provider,
                    settings: ref.read(appSettingsProvider).valueOrNull,
                  ) ==
                  ProviderDetailRequestFormat.gemini)
                MoeSettingsRow(
                  icon: Icons.cloud_sync_outlined,
                  label: 'Vertex Express',
                  subtitle: '开启后默认切到 aiplatform 端点',
                  trailingType: MoeSettingsRowTrailing.custom,
                  trailing: MoeSwitch(
                    value: isProviderDetailVertexExpressMode(provider),
                    onChanged: (value) => _toggleVertexExpress(provider, value),
                  ),
                ),
              MoeSettingsRow(
                icon: Icons.alt_route_outlined,
                label: '多 Key 模式',
                trailingType: MoeSettingsRowTrailing.custom,
                trailing: MoeSwitch(
                  value: multiKeyEnabled,
                  onChanged: (value) => _toggleMultiKeyMode(provider, value),
                ),
              ),
              if (multiKeyEnabled)
                MoeSettingsRow(
                  icon: Icons.manage_accounts_outlined,
                  label: '多 Key 管理',
                  trailingType: MoeSettingsRowTrailing.chevron,
                  onTap: () => _openMultiKeyManager(provider),
                ),
              MoeSettingsRow(
                icon: Icons.category_outlined,
                label: '能力标签',
                trailingType: MoeSettingsRowTrailing.custom,
                trailing: CapabilityChips(
                  capabilities: provider.capabilities,
                  size: CapabilityChipSize.sm,
                ),
                subtitle: '按已加载模型自动生成',
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
                    child: Text('暂无模型',
                        style: TextStyle(color: colors.muted, fontSize: 14)),
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

    final entries = provider.visibleModels
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
  const _ProviderModelEntry({
    required this.modelId,
    required this.displayName,
  });

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
              color:
                  isPrimary ? colors.headerContentColor : colors.textSecondary,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                color: isPrimary
                    ? colors.headerContentColor
                    : colors.textSecondary,
                fontWeight:
                    isPrimary ? MoeFontWeights.emphasis : MoeFontWeights.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 模型测试状态
enum _ModelTestState { queued, loading, success, failure }
