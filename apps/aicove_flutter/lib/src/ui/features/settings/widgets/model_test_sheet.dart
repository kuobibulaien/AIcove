/// ModelTestSheet - 模型连通性测试弹窗
///
/// 复用「选择模型」导入弹窗的壳与列表布局（搜索 + 可滚动列表 + 底部状态栏）。
/// 测活按小批量并发执行：点单行重测该模型，「全部测试」并发探测当前列表。
///
/// 更新记录：
/// - 2026-09-15: 创建模型测活弹窗，替换详情页内联不可滚动版本
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/settings/app_settings.dart';
import '../../../../features/settings/provider_detail/provider_detail_actions.dart';
import '../../../theme/moe_interaction_theme.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/widgets/index.dart';

/// Uses the shared picker shell; results live inline per row.
Future<void> showModelTestSheet(
  BuildContext context,
  WidgetRef ref, {
  required ProviderAuth provider,
  required String apiKey,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: false,
    constraints: const BoxConstraints(maxWidth: 640),
    builder: (context) =>
        _ModelTestContent(ref: ref, provider: provider, apiKey: apiKey),
  );
}

/// 测活内容
class _ModelTestContent extends StatefulWidget {
  final WidgetRef ref;
  final ProviderAuth provider;
  final String apiKey;

  const _ModelTestContent({
    required this.ref,
    required this.provider,
    required this.apiKey,
  });

  @override
  State<_ModelTestContent> createState() => _ModelTestContentState();
}

class _ModelTestContentState extends State<_ModelTestContent> {
  /// 同时探测的模型数上限，避免大列表一次性打满供应商限流
  static const int _maxConcurrentTests = 6;

  final _searchCtrl = TextEditingController();
  String _searchQuery = '';

  /// null=空闲；queued=排队中；loading=探测中；success/failure=已出结果
  final _states = <String, _ModelTestState>{};
  final _queue = <String>[];
  var _running = 0;

  late final Map<String, String> _displayNames;
  late final List<String> _models;

  ProviderDetailActions get _actions =>
      widget.ref.read(providerDetailActionsProvider);

  @override
  void initState() {
    super.initState();
    _displayNames =
        widget.ref.read(appSettingsProvider).value?.modelDisplayNames ??
            const {};
    // 与模型 Tab 一致，按显示名排序
    _models = List.of(widget.provider.visibleModels)
      ..sort((a, b) => _sortName(a).compareTo(_sortName(b)));
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  String _sortName(String modelId) {
    final name = _displayNames[modelId] ?? '';
    return (name.isEmpty ? modelId : name).toLowerCase();
  }

  List<String> get _filteredModels {
    if (_searchQuery.isEmpty) return _models;
    return _models.where((m) {
      final name = _displayNames[m] ?? '';
      return m.toLowerCase().contains(_searchQuery) ||
          name.toLowerCase().contains(_searchQuery);
    }).toList();
  }

  void _enqueue(Iterable<String> modelIds) {
    setState(() {
      for (final modelId in modelIds) {
        final state = _states[modelId];
        if (state == _ModelTestState.queued ||
            state == _ModelTestState.loading) {
          continue;
        }
        _queue.add(modelId);
        _states[modelId] = _ModelTestState.queued;
      }
    });
    _pump();
  }

  void _pump() {
    while (_running < _maxConcurrentTests && _queue.isNotEmpty) {
      final modelId = _queue.removeAt(0);
      _running++;
      setState(() => _states[modelId] = _ModelTestState.loading);
      unawaited(
        _runTest(modelId).whenComplete(() {
          _running--;
          if (mounted) _pump();
        }),
      );
    }
  }

  Future<void> _runTest(String modelId) async {
    try {
      await _actions.testModel(
        provider: widget.provider,
        apiKey: widget.apiKey,
        modelId: modelId,
      );
      if (mounted) setState(() => _states[modelId] = _ModelTestState.success);
    } catch (_) {
      if (mounted) setState(() => _states[modelId] = _ModelTestState.failure);
    }
  }

  void _testAll() {
    HapticFeedback.lightImpact();
    _enqueue(_filteredModels);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final filtered = _filteredModels;
    final success =
        _states.values.where((s) => s == _ModelTestState.success).length;
    final failure =
        _states.values.where((s) => s == _ModelTestState.failure).length;
    final allBusy = filtered.every(
      (m) =>
          _states[m] == _ModelTestState.queued ||
          _states[m] == _ModelTestState.loading,
    );

    return MoeBottomSheet(
      title: '测试模型',
      showCloseButton: true,
      titleTrailing: TextButton(
        style: withoutHoverFeedback(
          TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            minimumSize: const Size(44, 44),
          ),
        ),
        onPressed: filtered.isEmpty || allBusy ? null : _testAll,
        child: Text(
          '全部测试',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 15,
            color: colors.primary,
            fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily,
          ),
        ),
      ),
      footer: Text(
        '已测 ${success + failure}/${_models.length} · 成功 $success · 失败 $failure',
        textAlign: TextAlign.center,
        style: TextStyle(color: colors.textSecondary, fontSize: 13),
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
          if (filtered.isEmpty)
            const SliverToBoxAdapter(
              child: MoeEmptyState(
                icon: Icons.search_off,
                title: '未找到匹配的模型',
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate((context, index) {
                  final modelId = filtered[index];
                  final displayName = _displayNames[modelId] ?? '';
                  return MoeSettingsRow(
                    label: displayName.isNotEmpty ? displayName : modelId,
                    subtitle: displayName.isNotEmpty ? modelId : null,
                    trailingType: MoeSettingsRowTrailing.custom,
                    trailing: _buildStateIcon(_states[modelId], colors),
                    showDivider: index < filtered.length - 1,
                    onTap: () => _enqueue([modelId]),
                  );
                }, childCount: filtered.length),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildStateIcon(_ModelTestState? state, MoeColors colors) {
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
        return const Icon(
          Icons.check_circle,
          size: 20,
          color: Color(0xFF4CAF50),
        );
      case _ModelTestState.failure:
        return const Icon(Icons.cancel, size: 20, color: Color(0xFFE53935));
    }
  }
}

/// 模型测试状态
enum _ModelTestState { queued, loading, success, failure }
