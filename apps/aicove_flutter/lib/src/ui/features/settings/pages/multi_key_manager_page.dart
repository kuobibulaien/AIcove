import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/settings/app_settings.dart';
import '../../../../features/settings/provider_detail/provider_detail_actions.dart';
import '../../../../features/settings/provider_detail/provider_detail_support.dart';
import '../../../theme/tokens.dart';
import '../../../shared/widgets/index.dart';

class MultiKeyManagerPage extends ConsumerStatefulWidget {
  const MultiKeyManagerPage({super.key, required this.providerId});

  final String providerId;

  @override
  ConsumerState<MultiKeyManagerPage> createState() =>
      _MultiKeyManagerPageState();
}

class _MultiKeyManagerPageState extends ConsumerState<MultiKeyManagerPage> {
  bool _detecting = false;
  String? _testingKeyId;
  String? _detectModelId;

  ProviderDetailActions get _actions => ref.read(providerDetailActionsProvider);

  String? _resolveDetectModel(ProviderAuth provider) {
    final models = provider.visibleModels.isNotEmpty
        ? provider.visibleModels
        : provider.models;
    if (models.isEmpty) return null;
    final current = _detectModelId;
    if (current != null && models.contains(current)) return current;
    _detectModelId = models.first;
    return _detectModelId;
  }

  Future<bool> _testKey(
    ProviderAuth provider, {
    required String modelId,
    required String apiKey,
  }) async {
    try {
      await _actions.testModel(
        provider: provider,
        apiKey: apiKey,
        modelId: modelId,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _saveItems(
    ProviderAuth provider,
    List<ProviderMultiKeyItem> items, {
    bool? enabled,
    String? strategy,
    int? roundRobinIndex,
  }) {
    return _actions.saveProviderMultiKeyItems(
      provider: provider,
      items: items,
      enabled: enabled,
      strategy: strategy,
      roundRobinIndex: roundRobinIndex,
    );
  }

  Future<void> _pickStrategy(
    ProviderAuth provider,
    List<ProviderMultiKeyItem> items,
  ) async {
    final current = providerMultiKeyStrategy(provider).trim().toLowerCase();
    final selected = await showMoeBottomSheet<String>(
      context: context,
      title: '负载均衡策略',
      builder: (sheetContext) {
        final colors = sheetContext.moeColors;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: MoeSettingsGroup(
            margin: EdgeInsets.zero,
            children: [
              MoeSettingsRow(
                icon: Icons.sync_alt_outlined,
                label: '轮询',
                trailingType: MoeSettingsRowTrailing.custom,
                trailing: current == providerMultiKeyStrategyRoundRobin
                    ? Icon(Icons.check, color: colors.primary, size: 18)
                    : const SizedBox.shrink(),
                onTap: () => Navigator.of(
                  sheetContext,
                ).pop(providerMultiKeyStrategyRoundRobin),
              ),
              MoeSettingsRow(
                icon: Icons.shuffle_outlined,
                label: '随机',
                trailingType: MoeSettingsRowTrailing.custom,
                trailing: current == providerMultiKeyStrategyRandom
                    ? Icon(Icons.check, color: colors.primary, size: 18)
                    : const SizedBox.shrink(),
                onTap: () => Navigator.of(
                  sheetContext,
                ).pop(providerMultiKeyStrategyRandom),
              ),
              MoeSettingsRow(
                icon: Icons.hourglass_bottom_outlined,
                label: '用尽',
                subtitle: '当前 Key 报错后再切换',
                trailingType: MoeSettingsRowTrailing.custom,
                trailing: current == providerMultiKeyStrategyExhaust
                    ? Icon(Icons.check, color: colors.primary, size: 18)
                    : const SizedBox.shrink(),
                onTap: () => Navigator.of(
                  sheetContext,
                ).pop(providerMultiKeyStrategyExhaust),
              ),
            ],
          ),
        );
      },
    );
    if (selected == null || selected == current) return;
    await _saveItems(provider, items, strategy: selected);
    if (!mounted) return;
    MoeToast.show(context, '已切换为${providerMultiKeyStrategyLabel(selected)}');
  }

  Future<bool> _recordDetectionResult(
    ProviderAuth testedProvider,
    ProviderMultiKeyItem testedItem,
    bool ok,
  ) async {
    if (!mounted) return false;
    final current = ref
        .read(appSettingsProvider)
        .asData
        ?.value
        .getProvider(widget.providerId);
    if (current == null ||
        current.apiBaseUrl != testedProvider.apiBaseUrl ||
        resolveProviderDetailChatProvider(current) !=
            resolveProviderDetailChatProvider(testedProvider) ||
        resolveProviderDetailChatApiPath(current) !=
            resolveProviderDetailChatApiPath(testedProvider)) {
      return false;
    }
    final items = providerMultiKeyItemsFromProvider(current);
    final target = items.where((item) => item.id == testedItem.id).firstOrNull;
    if (target == null || target.key.trim() != testedItem.key.trim())
      return false;
    final now = DateTime.now().millisecondsSinceEpoch;
    final updated = target.copyWith(
      status: ok ? ProviderMultiKeyStatus.normal : ProviderMultiKeyStatus.error,
      totalRequests: target.totalRequests + 1,
      successRequests: target.successRequests + (ok ? 1 : 0),
      failedRequests: target.failedRequests + (ok ? 0 : 1),
      consecutiveFailures: ok ? 0 : target.consecutiveFailures + 1,
      lastUsedAt: now,
      lastError: ok ? null : '检测失败',
      clearLastError: ok,
      updatedAt: now,
    );
    await _saveItems(current, [
      for (final item in items)
        if (item.id == target.id) updated else item,
    ]);
    return true;
  }

  Future<void> _detectAll(
    ProviderAuth provider,
    List<ProviderMultiKeyItem> items,
  ) async {
    final modelId = _resolveDetectModel(provider);
    if (modelId == null) {
      MoeToast.show(context, '请先给渠道添加模型', type: ToastType.warning);
      return;
    }
    if (_detecting || _testingKeyId != null) return;
    setState(() => _detecting = true);
    var successCount = 0;
    var testedCount = 0;
    try {
      for (final queuedItem in items) {
        if (!mounted) return;
        final current = ref
            .read(appSettingsProvider)
            .asData
            ?.value
            .getProvider(widget.providerId);
        if (current == null) return;
        final item = providerMultiKeyItemsFromProvider(
          current,
        ).where((item) => item.id == queuedItem.id).firstOrNull;
        if (item == null || item.key.trim().isEmpty) continue;
        setState(() => _testingKeyId = item.id);
        final ok = await _testKey(
          current,
          modelId: modelId,
          apiKey: item.key.trim(),
        );
        if (!mounted) return;
        if (await _recordDetectionResult(current, item, ok)) {
          testedCount++;
          if (ok) successCount++;
        }
        if (!mounted) return;
        await Future<void>.delayed(const Duration(milliseconds: 80));
      }
      if (mounted) MoeToast.show(context, '检测完成：$successCount/$testedCount 正常');
    } finally {
      if (mounted)
        setState(() {
          _detecting = false;
          _testingKeyId = null;
        });
    }
  }

  Future<void> _detectOne(
    ProviderAuth provider,
    List<ProviderMultiKeyItem> items,
    ProviderMultiKeyItem target,
  ) async {
    final modelId = _resolveDetectModel(provider);
    if (modelId == null) {
      MoeToast.show(context, '请先给渠道添加模型', type: ToastType.warning);
      return;
    }
    if (_detecting || _testingKeyId != null) return;
    setState(() => _testingKeyId = target.id);
    try {
      final ok = await _testKey(
        provider,
        modelId: modelId,
        apiKey: target.key.trim(),
      );
      if (!mounted) return;
      final applied = await _recordDetectionResult(provider, target, ok);
      if (mounted && applied)
        MoeToast.show(context, ok ? 'Key 可用' : 'Key 检测失败');
    } finally {
      if (mounted) setState(() => _testingKeyId = null);
    }
  }

  Future<void> _deleteErrorKeys(
    ProviderAuth provider,
    List<ProviderMultiKeyItem> items,
  ) async {
    final toDelete = items.where(
      (item) => item.status == ProviderMultiKeyStatus.error,
    );
    if (toDelete.isEmpty) {
      MoeToast.show(context, '没有错误 Key');
      return;
    }
    final confirmed = await showMeoTalkDialog(
      context: context,
      title: '删除错误 Key',
      content: Text('将删除 ${toDelete.length} 个错误 Key，确定继续吗？'),
      confirmText: '删除',
      cancelText: '取消',
    );
    if (confirmed != true) return;
    final next = items
        .where((item) => item.status != ProviderMultiKeyStatus.error)
        .toList();
    await _saveItems(provider, next);
    if (!mounted) return;
    MoeToast.show(context, '已删除 ${toDelete.length} 个错误 Key');
  }

  Future<ProviderMultiKeyFormResult?> _showMultiKeyFormSheet({
    required String title,
    required String confirmText,
    String initialKey = '',
    String? initialAlias,
    bool allowBatchInput = false,
  }) async {
    final aliasController = allowBatchInput
        ? null
        : TextEditingController(text: initialAlias ?? '');
    final keyController = TextEditingController(text: initialKey);

    try {
      return await showMoeBottomSheet<ProviderMultiKeyFormResult>(
        context: context,
        title: title,
        showCloseButton: true,
        maxHeight: MediaQuery.sizeOf(context).height * 0.82,
        builder: (sheetContext) => _MultiKeyFormSheet(
          aliasController: aliasController,
          keyController: keyController,
          allowBatchInput: allowBatchInput,
          confirmText: confirmText,
          onCancel: () => Navigator.of(sheetContext).pop(),
          onSubmit: () => Navigator.of(sheetContext).pop(
            ProviderMultiKeyFormResult(
              key: keyController.text,
              alias: aliasController?.text.trim(),
            ),
          ),
        ),
      );
    } finally {
      aliasController?.dispose();
      keyController.dispose();
    }
  }

  List<String> _splitKeys(String raw) {
    return raw
        .replaceAll(',', ' ')
        .split(RegExp(r'\s+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  Future<void> _addKeys(
    ProviderAuth provider,
    List<ProviderMultiKeyItem> items,
  ) async {
    final result = await _showMultiKeyFormSheet(
      title: '添加 Key',
      confirmText: '添加',
      allowBatchInput: true,
    );
    if (result == null || !mounted) return;

    final exists = items.map((e) => e.key.trim()).toSet();
    final incoming = _splitKeys(result.key);
    final now = DateTime.now().millisecondsSinceEpoch;
    final next = List<ProviderMultiKeyItem>.from(items);
    var added = 0;
    for (final key in incoming) {
      if (exists.contains(key)) continue;
      next.add(
        ProviderMultiKeyItem(
          id: ProviderMultiKeyItem.createId(),
          key: key,
          updatedAt: now,
        ),
      );
      exists.add(key);
      added++;
    }
    if (added == 0) {
      MoeToast.show(context, '没有可新增的 Key');
      return;
    }
    await _saveItems(provider, next);
    if (!mounted) return;
    MoeToast.show(context, '已新增 $added 个 Key');
  }

  Future<void> _editKey(
    ProviderAuth provider,
    List<ProviderMultiKeyItem> items,
    ProviderMultiKeyItem target,
  ) async {
    final key = TextEditingController(text: target.key);
    final alias = TextEditingController(text: target.alias ?? '');
    await showMoeBottomSheet<void>(
      context: context,
      title: '编辑 Key',
      showCloseButton: true,
      isDismissible: false,
      enableDrag: false,
      builder: (context) => MoeAutoSaveForm(
        disposeFields: true,
        fields: [key, alias],
        snapshot: () => moeAutoSaveSignature([key.text, alias.text]),
        save: () async {
          final value = key.text.trim();
          final name = alias.text.trim();
          if (value.isEmpty) throw const FormatException('Key 不能为空');
          final current = ref
              .read(appSettingsProvider)
              .requireValue
              .providers
              .where((p) => p.id == provider.id)
              .firstOrNull;
          if (current == null) throw const FormatException('渠道已不存在');
          final entries = providerMultiKeyItemsFromProvider(current);
          if (entries.any(
            (item) =>
                item.id != target.id &&
                item.key.trim().toLowerCase() == value.toLowerCase(),
          )) {
            throw const FormatException('Key 已存在');
          }
          if (!entries.any((item) => item.id == target.id)) {
            throw const FormatException('Key 已不存在');
          }
          await _saveItems(
            current,
            entries
                .map(
                  (item) => item.id == target.id
                      ? item.copyWith(
                          key: value,
                          alias: name,
                          clearAlias: name.isEmpty,
                          updatedAt: DateTime.now().millisecondsSinceEpoch,
                        )
                      : item,
                )
                .toList(),
          );
        },
        builder: (context, update) => Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              MoeTextField(controller: alias, label: '备注'),
              const SizedBox(height: 12),
              MoeTextField(controller: key, label: 'API Key'),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _deleteKey(
    ProviderAuth provider,
    List<ProviderMultiKeyItem> items,
    ProviderMultiKeyItem target,
  ) async {
    final confirmed = await showMeoTalkDialog(
      context: context,
      title: '删除 Key',
      content: Text(
        '确定删除 ${target.alias ?? maskProviderMultiKeyValue(target.key)} 吗？',
      ),
      confirmText: '删除',
      cancelText: '取消',
    );
    if (confirmed != true) return;

    final next = items.where((item) => item.id != target.id).toList();
    await _saveItems(provider, next);
    if (!mounted) return;
    MoeToast.show(context, '已删除');
  }

  Future<void> _toggleKeyEnabled(
    ProviderAuth provider,
    List<ProviderMultiKeyItem> items,
    ProviderMultiKeyItem target,
    bool value,
  ) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final next = items.map((item) {
      if (item.id != target.id) return item;
      return item.copyWith(enabled: value, updatedAt: now);
    }).toList();
    await _saveItems(provider, next);
  }

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(appSettingsProvider);
    final colors = context.moeColors;

    return settingsAsync.when(
      loading: () => MoePageScaffold(
        extendBodyBehindAppBar: true,
        backgroundColor: colors.surface,
        appBar: const MoeAppBar(title: '多 Key 管理', showBackButton: true),
        body: const Center(child: MoeLoadingIndicator()),
      ),
      error: (e, _) => MoePageScaffold(
        extendBodyBehindAppBar: true,
        backgroundColor: colors.surface,
        appBar: const MoeAppBar(title: '多 Key 管理', showBackButton: true),
        body: MoeEmptyState(title: '加载失败', description: e.toString()),
      ),
      data: (settings) {
        final provider = settings.providers.firstWhere(
          (p) => p.id == widget.providerId,
          orElse: () => const ProviderAuth(
            id: '',
            displayName: '',
            apiBaseUrl: '',
            apiKeys: <String>[],
          ),
        );
        if (provider.id.isEmpty) {
          return const MoePageScaffold(
            extendBodyBehindAppBar: true,
            appBar: MoeAppBar(title: '多 Key 管理', showBackButton: true),
            body: MoeEmptyState(title: '渠道不存在'),
          );
        }

        final items = providerMultiKeyItemsFromProvider(provider);
        final total = items.length;
        final normal = items
            .where((item) => item.status == ProviderMultiKeyStatus.normal)
            .length;
        final error = items
            .where((item) => item.status == ProviderMultiKeyStatus.error)
            .length;
        final strategy = providerMultiKeyStrategyLabel(
          providerMultiKeyStrategy(provider),
        );

        return LayoutBuilder(builder: (context, constraints) {
          return MoePageScaffold(
          extendBodyBehindAppBar: true,
          backgroundColor: colors.surface,
          appBar: MoeAppBar(
            title: '多 Key 管理',
            showBackButton: true,
            actions: [
              if (constraints.maxWidth < 480)
                Builder(builder: (buttonContext) => IconButton(
                  tooltip: '更多 Key 操作',
                  icon: Icon(Icons.more_horiz, color: colors.text),
                  onPressed: () => MoePopupMenu.show(buttonContext,
                    targetBox: buttonContext.findRenderObject()! as RenderBox,
                    alignToEnd: true,
                    items: [
                      MoePopupMenuItem(icon: Icons.add, label: '添加',
                        onTap: () { if (mounted) _addKeys(provider, items); }),
                      MoePopupMenuItem(icon: Icons.monitor_heart_outlined,
                        label: _detecting ? '检测中...' : '检测全部 Key',
                        onTap: () { if (mounted && !_detecting) _detectAll(provider, items); }),
                      MoePopupMenuItem(icon: Icons.delete_outline,
                        label: '删除错误 Key', danger: true,
                        onTap: () { if (mounted) _deleteErrorKeys(provider, items); }),
                    ],
                  ),
                ))
              else ...[
              IconButton(
                icon: Icon(Icons.delete_outline, color: colors.text),
                tooltip: '删除错误 Key',
                onPressed: () => _deleteErrorKeys(provider, items),
              ),
              IconButton(
                icon: _detecting
                    ? SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: colors.text,
                        ),
                      )
                    : Icon(Icons.monitor_heart_outlined, color: colors.text),
                tooltip: '检测',
                onPressed: _detecting
                    ? null
                    : () => _detectAll(provider, items),
              ),
              IconButton(
                icon: Icon(Icons.add, color: colors.text),
                tooltip: '添加',
                onPressed: () => _addKeys(provider, items),
              ),
              ],
            ],
          ),
          body: Builder(
            builder: (context) => SingleChildScrollView(
              padding: moeUnderBarPadding(
                context,
                EdgeInsets.fromLTRB(16, 12, 16, 24),
              ),
              child: Column(
                children: [
                  MoeSettingsGroup(
                    margin: EdgeInsets.zero,
                    children: [
                      MoeSettingsRow(
                        icon: Icons.numbers,
                        label: '总数',
                        trailingType: MoeSettingsRowTrailing.text,
                        detailText: '$total',
                      ),
                      MoeSettingsRow(
                        icon: Icons.check_circle_outline,
                        label: '正常',
                        trailingType: MoeSettingsRowTrailing.text,
                        detailText: '$normal',
                      ),
                      MoeSettingsRow(
                        icon: Icons.error_outline,
                        label: '错误',
                        trailingType: MoeSettingsRowTrailing.text,
                        detailText: '$error',
                      ),
                      MoeSettingsRow(
                        icon: Icons.sync_alt_outlined,
                        label: '负载均衡策略',
                        trailingType: MoeSettingsRowTrailing.text,
                        detailText: strategy,
                        onTap: () => _pickStrategy(provider, items),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (items.isEmpty)
                    MoeSettingsGroup(
                      margin: EdgeInsets.zero,
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 20),
                          child: Center(
                            child: Text(
                              '暂无 Key',
                              style: TextStyle(
                                color: colors.muted,
                                fontSize: 14,
                              ),
                            ),
                          ),
                        ),
                      ],
                    )
                  else
                    MoeSettingsGroup(
                      margin: EdgeInsets.zero,
                      children: [
                        for (final item in items)
                          _MultiKeyRow(
                            item: item,
                            colors: colors,
                            testing: _testingKeyId == item.id,
                            onToggleEnabled: (value) =>
                                _toggleKeyEnabled(provider, items, item, value),
                            onDetect: () => _detectOne(provider, items, item),
                            onEdit: () => _editKey(provider, items, item),
                            onDelete: () => _deleteKey(provider, items, item),
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ),
          );
        });
      },
    );
  }
}

class _MultiKeyFormSheet extends StatelessWidget {
  const _MultiKeyFormSheet({
    required this.keyController,
    required this.allowBatchInput,
    required this.confirmText,
    required this.onCancel,
    required this.onSubmit,
    this.aliasController,
  });

  final TextEditingController? aliasController;
  final TextEditingController keyController;
  final bool allowBatchInput;
  final String confirmText;
  final VoidCallback onCancel;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: (constraints.maxWidth - 32).clamp(0.0, double.infinity)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (aliasController != null) ...[
                MoeTextField(
                  controller: aliasController,
                  label: '备注',
                  hint: '给这个 Key 起个名字（可选）',
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 12),
              ],
              MoeTextField(
                controller: keyController,
                autofocus: true,
                label: allowBatchInput ? 'API Key 列表' : 'API Key',
                hint: allowBatchInput
                    ? '请输入 API Key（多个可用空格或逗号分隔）'
                    : '请输入 API Key',
                minLines: allowBatchInput ? 4 : 1,
                maxLines: allowBatchInput ? 8 : 1,
                keyboardType: allowBatchInput
                    ? TextInputType.multiline
                    : TextInputType.text,
                textInputAction: allowBatchInput
                    ? TextInputAction.newline
                    : TextInputAction.done,
                onSubmitted: allowBatchInput ? null : (_) => onSubmit(),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: MoeSecondaryButton(label: '取消', onPressed: onCancel),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: MoePrimaryButton(
                      label: confirmText,
                      onPressed: onSubmit,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MultiKeyRow extends StatelessWidget {
  const _MultiKeyRow({
    required this.item,
    required this.colors,
    required this.testing,
    required this.onToggleEnabled,
    required this.onDetect,
    required this.onEdit,
    required this.onDelete,
  });

  final ProviderMultiKeyItem item;
  final MoeColors colors;
  final bool testing;
  final ValueChanged<bool> onToggleEnabled;
  final VoidCallback onDetect;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final statusColor = item.status == ProviderMultiKeyStatus.error
        ? const Color(0xFFE53935)
        : const Color(0xFF43A047);
    final statusText = item.status == ProviderMultiKeyStatus.error
        ? '错误'
        : '正常';
    final title = (item.alias?.trim().isNotEmpty ?? false)
        ? '${item.alias} · ${maskProviderMultiKeyValue(item.key)}'
        : maskProviderMultiKeyValue(item.key);

    final details = <Widget>[
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: statusColor.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(statusText, style: TextStyle(
          color: statusColor, fontSize: 12,
          fontWeight: MoeFontWeights.emphasis,
        )),
      ),
      const SizedBox(width: 8),
      Expanded(child: Text(title, maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: colors.text, fontSize: 16,
          fontWeight: MoeFontWeights.emphasis),
      )),
    ];
    final actions = <Widget>[
      MoeSwitch(value: item.enabled, onChanged: onToggleEnabled),
      if (testing)
        SizedBox(width: 48, height: 48,
          child: Center(child: SizedBox(width: 18, height: 18,
            child: CircularProgressIndicator(strokeWidth: 2,
              color: colors.primary),
          )),
        )
      else
        IconButton(
          icon: Icon(Icons.monitor_heart_outlined, color: colors.textSecondary),
          tooltip: '检测', onPressed: onDetect,
        ),
      IconButton(
        icon: Icon(Icons.edit_outlined, color: colors.textSecondary),
        tooltip: '编辑', onPressed: onEdit,
      ),
      IconButton(
        icon: Icon(Icons.delete_outline, color: colors.toastError),
        tooltip: '删除', onPressed: onDelete,
      ),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: LayoutBuilder(builder: (context, constraints) {
        if (constraints.maxWidth < 480) {
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: details),
              const SizedBox(height: 6),
              Align(alignment: Alignment.centerRight,
                child: Wrap(spacing: 4, runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: actions),
              ),
            ],
          );
        }
        return Row(children: [...details, const SizedBox(width: 4), ...actions]);
      }),
    );
  }
}
