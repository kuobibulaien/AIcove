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

  /// 获取适配器，如果不存在则返回 OpenAI 适配器作为默认
  static ProviderAdapter getAdapter(String provider) {
    final normalized = provider.toLowerCase().trim();
    return _adapters[normalized] ?? OpenAIAdapter();
  }

  /// 判断是否为 OpenAI 兼容格式（大部分国内中转都兼容）
  static bool isOpenAICompatible(String provider) {
    final normalized = provider.toLowerCase().trim();
    return !_adapters.containsKey(normalized) || normalized == 'openai';
  }
}
