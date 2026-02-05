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
    return _providers[providerId.toLowerCase()];
  }

  /// 根据 API URL 自动识别渠道并获取 Provider
  ///
  /// [apiUrl] API 基础 URL
  /// [requestFormat] 可选，请求格式标识
  static TtsVoiceProvider? getProviderByUrl(String apiUrl,
      {String? requestFormat}) {
    final url = apiUrl.toLowerCase();

    // 根据 requestFormat 判断
    if (requestFormat != null) {
      if (requestFormat == 'aliyun_qwen_tts') {
        return _providers['aliyun_qwen'];
      }
      if (requestFormat == 'aliyun_cosyvoice') {
        return _providers['aliyun_cosyvoice'];
      }
      if (requestFormat == 'siliconflow_indextts') {
        return _providers['siliconflow'];
      }
    }

    // 根据 URL 判断
    if (url.contains('siliconflow')) {
      return _providers['siliconflow'];
    }
    if (url.contains('dashscope') || url.contains('aliyuncs')) {
      // 默认使用 Qwen-TTS
      return _providers['aliyun_qwen'];
    }
    if (url.contains('minimax')) {
      return _providers['minimax'];
    }

    return null;
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
