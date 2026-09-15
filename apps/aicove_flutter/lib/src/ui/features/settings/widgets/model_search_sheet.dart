/// ModelSearchSheet - 模型搜索弹窗
///
/// 从 model_list_page.dart 提取，用于搜索模型。
///
/// 设计特点：
/// - 底部弹窗样式
/// - 实时搜索过滤
/// - 显示模型归属的渠道
/// - 支持切换可见性
///
/// 更新记录：
/// - 2025-12-31: 从 model_list_page.dart 提取
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/settings/app_settings.dart';
import '../../../../ui/shared/widgets/index.dart';

/// 显示模型搜索弹窗
Future<void> showModelSearchSheet(BuildContext context, WidgetRef ref) async {
  await showMoeBottomSheet(
    context: context,
    title: '搜索模型',
    showCloseButton: true,
    maxHeight: MediaQuery.sizeOf(context).height * 0.85,
    builder: (context) => _ModelSearchContent(ref: ref),
  );
}

/// 搜索弹窗内容
class _ModelSearchContent extends StatefulWidget {
  final WidgetRef ref;

  const _ModelSearchContent({required this.ref});

  @override
  State<_ModelSearchContent> createState() => _ModelSearchContentState();
}

class _ModelSearchContentState extends State<_ModelSearchContent> {
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

    return Column(
      children: [
        // 搜索框
        Padding(
          padding: const EdgeInsets.all(16),
          child: MoeSearchField(
            padding: EdgeInsets.zero,
            controller: _searchCtrl,
            hintText: '搜索模型ID或备注...',
            autofocus: true,
            onChanged: (value) {
              setState(() {
                _searchQuery = value.toLowerCase().trim();
              });
            },
          ),
        ),

        // 搜索结果
        Expanded(
          child: settingsAsync.when(
            loading: () => const Center(child: MoeLoadingIndicator()),
            error: (e, _) => MoeEmptyState(
              icon: Icons.error_outline,
              title: '加载失败',
              description: '$e',
            ),
            data: (settings) {
              final searchResults = _buildSearchResults(settings);
              if (searchResults.isEmpty) {
                return MoeEmptyState(
                  icon: Icons.search_off,
                  title: _searchQuery.isEmpty ? '请输入搜索关键词' : '未找到匹配的模型',
                );
              }
              return ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: searchResults.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final result = searchResults[index];
                  return _SearchResultRow(result: result, ref: widget.ref);
                },
              );
            },
          ),
        ),
      ],
    );
  }

  /// 构建搜索结果
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
          results.add(
            _ModelSearchResult(
              modelId: modelId,
              displayName: displayName,
              providerId: provider.id,
              providerName: provider.displayName ?? provider.id,
              isVisible: isVisible,
            ),
          );
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

/// 搜索结果数据类
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
class _SearchResultRow extends StatelessWidget {
  final _ModelSearchResult result;
  final WidgetRef ref;

  const _SearchResultRow({required this.result, required this.ref});

  @override
  Widget build(BuildContext context) {
    final notifier = ref.read(appSettingsProvider.notifier);

    return MoeSettingsRow(
      icon: Icons.model_training_outlined,
      label: result.modelId,
      subtitle: '${result.displayName ?? ""} · ${result.providerName}',
      trailingType: MoeSettingsRowTrailing.switchControl,
      switchValue: result.isVisible,
      onSwitchChanged: (value) {
        notifier.setModelVisibility(
          providerId: result.providerId,
          modelId: result.modelId,
          visible: value,
        );
      },
    );
  }
}
