import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/tokens.dart';
import '../../../settings/app_settings.dart';
import 'import_model_dialog.dart';

class ModelListPage extends ConsumerWidget {
  const ModelListPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsAsync = ref.watch(appSettingsProvider);
    final colors = context.moeColors;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: colors.surface,
        foregroundColor: colors.text,
        elevation: 0,
        title: Text('模型管理', style: TextStyle(color: colors.text)),
        actions: [
          IconButton(
            tooltip: '搜索模型',
            icon: const Icon(Icons.search),
            onPressed: () async {
              await showDialog(
                context: context,
                builder: (_) => _ModelSearchDialog(ref: ref),
              );
            },
          ),
          IconButton(
            tooltip: '导入渠道',
            icon: const Icon(Icons.add),
            onPressed: () async {
              await showDialog(
                context: context,
                builder: (_) => const ImportModelDialog(),
              );
            },
          ),
        ],
      ),
      backgroundColor: colors.surface,
      body: settingsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载失败: $e')),
        data: (settings) {
          if (settings.providers.isEmpty) {
            return Center(
              child: Text(
                '还没有配置任何渠道，请先导入。',
                style: TextStyle(color: colors.muted),
              ),
            );
          }
          final providers = [...settings.providers]
            ..sort((a, b) => _providerTitle(a).toLowerCase().compareTo(_providerTitle(b).toLowerCase()));
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              ...providers.map(
                (provider) => _ProviderSection(
                  provider: provider,
                  displayNames: settings.modelDisplayNames,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ProviderSection extends ConsumerWidget {
  final ProviderAuth provider;
  final Map<String, String> displayNames;

  const _ProviderSection({
    required this.provider,
    required this.displayNames,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final visible = _sortedModels(provider.visibleModels, displayNames);
    final hidden = _sortedModels(provider.hiddenModels, displayNames);
    final title = _providerTitle(provider);
    final notifier = ref.read(appSettingsProvider.notifier);
    final colors = context.moeColors;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      color: colors.surfaceAlt,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 标题和状态区域
            Row(
              children: [
                Icon(Icons.hub, color: colors.primary, size: 24),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                        overflow: TextOverflow.ellipsis,
                      ),
                            backgroundColor: colors.dialogWarning,
                            label: const Text('已停用'),
                            labelStyle: TextStyle(color: colors.text, fontSize: 11),
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // 操作按钮区域 - 第一行
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.edit_outlined, size: 16),
                    label: const Text('编辑', style: TextStyle(fontSize: 13)),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: () => _showEditProviderDialog(context, ref, provider),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.wifi_tethering, size: 16),
                    label: const Text('测试', style: TextStyle(fontSize: 13)),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: () => _testConnection(context, ref, provider),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // 操作按钮区域 - 第二行
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: Icon(
                      provider.enabled ? Icons.pause_circle_outline : Icons.play_circle_outline,
                      size: 16,
                    ),
                    label: Text(
                      provider.enabled ? '停用' : '启用',
                      style: const TextStyle(fontSize: 13),
                    ),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: () async {
                      final confirm = await _showConfirmDialog(
                        context,
                        provider.enabled ? '停用渠道' : '启用渠道',
                        provider.enabled
                            ? '停用后该渠道的模型不会出现在模型切换列表，确定继续吗？'
                            : '启用后该渠道的模型将重新可用，确定继续吗？',
                      );
                      if (confirm) {
                        await notifier.setProviderEnabled(provider.id, !provider.enabled);
                      }
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.delete_outline, size: 16),
                    label: const Text('删除', style: TextStyle(fontSize: 13)),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      visualDensity: VisualDensity.compact,
                      foregroundColor: const Color(0xFFB00020),
                    ),
                    onPressed: () async {
                      final confirm = await _showConfirmDialog(
                        context,
                        '删除渠道',
                        '确认删除渠道「$title」及其模型配置？该操作不可恢复。',
                      );
                      if (confirm) {
                        await notifier.deleteProvider(provider.id);
                      }
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text('已显示模型', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            if (visible.isEmpty)
              Text('暂无可见模型', style: TextStyle(color: colors.muted, fontSize: 12))
            else
              Column(
                children: visible
                    .map((model) => Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: _ModelRow(
                            providerId: provider.id,
                            model: model,
                            displayName: displayNames[model],
                            canHide: visible.length > 1,
                            providerEnabled: provider.enabled,
                          ),
                        ))
                    .toList(),
              ),
            if (hidden.isNotEmpty) ...[
              const SizedBox(height: 12),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text('隐藏模型（${hidden.length}）', style: const TextStyle(fontSize: 14)),
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: hidden
                        .map(
                          (model) => ActionChip(
                            avatar: const Icon(Icons.visibility_outlined, size: 16),
                            label: Text(
                              displayNames[model]?.isNotEmpty == true ? '${displayNames[model]} ($model)' : model,
                            ),
                            onPressed: provider.enabled
                                ? () {
                                    notifier.setModelVisibility(
                                      providerId: provider.id,
                                      modelId: model,
                                      visible: true,
                                    );
                                  }
                                : null,
                          ),
                        )
                        .toList(),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ModelChip extends StatelessWidget {
  final String model;
  final String? displayName;
  final bool isDefault;
  final VoidCallback? onHide;

  const _ModelChip({
    required this.model,
    required this.displayName,
    required this.isDefault,
    this.onHide,
  });

  @override
  Widget build(BuildContext context) {
    final label = displayName?.isNotEmpty == true ? '${displayName!} ($model)' : model;
    final colors = Theme.of(context).extension<MoeColors>() ?? MoeColors.light;
    return InputChip(
      avatar: isDefault ? Icon(Icons.star, size: 16, color: Colors.white) : null,
      label: Text(label),
      onDeleted: onHide,
      deleteIcon: onHide != null ? const Icon(Icons.visibility_off_outlined) : null,
      backgroundColor: isDefault ? colors.primary : colors.surface,
      labelStyle: TextStyle(
        color: isDefault ? Colors.white : colors.text,
        fontWeight: isDefault ? FontWeight.w600 : FontWeight.normal,
      ),
      side: BorderSide(color: isDefault ? colors.primary : colors.borderLight, width: borderWidth),
      deleteIconColor: onHide != null ? colors.muted : Colors.transparent,
    );
  }
}

/// 单行模型展示组件（用于已显示模型列表）
class _ModelRow extends ConsumerWidget {
  final String providerId;
  final String model;
  final String? displayName;
  final bool canHide;
  final bool providerEnabled;

  const _ModelRow({
    required this.providerId,
    required this.model,
    required this.displayName,
    required this.canHide,
    required this.providerEnabled,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(appSettingsProvider.notifier);

    final colors = context.moeColors;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.borderLight, width: borderWidth),
      ),
      child: Row(
        children: [
          // 模型信息
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  model,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: colors.text,
                  ),
                ),
                if (displayName != null && displayName!.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    displayName!,
                    style: TextStyle(
                      fontSize: 12,
                      color: colors.muted,
                    ),
                  ),
                ],
              ],
            ),
          ),
          // 编辑按钮
          IconButton(
            icon: const Icon(Icons.edit_outlined, size: 18),
            color: colors.muted,
            tooltip: '编辑备注',
            onPressed: () => _showEditModelNameDialog(
              context: context,
              ref: ref,
              modelId: model,
              currentDisplayName: displayName,
            ),
          ),
          // 可见性切换
          Switch(
            value: true, // 已显示模型始终为true
            onChanged: (canHide && providerEnabled)
                ? (value) {
                    if (!value) {
                      notifier.setModelVisibility(
                        providerId: providerId,
                        modelId: model,
                        visible: false,
                      );
                    }
                  }
                : null,
          ),
        ],
      ),
    );
  }
}

String _providerTitle(ProviderAuth provider) =>
    provider.displayName?.isNotEmpty == true ? provider.displayName! : provider.id;

List<String> _sortedModels(List<String> models, Map<String, String> displayNames) {
  final unique = <String>[];
  final seen = <String>{};
  for (final model in models) {
    if (seen.add(model)) {
      unique.add(model);
    }
  }
  unique.sort((a, b) {
    final labelA = (displayNames[a] ?? a).toLowerCase();
    final labelB = (displayNames[b] ?? b).toLowerCase();
    return labelA.compareTo(labelB);
  });
  return unique;
}

Future<void> _showEditProviderDialog(BuildContext context, WidgetRef ref, ProviderAuth provider) async {
  final nameCtrl = TextEditingController(text: provider.displayName ?? '');
  final baseCtrl = TextEditingController(text: provider.apiBaseUrl);
  final keyCtrl = TextEditingController(text: provider.apiKeys.isNotEmpty ? provider.apiKeys.first : '');
  final formKey = GlobalKey<FormState>();

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: Text('编辑渠道：${_providerTitle(provider)}'),
        content: SizedBox(
          width: 400,
          child: Form(
            key: formKey,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(labelText: '显示名称'),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: baseCtrl,
                    decoration: const InputDecoration(labelText: 'API Base URL'),
                    validator: (value) => (value == null || value.trim().isEmpty) ? '请输入 API Base URL' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: keyCtrl,
                    decoration: const InputDecoration(
                      labelText: 'API Key',
                      hintText: '留空则不修改',
                    ),
                    obscureText: true,
                  ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              if (formKey.currentState?.validate() ?? false) {
                Navigator.pop(context, true);
              }
            },
            child: const Text('保存'),
          ),
        ],
      );
    },
  );

  if (confirmed == true) {
    final newKey = keyCtrl.text.trim();
    await ref.read(appSettingsProvider.notifier).editProvider(
          providerId: provider.id,
          displayName: nameCtrl.text.trim().isEmpty ? null : nameCtrl.text.trim(),
          apiBaseUrl: baseCtrl.text.trim(),
          apiKeys: newKey.isNotEmpty ? [newKey] : null,
        );
  }
}

Future<bool> _showConfirmDialog(BuildContext context, String title, String message) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('确认')),
      ],
    ),
  );
  return result ?? false;
}

/// 模型搜索弹窗
class _ModelSearchDialog extends StatefulWidget {
  final WidgetRef ref;

  const _ModelSearchDialog({required this.ref});

  @override
  State<_ModelSearchDialog> createState() => _ModelSearchDialogState();
}

class _ModelSearchDialogState extends State<_ModelSearchDialog> {
  final _searchCtrl = TextEditingController();
  String _searchQuery = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settingsAsync = widget.ref.watch(appSettingsProvider);

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: MediaQuery.of(context).size.width * 0.9,
        height: MediaQuery.of(context).size.height * 0.8,
        decoration: BoxDecoration(
          color: moeSurface,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          children: [
            // 顶部搜索栏
            Container(
              padding: const EdgeInsets.all(16),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: moeBorderLight)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.search, color: moeMuted),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _searchCtrl,
                      autofocus: true,
                      decoration: const InputDecoration(
                        hintText: '搜索模型ID或备注...',
                        border: InputBorder.none,
                      ),
                      onChanged: (value) {
                        setState(() {
                          _searchQuery = value.toLowerCase().trim();
                        });
                      },
                    ),
                  ),
                  if (_searchCtrl.text.isNotEmpty)
                    IconButton(
                      icon: const Icon(Icons.clear, size: 20),
                      onPressed: () {
                        setState(() {
                          _searchCtrl.clear();
                          _searchQuery = '';
                        });
                      },
                    ),
                ],
              ),
            ),
            // 搜索结果列表
            Expanded(
              child: settingsAsync.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => Center(child: Text('加载失败: $e')),
                data: (settings) {
                  final searchResults = _buildSearchResults(settings);
                  if (searchResults.isEmpty) {
                    return Center(
                      child: Text(
                        _searchQuery.isEmpty ? '请输入搜索关键词' : '未找到匹配的模型',
                        style: const TextStyle(color: moeMuted),
                      ),
                    );
                  }
                  return ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: searchResults.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final result = searchResults[index];
                      return _SearchResultRow(
                        modelId: result.modelId,
                        displayName: result.displayName,
                        providerId: result.providerId,
                        providerName: result.providerName,
                        isVisible: result.isVisible,
                        ref: widget.ref,
                      );
                    },
                  );
                },
              ),
            ),
            // 底部关闭按钮
            Container(
              padding: const EdgeInsets.all(16),
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: moeBorderLight)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('关闭'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<_ModelSearchResult> _buildSearchResults(AppSettings settings) {
    final results = <_ModelSearchResult>[];
    final seenModels = <String>{};

    for (final provider in settings.providers) {
      final allModels = <String>{
        ...provider.models,
        ...provider.visibleModels,
        ...provider.hiddenModels,
      };

      for (final modelId in allModels) {
        if (seenModels.contains(modelId)) continue;
        seenModels.add(modelId);

        final displayName = settings.modelDisplayNames[modelId];
        final isVisible = provider.visibleModels.contains(modelId);

        // 搜索匹配逻辑
        if (_searchQuery.isEmpty ||
            modelId.toLowerCase().contains(_searchQuery) ||
            (displayName?.toLowerCase().contains(_searchQuery) ?? false)) {
          results.add(_ModelSearchResult(
            modelId: modelId,
            displayName: displayName,
            providerId: provider.id,
            providerName: _providerTitle(provider),
            isVisible: isVisible,
          ));
        }
      }
    }

    // 排序：先按可见性，再按模型ID
    results.sort((a, b) {
      if (a.isVisible != b.isVisible) return a.isVisible ? -1 : 1;
      return a.modelId.toLowerCase().compareTo(b.modelId.toLowerCase());
    });

    return results;
  }
}

class _ModelSearchResult {
  final String modelId;
  final String? displayName;
  final String providerId;
  final String providerName;
  final bool isVisible;

  _ModelSearchResult({
    required this.modelId,
    required this.displayName,
    required this.providerId,
    required this.providerName,
    required this.isVisible,
  });
}

/// 搜索结果行组件
class _SearchResultRow extends ConsumerWidget {
  final String modelId;
  final String? displayName;
  final String providerId;
  final String providerName;
  final bool isVisible;
  final WidgetRef ref;

  const _SearchResultRow({
    required this.modelId,
    required this.displayName,
    required this.providerId,
    required this.providerName,
    required this.isVisible,
    required this.ref,
  });

  @override
  Widget build(BuildContext context, WidgetRef localRef) {
    final notifier = ref.read(appSettingsProvider.notifier);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: moeSurfaceAlt,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: moeBorderLight, width: borderWidth),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  modelId,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: moeText,
                  ),
                ),
                if (displayName != null && displayName!.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    displayName!,
                    style: const TextStyle(
                      fontSize: 12,
                      color: moeMuted,
                    ),
                  ),
                ],
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: moeSurface,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: moeBorderLight),
                  ),
                  child: Text(
                    providerName,
                    style: const TextStyle(fontSize: 11, color: moeMuted),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                isVisible ? '已显示' : '已隐藏',
                style: TextStyle(
                  fontSize: 11,
                  color: isVisible ? moePrimary : moeMuted,
                ),
              ),
              Switch(
                value: isVisible,
                onChanged: (value) {
                  notifier.setModelVisibility(
                    providerId: providerId,
                    modelId: modelId,
                    visible: value,
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 编辑模型备注弹窗
Future<void> _showEditModelNameDialog({
  required BuildContext context,
  required WidgetRef ref,
  required String modelId,
  String? currentDisplayName,
}) async {
  final ctrl = TextEditingController(text: currentDisplayName ?? '');
  final formKey = GlobalKey<FormState>();

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: const Text('编辑模型备注'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '模型ID: $modelId',
                style: const TextStyle(fontSize: 12, color: moeMuted),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: ctrl,
                decoration: const InputDecoration(
                  labelText: '显示名称（备注）',
                  hintText: '留空则显示原始ID',
                ),
                autofocus: true,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('保存'),
          ),
        ],
      );
    },
  );

  if (confirmed == true) {
    try {
      await ref.read(appSettingsProvider.notifier).setModelDisplayName(
            modelId: modelId,
            displayName: ctrl.text.trim().isEmpty ? null : ctrl.text.trim(),
          );
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('备注已保存'), duration: Duration(seconds: 1)),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败: $e'), duration: const Duration(seconds: 1)),
      );
    }
  }
}

/// 从完整URL提取域名
String _extractDomain(String url) {
  try {
    final uri = Uri.parse(url);
    return uri.host.isNotEmpty ? uri.host : url;
  } catch (_) {
    return url;
  }
}

/// 脱敏显示API Key
String _maskApiKey(String key) {
  if (key.length <= 8) return '***';
  return '${key.substring(0, 3)}***${key.substring(key.length - 3)}';
}

/// 测试渠道连接
Future<void> _testConnection(BuildContext context, WidgetRef ref, ProviderAuth provider) async {
  if (provider.apiKeys.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('该渠道未配置 API Key，无法测试'), duration: Duration(seconds: 1)),
    );
    return;
  }

  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (context) => const Center(
      child: Card(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('正在测试连接...'),
            ],
          ),
        ),
      ),
    ),
  );

  try {
    final models = await ref.read(appSettingsProvider.notifier).previewProviderModels(
          providerId: provider.id,
          apiKey: provider.apiKeys.first,
          apiBaseUrl: provider.apiBaseUrl,
        );

    if (!context.mounted) return;
    Navigator.pop(context); // 关闭加载对话框

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.check_circle, color: Colors.green),
            SizedBox(width: 8),
            Text('连接成功'),
          ],
        ),
        content: Text('成功获取到 ${models.length} 个模型'),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  } catch (e) {
    if (!context.mounted) return;
    Navigator.pop(context); // 关闭加载对话框

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.error, color: Colors.red),
            SizedBox(width: 8),
            Text('连接失败'),
          ],
        ),
        content: SingleChildScrollView(
          child: Text('错误信息：\n$e'),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }
}
class _CapabilityInfo {
  final String label;
  final String shortLabel;
  final IconData icon;
  const _CapabilityInfo(this.label, this.shortLabel, this.icon);
}

_CapabilityInfo _getCapabilityInfo(String capability) {
  switch (capability) {
    case 'chat':
      return const _CapabilityInfo('聊天对话', '聊天', Icons.chat_bubble_outline);
    case 'embedding':
      return const _CapabilityInfo('向量嵌入', '嵌入', Icons.scatter_plot);
    case 'tts':
      return const _CapabilityInfo('语音生成', '语音', Icons.record_voice_over);
    case 'image':
      return const _CapabilityInfo('图片生成', '图片', Icons.image_outlined);
    default:
      return const _CapabilityInfo('未知', '?', Icons.help_outline);
  }
}
