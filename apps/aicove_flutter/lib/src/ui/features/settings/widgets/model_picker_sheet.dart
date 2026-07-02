/// ModelPickerSheet - 模型选择器弹窗
///
/// 从供应商 API 获取可用模型列表，让用户选择要导入哪些模型。
///
/// 设计特点：
/// - 底部弹窗样式
/// - 实时搜索过滤
/// - 支持全选/反选
/// - 用户选择后才导入模型
/// - 搜索框在顶部，键盘弹出时底部按钮不移动
///
/// 更新记录：
/// - 2026-01-25: 修复键盘弹出时底部按钮跳动问题
/// - 2026-01-21: 创建模型选择器
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:figma_squircle/figma_squircle.dart';

import '../../../../features/settings/app_settings.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/shared/widgets/index.dart';

/// 显示模型选择器弹窗
///
/// 注意：此弹窗不使用公共的 showMoeBottomSheet，因为搜索框在顶部，
/// 键盘弹出时不会遮挡，底部按钮无需跟随键盘移动。
Future<void> showModelPickerSheet(
  BuildContext context,
  WidgetRef ref, {
  required String providerId,
}) async {
  await showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (context) => _ModelPickerSheet(
      ref: ref,
      providerId: providerId,
    ),
  );
}

/// 弹窗容器 - 不响应键盘
class _ModelPickerSheet extends StatelessWidget {
  final WidgetRef ref;
  final String providerId;

  const _ModelPickerSheet({
    required this.ref,
    required this.providerId,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final sheetBgColor = isDark ? colors.surface : Colors.white;
    final screenHeight = MediaQuery.sizeOf(context).height;
    final maxHeight = screenHeight * 0.85;

    const sheetBorderRadius = SmoothBorderRadius.vertical(
      top: SmoothRadius(cornerRadius: 16, cornerSmoothing: 0.6),
    );

    // 不使用 viewInsets.bottom，键盘弹出时底部按钮不动
    return Container(
      constraints: BoxConstraints(maxHeight: maxHeight),
      decoration: ShapeDecoration(
        color: sheetBgColor,
        shape: SmoothRectangleBorder(
          borderRadius: sheetBorderRadius,
          side: BorderSide(
            color: colors.border.withValues(alpha: isDark ? 0.3 : 0.15),
            width: 0.5,
          ),
        ),
        shadows: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.08),
            blurRadius: 16,
            spreadRadius: 0,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        child: SafeArea(
          top: false,
          // 关键：不让 SafeArea 响应键盘
          maintainBottomViewPadding: true,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 拖动指示器
              Container(
                margin: const EdgeInsets.only(top: 8, bottom: 4),
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: colors.muted.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              // 标题栏
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.close),
                      iconSize: 20,
                      color: colors.muted,
                      onPressed: () => Navigator.pop(context),
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 32, minHeight: 32),
                    ),
                    Expanded(
                      child: Text(
                        '选择模型',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: MoeFontWeights.emphasis,
                          color: colors.text,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(width: 32),
                  ],
                ),
              ),
              Divider(height: 1, color: colors.borderLight),
              // 内容
              Flexible(
                child: _ModelPickerContent(
                  ref: ref,
                  providerId: providerId,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 选择器内容
class _ModelPickerContent extends StatefulWidget {
  final WidgetRef ref;
  final String providerId;

  const _ModelPickerContent({
    required this.ref,
    required this.providerId,
  });

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
      hiddenModels:
          _availableModels.where((m) => !_selectedModels.contains(m)).toList(),
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
    final allSelected = filtered.isNotEmpty &&
        filtered.every((m) => _selectedModels.contains(m));

    final groupG2Radius = MoeRadii.borderMd.topLeft.x;
    final groupBorder = BorderSide(
      color: colors.border.withValues(alpha: 0.06),
      width: 0.6,
    );

    return Column(
      children: [
        // 搜索框
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: MoeTextField(
                  controller: _searchCtrl,
                  hint: '搜索模型...',
                  prefixIcon: Icons.search,
                  suffix: _searchCtrl.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, size: 20),
                          onPressed: () {
                            setState(() {
                              _searchCtrl.clear();
                              _searchQuery = '';
                            });
                          },
                        )
                      : null,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  onChanged: (value) {
                    setState(() {
                      _searchQuery = value.toLowerCase().trim();
                    });
                  },
                ),
              ),
              const SizedBox(width: 8),
              // 全选/取消全选按钮
              IconButton(
                icon: Icon(
                  allSelected ? Icons.deselect : Icons.select_all,
                  color: colors.primary,
                ),
                tooltip: allSelected ? '取消全选' : '全选',
                onPressed: allSelected ? _deselectAll : _selectAll,
              ),
            ],
          ),
        ),

        // 模型列表
        Expanded(
          child: _isLoading
              ? const Center(child: MoeLoadingIndicator())
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
                  : _availableModels.isEmpty
                      ? const MoeEmptyState(
                          icon: Icons.inbox_outlined,
                          title: '暂无可用模型',
                        )
                      : filtered.isEmpty
                          ? const MoeEmptyState(
                              icon: Icons.search_off,
                              title: '未找到匹配的模型',
                            )
                          : Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 16),
                              child: Container(
                                decoration: MoeG2Decoration(
                                  radius: groupG2Radius,
                                  color: colors.componentBackground,
                                  border: Border.fromBorderSide(groupBorder),
                                  boxShadow: MoeShadows.soft,
                                ),
                                child: MoeG2ClipRRect(
                                  radius: groupG2Radius,
                                  child: ListView.builder(
                                    padding:
                                        const EdgeInsets.symmetric(vertical: 4),
                                    itemCount: filtered.length,
                                    itemBuilder: (context, index) {
                                      final modelId = filtered[index];
                                      final isSelected =
                                          _selectedModels.contains(modelId);
                                      return MoeSettingsRow(
                                        icon: isSelected
                                            ? Icons.check_circle
                                            : Icons.circle_outlined,
                                        iconColor: isSelected
                                            ? colors.primary
                                            : colors.muted,
                                        label: modelId,
                                        trailingType:
                                            MoeSettingsRowTrailing.none,
                                        showDivider:
                                            index != filtered.length - 1,
                                        onTap: () => _toggleModel(modelId),
                                      );
                                    },
                                  ),
                                ),
                              ),
                            ),
        ),

        // 底部确认按钮 - 不需要响应键盘
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '已选择 ${_selectedModels.length} 个模型',
                  style: TextStyle(
                    color: colors.textSecondary,
                    fontSize: 14,
                  ),
                ),
              ),
              MoePrimaryButton(
                label: '确认导入',
                onPressed:
                    _selectedModels.isNotEmpty ? _confirmSelection : null,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
