import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'provider_api.dart';

/// 提供商信息数据类
class ProviderInfo {
  final List<String> providers;
  final Map<String, List<String>> models;
  final String? selectedProvider;

  const ProviderInfo({
    required this.providers,
    required this.models,
    this.selectedProvider,
  });

  ProviderInfo copyWith({
    List<String>? providers,
    Map<String, List<String>>? models,
    String? selectedProvider,
  }) {
    return ProviderInfo(
      providers: providers ?? this.providers,
      models: models ?? this.models,
      selectedProvider: selectedProvider ?? this.selectedProvider,
    );
  }
}

/// ProviderApi 实例提供者
final providerApiProvider = Provider((ref) => ProviderApi());

/// 提供商状态管理
class ProviderInfoNotifier extends AsyncNotifier<ProviderInfo> {
  @override
  Future<ProviderInfo> build() async {
    final api = ref.watch(providerApiProvider);
    try {
      final providers = await api.fetchProviders();
      final models = await api.fetchModels();
      return ProviderInfo(
        providers: providers,
        models: models,
        selectedProvider: providers.isNotEmpty ? providers.first : null,
      );
    } catch (e) {
      // 如果后端不可用，返回空数据
      return const ProviderInfo(
        providers: [],
        models: {},
        selectedProvider: null,
      );
    }
  }

  /// 刷新提供商和模型列表
  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(() => build());
  }

  /// 设置选中的提供商
  void selectProvider(String provider) {
    final current = state.value;
    if (current == null) return;
    state = AsyncValue.data(current.copyWith(selectedProvider: provider));
  }
}

final providerInfoProvider = AsyncNotifierProvider<ProviderInfoNotifier, ProviderInfo>(
  ProviderInfoNotifier.new,
);
