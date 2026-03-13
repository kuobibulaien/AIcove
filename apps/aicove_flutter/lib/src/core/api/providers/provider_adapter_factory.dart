/// Provider 适配器工厂
///
/// 职责：根据 provider 名称创建对应的适配器实例
/// 原则：KISS - 简单的工厂模式，无需过度设计
library;

import 'provider_adapter.dart';
import 'openai_adapter.dart';
import 'claude_adapter.dart';
import 'gemini_adapter.dart';

class ProviderAdapterFactory {
  static final _adapters = <String, ProviderAdapter>{
    'openai': OpenAIAdapter(),
    'claude': ClaudeAdapter(),
    'anthropic': ClaudeAdapter(),
    'gemini': GeminiAdapter(),
    'google': GeminiAdapter(),
  };

  static String? _normalizeRequestFormat(Map<String, dynamic>? customConfig) {
    final raw = customConfig?['requestFormat']?.toString().trim().toLowerCase();
    switch (raw) {
      case 'openai':
        return 'openai';
      case 'claude':
      case 'anthropic':
        return 'claude';
      case 'gemini':
      case 'google':
        return 'gemini';
      default:
        return null;
    }
  }

  /// 解析最终使用的适配器标识。
  ///
  /// 优先级：
  /// 1. customConfig.requestFormat
  /// 2. provider id
  static String resolveProvider(
    String provider, {
    Map<String, dynamic>? customConfig,
  }) {
    final fromConfig = _normalizeRequestFormat(customConfig);
    if (fromConfig != null) return fromConfig;

    final normalized = provider.toLowerCase().trim();
    if (normalized == 'anthropic') return 'claude';
    if (normalized == 'google') return 'gemini';
    return normalized;
  }

  /// 获取适配器，如果不存在则返回 OpenAI 适配器作为默认
  static ProviderAdapter getAdapter(
    String provider, {
    Map<String, dynamic>? customConfig,
  }) {
    final resolved = resolveProvider(provider, customConfig: customConfig);
    return _adapters[resolved] ?? OpenAIAdapter();
  }

  /// 判断是否为 OpenAI 兼容格式（大部分国内中转都兼容）
  static bool isOpenAICompatible(
    String provider, {
    Map<String, dynamic>? customConfig,
  }) {
    final resolved = resolveProvider(provider, customConfig: customConfig);
    return !_adapters.containsKey(resolved) || resolved == 'openai';
  }
}
