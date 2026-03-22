/// Provider 适配器工厂
///
/// 职责：根据 provider 名称创建对应的适配器实例
/// 原则：KISS - 简单的工厂模式，无需过度设计
library;

import 'provider_adapter.dart';
import 'openai_adapter.dart';
import 'claude_adapter.dart';
import 'gemini_adapter.dart';
import 'minimax_adapter.dart';
import 'minimax_compat.dart';
import 'zai_compat.dart';

class ProviderAdapterFactory {
  static final _adapters = <String, ProviderAdapter>{
    'openai': OpenAIAdapter(),
    'claude': ClaudeAdapter(),
    'anthropic': ClaudeAdapter(),
    'gemini': GeminiAdapter(),
    'google': GeminiAdapter(),
    'minimax': MiniMaxAdapter(),
  };

  static const Set<String> _requestLocalOnlyKeys = <String>{
    'requestFormat',
    'apiPath',
    'vertexExpress',
    'defaultImageModel',
    'tts_models',
    'multi_key_enabled',
    'multi_key_strategy',
    'multi_key_items',
    'multi_key_rr_index',
  };

  static String? _normalizeRequestFormat(Map<String, dynamic>? customConfig) {
    final raw = customConfig?['requestFormat']?.toString().trim().toLowerCase();
    switch (raw) {
      case 'openai':
      case 'zai':
      case 'z.ai':
      case 'glm':
      case 'zhipu':
        return 'openai';
      case 'minimax':
        return 'minimax';
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
    String? apiBaseUrl,
  }) {
    if (isMiniMaxNativeChatEndpoint(apiBaseUrl)) return 'minimax';

    final fromConfig = _normalizeRequestFormat(customConfig);
    if (fromConfig != null) return fromConfig;

    final normalized = provider.toLowerCase().trim();
    if (isZaiProvider(providerId: normalized, apiBaseUrl: apiBaseUrl)) {
      return 'openai';
    }
    if (normalized == 'anthropic') return 'claude';
    if (normalized == 'google') return 'gemini';
    return normalized;
  }

  /// 获取适配器，如果不存在则返回 OpenAI 适配器作为默认
  static ProviderAdapter getAdapter(
    String provider, {
    Map<String, dynamic>? customConfig,
    String? apiBaseUrl,
  }) {
    final resolved = resolveProvider(
      provider,
      customConfig: customConfig,
      apiBaseUrl: apiBaseUrl,
    );
    return _adapters[resolved] ?? OpenAIAdapter();
  }

  static Map<String, dynamic>? sanitizeRequestCustomConfig(
    Map<String, dynamic>? customConfig,
  ) {
    if (customConfig == null || customConfig.isEmpty) {
      return customConfig;
    }
    final sanitized = <String, dynamic>{};
    customConfig.forEach((key, value) {
      if (_requestLocalOnlyKeys.contains(key)) {
        return;
      }
      sanitized[key] = value;
    });
    return sanitized;
  }

  /// 判断是否为 OpenAI 兼容格式（大部分国内中转都兼容）
  static bool isOpenAICompatible(
    String provider, {
    Map<String, dynamic>? customConfig,
    String? apiBaseUrl,
  }) {
    final resolved = resolveProvider(
      provider,
      customConfig: customConfig,
      apiBaseUrl: apiBaseUrl,
    );
    return !_adapters.containsKey(resolved) ||
        resolved == 'openai' ||
        resolved == 'minimax';
  }
}
