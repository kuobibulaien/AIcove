/// ModelPickerSheet - 模型选择器弹窗
///
/// 从供应商 API 获取可用模型列表，让用户选择要导入哪些模型。
///
/// 设计特点：
/// - 底部弹窗样式
/// - 实时搜索过滤
/// - 支持全选/反选
/// - 用户选择后才导入模型
/// - 公共导航栏、按内容收缩的列表与固定底部操作区
///
/// 更新记录：
/// - 2026-01-25: 修复键盘弹出时底部按钮跳动问题
/// - 2026-01-21: 创建模型选择器
library;

import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import '../../../theme/moe_interaction_theme.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/settings/app_settings.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/widgets/index.dart';

/// Uses the shared shell; selection remains local until explicit import.
Future<void> showModelPickerSheet(
  BuildContext context,
  WidgetRef ref, {
  required String providerId,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: false,
    constraints: const BoxConstraints(maxWidth: 640),
    builder: (context) => _ModelPickerContent(ref: ref, providerId: providerId),
  );
}

/// 选择器内容
class _ModelPickerContent extends StatefulWidget {
  final WidgetRef ref;
  final String providerId;

  const _ModelPickerContent({required this.ref, required this.providerId});

  @override
  State<_ModelPickerContent> createState() => _ModelPickerContentState();
}

class _ModelPickerContentState extends State<_ModelPickerContent> {
  final _searchCtrl = TextEditingController();
  String _searchQuery = '';

  bool _isLoading = true;
  String? _error;
  List<String> _availableModels = [];
  Set<String> _selectedModels = {};

  @override
  void initState() {
    super.initState();
    _loadModels();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadModels() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final notifier = widget.ref.read(appSettingsProvider.notifier);
      final settings = widget.ref.read(appSettingsProvider).value;
      if (settings == null) throw Exception('设置未加载');

      final provider = settings.providers.firstWhere(
        (p) => p.id == widget.providerId,
        orElse: () => throw Exception('供应商不存在'),
      );

      final models = await notifier.previewProviderModels(
        providerId: provider.id,
        apiKey: provider.apiKeys.isNotEmpty ? provider.apiKeys.first : '',
        apiBaseUrl: provider.apiBaseUrl,
        customConfig: provider.customConfig,
      );

      // 预选已经在 visibleModels 中的模型
      final existingVisible = provider.visibleModels.toSet();

      if (mounted) {
        setState(() {
          _availableModels = models;
          _selectedModels = existingVisible.intersection(models.toSet());
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  List<String> get _filteredModels {
    if (_searchQuery.isEmpty) return _availableModels;
    return _availableModels
        .where((m) => m.toLowerCase().contains(_searchQuery))
        .toList();
  }

  void _toggleModel(String modelId) {
    HapticFeedback.selectionClick();
    setState(() {
      if (_selectedModels.contains(modelId)) {
        _selectedModels.remove(modelId);
      } else {
        _selectedModels.add(modelId);
      }
    });
  }

  void _selectAll() {
    HapticFeedback.lightImpact();
    setState(() {
      _selectedModels.addAll(_filteredModels);
    });
  }

  void _deselectAll() {
    HapticFeedback.lightImpact();
    setState(() {
      _selectedModels.removeAll(_filteredModels);
    });
  }

  Future<void> _confirmSelection() async {
    if (_selectedModels.isEmpty) {
      MoeToast.show(context, '请至少选择一个模型', type: ToastType.error);
      return;
    }

    final notifier = widget.ref.read(appSettingsProvider.notifier);

    // 更新供应商的模型列表
    await notifier.updateProviderModels(
      providerId: widget.providerId,
      allModels: _availableModels,
      visibleModels: _selectedModels.toList(),
      hiddenModels: _availableModels
          .where((m) => !_selectedModels.contains(m))
          .toList(),
    );

    if (mounted) {
      Navigator.of(context).pop();
      MoeToast.show(context, '已导入 ${_selectedModels.length} 个模型');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final filtered = _filteredModels;
    final allSelected =
        filtered.isNotEmpty &&
        filtered.every((m) => _selectedModels.contains(m));

    return MoeBottomSheet(
      title: '选择模型',
      showCloseButton: true,
      titleTrailing: TextButton(
        style: withoutHoverFeedback(
          TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            minimumSize: const Size(44, 44),
          ),
        ),
        onPressed: filtered.isEmpty
            ? null
            : (allSelected ? _deselectAll : _selectAll),
        child: Text(
          allSelected ? '取消全选' : '全选',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 15,
            color: colors.primary,
            fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily,
          ),
        ),
      ),
      footer: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '已选择 ${_selectedModels.length} 个模型',
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.textSecondary, fontSize: 13),
          ),
          const SizedBox(height: 10),
          MoePrimaryButton(
            label: '确认导入',
            size: MoePrimaryButtonSize.lg,
            width: double.infinity,
            borderRadius: BorderRadius.circular(16),
            backgroundColor: colors.primary,
            foregroundColor: colors.text,
            onPressed: _selectedModels.isNotEmpty ? _confirmSelection : null,
          ),
        ],
      ),
      child: CustomScrollView(
        shrinkWrap: true,
        slivers: [
          SliverToBoxAdapter(
            child: MoeSearchField(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
              controller: _searchCtrl,
              hintText: '搜索模型',
              onChanged: (value) => setState(() {
                _searchQuery = value.toLowerCase().trim();
              }),
            ),
          ),
          if (_isLoading || _error != null || filtered.isEmpty)
            SliverToBoxAdapter(
              child: _isLoading
                  ? const SizedBox(
                      height: 120,
                      child: Center(child: MoeLoadingIndicator()),
                    )
                  : _error != null
                  ? MoeEmptyState(
                      icon: Icons.error_outline,
                      title: '获取失败',
                      description: _error!,
                      action: MoeSecondaryButton(
                        label: '重试',
                        onPressed: _loadModels,
                      ),
                    )
                  : MoeEmptyState(
                      icon: Icons.search_off,
                      title: _availableModels.isEmpty ? '暂无可用模型' : '未找到匹配的模型',
                    ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate((context, index) {
                  if (index.isOdd) {
                    return Divider(
                      height: 1,
                      thickness: 0.5,
                      indent: 44,
                      color: colors.text.withValues(alpha: 0.10),
                    );
                  }
                  final modelId = filtered[index ~/ 2];
                  final isSelected = _selectedModels.contains(modelId);
                  return MoeSettingsRow(
                    icon: isSelected
                        ? CupertinoIcons.check_mark_circled_solid
                        : CupertinoIcons.circle,
                    iconColor: isSelected ? colors.primary : colors.muted,
                    label: modelId,
                    trailingType: MoeSettingsRowTrailing.none,
                    showDivider: false,
                    onTap: () => _toggleModel(modelId),
                  );
                }, childCount: filtered.length * 2 - 1),
              ),
            ),
        ],
      ),
    );
  }
}
