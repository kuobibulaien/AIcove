/// TTS Provider 工厂
///
/// 根据渠道标识获取对应的 TtsVoiceProvider 实现
///
/// 2026-01-31: 创建 TTS Provider 工厂
library;

import 'tts_voice_provider.dart';
import 'siliconflow_voice_provider.dart';
import 'aliyun_voice_provider.dart';
import 'minimax_voice_provider.dart';

String _normalizeRoutingValue(String? value) {
  return value?.trim().toLowerCase() ?? '';
}

class TtsProviderResolution {
  final TtsVoiceProvider? voiceProvider;
  final String requestFormat;
  final String? matchedBy;

  const TtsProviderResolution({
    required this.voiceProvider,
    required this.requestFormat,
    this.matchedBy,
  });
}

/// TTS Provider 工厂
class TtsProviderFactory {
  /// 所有已注册的 Provider
  static final Map<String, TtsVoiceProvider> _providers = {
    'siliconflow': SiliconFlowVoiceProvider(),
    'aliyun_qwen': AliyunQwenVoiceProvider(),
    'aliyun_cosyvoice': AliyunCosyVoiceProvider(),
    'minimax': MinimaxVoiceProvider(),
  };

  /// 根据渠道标识获取 Provider
  ///
  /// [providerId] 渠道标识，如 'siliconflow'、'aliyun_qwen'、'minimax'
  /// 返回对应的 Provider 实例，如果不存在则返回 null
  static TtsVoiceProvider? getProvider(String providerId) {
    final normalized = _normalizeRoutingValue(providerId);
    if (normalized.isEmpty) return null;
    for (final provider in _providers.values) {
      if (provider.matchesProviderId(normalized)) {
        return provider;
      }
    }
    return null;
  }

  static String _normalizeRequestFormat(String? requestFormat) {
    final normalized = _normalizeRoutingValue(requestFormat);
    return normalized.isEmpty ? 'openai_tts' : normalized;
  }

  static TtsProviderResolution resolve({
    String? providerId,
    String? apiUrl,
    String? requestFormat,
  }) {
    final normalizedRequestFormat = _normalizeRequestFormat(requestFormat);

    if (normalizedRequestFormat != 'openai_tts') {
      for (final provider in _providers.values) {
        if (provider.matchesRequestFormat(normalizedRequestFormat)) {
          return TtsProviderResolution(
            voiceProvider: provider,
            requestFormat: normalizedRequestFormat,
            matchedBy: 'requestFormat',
          );
        }
      }
    }

    final normalizedProviderId = _normalizeRoutingValue(providerId);
    if (normalizedProviderId.isNotEmpty) {
      for (final provider in _providers.values) {
        if (provider.matchesProviderId(normalizedProviderId)) {
          return TtsProviderResolution(
            voiceProvider: provider,
            requestFormat: normalizedRequestFormat,
            matchedBy: 'providerId',
          );
        }
      }
    }

    final normalizedApiUrl = _normalizeRoutingValue(apiUrl);
    if (normalizedApiUrl.isNotEmpty) {
      for (final provider in _providers.values) {
        if (provider.matchesApiUrl(normalizedApiUrl)) {
          return TtsProviderResolution(
            voiceProvider: provider,
            requestFormat: normalizedRequestFormat,
            matchedBy: 'apiUrl',
          );
        }
      }
    }

    return TtsProviderResolution(
      voiceProvider: null,
      requestFormat: normalizedRequestFormat,
    );
  }

  /// 根据 API URL 自动识别渠道并获取 Provider
  ///
  /// [apiUrl] API 基础 URL
  /// [requestFormat] 可选，请求格式标识
  static TtsVoiceProvider? getProviderByUrl(
    String apiUrl, {
    String? requestFormat,
    String? providerId,
  }) {
    return resolve(
      providerId: providerId,
      apiUrl: apiUrl,
      requestFormat: requestFormat,
    ).voiceProvider;
  }

  /// 获取所有可用的 Provider 列表
  static List<TtsVoiceProvider> getAllProviders() {
    return _providers.values.toList();
  }

  /// 获取所有 Provider 的信息（用于 UI 展示）
  static List<ProviderInfo> getProviderInfoList() {
    return _providers.values.map((p) {
      return ProviderInfo(
        id: p.providerId,
        name: p.displayName,
        capabilities: p.capabilities,
      );
    }).toList();
  }

  /// 注册自定义 Provider
  ///
  /// 允许在运行时注册新的 Provider（用于插件扩展）
  static void registerProvider(TtsVoiceProvider provider) {
    _providers[provider.providerId.toLowerCase()] = provider;
  }

  /// 移除 Provider
  static void unregisterProvider(String providerId) {
    _providers.remove(providerId.toLowerCase());
  }
}

/// Provider 信息（用于 UI 展示）
class ProviderInfo {
  final String id;
  final String name;
  final TtsCapabilities capabilities;

  const ProviderInfo({
    required this.id,
    required this.name,
    required this.capabilities,
  });
}
