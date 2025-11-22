import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/tokens.dart';
import '../../../settings/provider_state.dart';
import '../../../settings/app_settings.dart';

/// 提供商选择页面
class ProviderSelectorPage extends ConsumerWidget {
  const ProviderSelectorPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final providerInfoAsync = ref.watch(providerInfoProvider);

    return Scaffold(
      appBar: AppBar(
        backgroundColor: moeSurface,
        foregroundColor: moeText,
        elevation: 0,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(borderWidth),
          child: Container(
            color: moeBorderLight,
            height: borderWidth,
          ),
        ),
        title: const Text('选择提供商和模型', style: TextStyle(fontWeight: FontWeight.w600, color: moeText)),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              ref.read(providerInfoProvider.notifier).refresh();
            },
            tooltip: '刷新',
          ),
        ],
      ),
      backgroundColor: moeSurface,
      body: providerInfoAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 16),
              Text('加载失败: $e', style: const TextStyle(color: moeTextSecondary)),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
                onPressed: () {
                  ref.read(providerInfoProvider.notifier).refresh();
                },
              ),
            ],
          ),
        ),
        data: (providerInfo) {
          if (providerInfo.providers.isEmpty) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.cloud_off, size: 48, color: moeMuted),
                  SizedBox(height: 16),
                  Text('后端未配置任何提供商', style: TextStyle(color: moeTextSecondary)),
                  SizedBox(height: 8),
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 32),
                    child: Text(
                      '请在后端 .env 文件中配置 API Key',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: moeMuted, fontSize: 12),
                    ),
                  ),
                ],
              ),
            );
          }

          return ListView(
            children: [
              const SizedBox(height: 8),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text(
                  '从后端获取的可用提供商和模型',
                  style: TextStyle(color: moeTextSecondary, fontSize: 12),
                ),
              ),
              ...providerInfo.providers.map((provider) {
                final models = providerInfo.models[provider] ?? [];
                return _ProviderCard(
                  provider: provider,
                  models: models,
                );
              }).toList(),
              const SizedBox(height: 16),
            ],
          );
        },
      ),
    );
  }
}

class _ProviderCard extends ConsumerWidget {
  final String provider;
  final List<String> models;

  const _ProviderCard({
    required this.provider,
    required this.models,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider).value;
    final currentModel = settings?.defaultModelName ?? '';

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: moeSurfaceAlt,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(_getProviderIcon(provider), color: moePrimary, size: 24),
                const SizedBox(width: 8),
                Text(
                  _getProviderDisplayName(provider),
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: moeText,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (models.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  '该提供商未配置模型',
                  style: TextStyle(color: moeMuted, fontSize: 12),
                ),
              )
            else
              ...models.map((model) {
                final isSelected = model == currentModel;
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    isSelected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                    color: isSelected ? moePrimary : moeMuted,
                  ),
                  title: Text(
                    model,
                    style: TextStyle(
                      color: isSelected ? moeText : moeTextSecondary,
                      fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                  onTap: () {
                    ref.read(appSettingsProvider.notifier).setDefaultModelName(model);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('已设置默认模型为: $model'),
                        duration: const Duration(seconds: 1),
                      ),
                    );
                  },
                );
              }).toList(),
          ],
        ),
      ),
    );
  }

  IconData _getProviderIcon(String provider) {
    switch (provider.toLowerCase()) {
      case 'openai':
        return Icons.psychology;
      case 'gemini':
        return Icons.auto_awesome;
      case 'doubao':
        return Icons.coffee;
      default:
        return Icons.cloud;
    }
  }

  String _getProviderDisplayName(String provider) {
    switch (provider.toLowerCase()) {
      case 'openai':
        return 'OpenAI';
      case 'gemini':
        return 'Google Gemini';
      case 'doubao':
        return '豆包 (Doubao)';
      default:
        return provider;
    }
  }
}
