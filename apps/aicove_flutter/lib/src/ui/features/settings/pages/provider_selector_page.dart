import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../features/settings/provider_state.dart';
import '../../../../features/settings/app_settings.dart';

/// 提供商选择页面
class ProviderSelectorPage extends ConsumerWidget {
  const ProviderSelectorPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final providerInfoAsync = ref.watch(providerInfoProvider);
    final colors = context.moeColors;

    return MoePageScaffold(
      extendBodyBehindAppBar: true,
      appBar: MoeAppBar(
        title: '选择提供商和模型',
        showBackButton: true,
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
      backgroundColor: colors.surface,
      body: providerInfoAsync.when(
        loading: () =>
            const Center(child: MoeLoadingIndicator(message: '获取可用模型中...')),
        error: (e, _) => Center(
          child: MoeEmptyState(
            icon: Icons.error_outline,
            title: '加载失败',
            description: e.toString(),
            action: MoePrimaryButton(
              label: '重试',
              icon: Icons.refresh,
              onPressed: () {
                ref.read(providerInfoProvider.notifier).refresh();
              },
            ),
          ),
        ),
        data: (providerInfo) {
          if (providerInfo.providers.isEmpty) {
            return Center(
              child: MoeEmptyState(
                icon: Icons.cloud_off,
                title: '后端未配置任何提供商',
                description: '请在后端 .env 文件中配置相应的 API Key',
              ),
            );
          }

          return Builder(
            builder: (context) => ListView(
              padding: moeUnderBarPadding(
                context,
                EdgeInsets.symmetric(vertical: 8),
              ),
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: Text(
                    '从后端获取的可用提供商和模型',
                    style: TextStyle(color: colors.textSecondary, fontSize: 12),
                  ),
                ),
                ...providerInfo.providers.map((provider) {
                  final models = providerInfo.models[provider] ?? [];
                  return _ProviderCard(provider: provider, models: models);
                }),
                const SizedBox(height: 32),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _ProviderCard extends ConsumerWidget {
  final String provider;
  final List<String> models;

  const _ProviderCard({required this.provider, required this.models});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.moeColors;
    final settings = ref.watch(appSettingsProvider).value;
    final currentModel = settings?.defaultModelName ?? '';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: MoeG2ClipRRect(
        radius: 12,
        child: Container(
          decoration: MoeG2Decoration(
            radius: 12,
            color: colors.surfaceAlt,
            border: Border.all(color: colors.borderLight, width: borderWidth),
          ),
          child: Material(
            color: Colors.transparent,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Row(
                    children: [
                      Icon(
                        _getProviderIcon(provider),
                        color: colors.primary,
                        size: 24,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _getProviderDisplayName(provider),
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: MoeFontWeights.emphasis,
                          color: colors.text,
                        ),
                      ),
                    ],
                  ),
                ),
                if (models.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      '该提供商未配置模型',
                      style: TextStyle(color: colors.muted, fontSize: 13),
                    ),
                  )
                else
                  ...models.map((model) {
                    final canQualify =
                        settings?.providers.any((p) => p.id == provider) ??
                        false;
                    final modelRef = canQualify
                        ? settings!.buildModelRef(provider, model)
                        : model;
                    final isSelected =
                        modelRef == currentModel || model == currentModel;
                    return MoeListTile(
                      title: Text(
                        settings?.getModelDisplayName(modelRef) ?? model,
                        style: TextStyle(
                          color: isSelected ? colors.primary : colors.text,
                          fontWeight: isSelected
                              ? MoeFontWeights.emphasis
                              : MoeFontWeights.normal,
                        ),
                      ),
                      leading: Icon(
                        isSelected
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                        color: isSelected ? colors.primary : colors.muted,
                        size: 20,
                      ),
                      trailing: isSelected
                          ? Icon(Icons.check, color: colors.primary, size: 18)
                          : null,
                      selected: isSelected,
                      onTap: () {
                        ref
                            .read(appSettingsProvider.notifier)
                            .setDefaultModelName(modelRef);
                        final label =
                            settings?.getModelDisplayName(modelRef) ?? model;
                        MoeToast.success(context, '已设置默认模型为: $label');
                      },
                    );
                  }),
                const SizedBox(height: 8),
              ],
            ),
          ),
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
      case 'vertex':
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
      case 'vertex':
        return 'Google Gemini';
      case 'doubao':
        return '豆包 (Doubao)';
      default:
        return provider;
    }
  }
}
