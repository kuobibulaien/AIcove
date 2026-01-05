/// ModelListPage - 服务提供商管理页面
/// 
/// 显示和管理 AI 模型的服务提供商（渠道）。
/// 
/// 设计特点：
/// - 顶部 Tab 按模型类型分组筛选
/// - 渠道卡片自适应布局（单列/多列）
/// - 点击渠道卡片弹出底部操作菜单
/// - 搜索功能使用底部弹窗
/// 
/// 重构记录：
/// - 2025-12-31: 拆分为多个组件文件，主页面精简至约200行
///   - 提取 ProviderSectionCard 渠道卡片组件
///   - 提取 ModelRowTile 模型行组件
///   - 提取 ModelSearchSheet 搜索弹窗组件
///   - 提取 ProviderDialogs 对话框函数
///   - 使用 MoeFilterChipBar 筛选标签栏
///   - 使用 MoeEmptyState 空状态组件
///   - 使用 MoeLoadingIndicator 加载指示器
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../ui/theme/tokens.dart';
import '../../../../features/settings/app_settings.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../widgets/provider_section_card.dart';
import '../widgets/model_search_sheet.dart';
import 'import_model_dialog.dart';

class ModelListPage extends ConsumerStatefulWidget {
  const ModelListPage({super.key});

  @override
  ConsumerState<ModelListPage> createState() => _ModelListPageState();
}

class _ModelListPageState extends ConsumerState<ModelListPage> {
  String _selectedModelType = 'chat'; // 当前选中的模型类型

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(appSettingsProvider);
    final colors = context.moeColors;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: colors.surface,
        foregroundColor: colors.text,
        elevation: 0,
        title: Text('✨ 服务提供商管理', style: TextStyle(color: colors.text)),
        actions: [
          IconButton(
            tooltip: '搜索模型',
            icon: const Icon(Icons.search),
            onPressed: () => showModelSearchSheet(context, ref),
          ),
          IconButton(
            tooltip: '新增服务提供商',
            icon: const Icon(Icons.add_circle_outline),
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
        loading: () => const Center(child: MoeLoadingIndicator(message: '加载中...')),
        error: (e, _) => Center(
          child: MoeEmptyState(
            icon: Icons.error_outline,
            title: '加载失败',
            description: '$e',
          ),
        ),
        data: (settings) => _buildContent(settings, colors),
      ),
    );
  }

  /// 构建页面内容
  Widget _buildContent(AppSettings settings, MoeColors colors) {
    if (settings.providers.isEmpty) {
      return Center(
        child: MoeEmptyState(
          icon: Icons.cloud_off,
          title: '还没有配置任何渠道',
          description: '请先导入服务提供商',
          action: MoePrimaryButton(
            label: '新增渠道',
            icon: Icons.add,
            onPressed: () async {
              await showDialog(
                context: context,
                builder: (_) => const ImportModelDialog(),
              );
            },
          ),
        ),
      );
    }

    // 按模型类型分组
    final groupedProviders = <String, List<ProviderAuth>>{};
    for (final provider in settings.providers) {
      final type = provider.modelType;
      groupedProviders.putIfAbsent(type, () => []).add(provider);
    }

    // 获取所有模型类型
    final allTypes = ModelType.values
        .where((type) => groupedProviders.containsKey(type.value))
        .toList();

    // 如果当前选中的类型没有数据,切换到第一个有数据的类型
    if (!groupedProviders.containsKey(_selectedModelType) && allTypes.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        setState(() {
          _selectedModelType = allTypes.first.value;
        });
      });
    }

    return Column(
      children: [
        // Tab 分组导航
        MoeFilterChipBar<String>(
          items: ModelType.values.map((type) {
            final hasProviders = groupedProviders.containsKey(type.value);
            final count = groupedProviders[type.value]?.length ?? 0;
            return MoeFilterItem<String>(
              value: type.value,
              label: type.label,
              icon: type.icon,
              count: count > 0 ? count : null,
              enabled: hasProviders,
            );
          }).toList(),
          selectedValue: _selectedModelType,
          onSelected: (value) {
            setState(() {
              _selectedModelType = value;
            });
          },
        ),

        // 渠道列表
        Expanded(
          child: _buildProviderList(
            providers: groupedProviders[_selectedModelType] ?? [],
            displayNames: settings.modelDisplayNames,
            colors: colors,
          ),
        ),
      ],
    );
  }

  /// 构建渠道列表
  Widget _buildProviderList({
    required List<ProviderAuth> providers,
    required Map<String, String> displayNames,
    required MoeColors colors,
  }) {
    if (providers.isEmpty) {
      return Center(
        child: MoeEmptyState(
          icon: Icons.folder_off,
          title: '该类型暂无服务提供商',
        ),
      );
    }

    // 按名称排序
    providers.sort((a, b) =>
        providerTitle(a).toLowerCase().compareTo(providerTitle(b).toLowerCase()));

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        int crossAxisCount = 1;
        if (width > 1200) {
          crossAxisCount = 4;
        } else if (width > 900) {
          crossAxisCount = 3;
        } else if (width > 600) {
          crossAxisCount = 2;
        }

        if (crossAxisCount == 1) {
          // 单列列表
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: providers
                .map((provider) => ProviderSectionCard(
                      provider: provider,
                      displayNames: displayNames,
                    ))
                .toList(),
          );
        }

        // 多列瀑布流布局
        final columns = List.generate(crossAxisCount, (_) => <Widget>[]);
        for (var i = 0; i < providers.length; i++) {
          columns[i % crossAxisCount].add(
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: ProviderSectionCard(
                provider: providers[i],
                displayNames: displayNames,
              ),
            ),
          );
        }

        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: List.generate(crossAxisCount, (index) {
              return Expanded(
                child: Padding(
                  padding: EdgeInsets.only(
                    left: index == 0 ? 0 : 8,
                    right: index == crossAxisCount - 1 ? 0 : 8,
                  ),
                  child: Column(
                    children: columns[index],
                  ),
                ),
              );
            }),
          ),
        );
      },
    );
  }
}
