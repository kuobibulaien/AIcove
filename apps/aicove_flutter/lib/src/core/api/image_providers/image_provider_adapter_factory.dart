library;

import 'image_provider_adapter.dart';
import 'comfyui_image_adapter.dart';
import 'comfyui_workflow.dart';
import 'openai_compatible_image_adapter.dart';

class ImageProviderAdapterFactory {
  static final ImageProviderAdapter _openAiCompatibleAdapter =
      OpenAICompatibleImageAdapter();

  static String resolveProvider(
    String provider, {
    Map<String, dynamic>? customConfig,
  }) {
    if (ComfyUIWorkflow.isProvider(provider, customConfig)) return 'comfyui';
    final requestFormat = customConfig?['requestFormat']
        ?.toString()
        .trim()
        .toLowerCase();
    if (requestFormat == 'novelai' || requestFormat == 'nai') {
      return 'novelai';
    }

    final normalized = provider.trim().toLowerCase();
    if (normalized == 'novelai' || normalized == 'nai') {
      return 'novelai';
    }

    return 'openai';
  }

  static ImageProviderAdapter getAdapter(
    String provider, {
    Map<String, dynamic>? customConfig,
  }) {
    final resolved = resolveProvider(provider, customConfig: customConfig);
    switch (resolved) {
      case 'comfyui':
        return const ComfyUIImageAdapter();
      case 'openai':
        return _openAiCompatibleAdapter;
      default:
        throw UnsupportedError('Unsupported image provider adapter: $resolved');
    }
  }
}
