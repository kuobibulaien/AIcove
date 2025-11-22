import '../../core/api_client.dart';

/// API客户端：从后端获取提供商和模型信息
class ProviderApi {
  final ApiClient _api;
  ProviderApi([ApiClient? api]) : _api = api ?? ApiClient();

  /// 获取可用的提供商列表
  /// 返回: ["openai", "gemini", "doubao"]
  Future<List<String>> fetchProviders() async {
    final data = await _api.getJson('/api/providers');
    final providers = (data['providers'] as List?)?.cast<String>() ?? const <String>[];
    return providers;
  }

  /// 获取各提供商支持的模型列表
  /// 返回: {"openai": ["gpt-4o-mini"], "gemini": ["gemini-2.5-pro"], "doubao": ["doubao-seed-1-6-251015"]}
  Future<Map<String, List<String>>> fetchModels() async {
    final data = await _api.getJson('/api/models');
    final modelsData = (data['models'] as Map<String, dynamic>?) ?? const {};
    final models = <String, List<String>>{};
    modelsData.forEach((key, value) {
      models[key] = (value as List?)?.cast<String>() ?? const <String>[];
    });
    return models;
  }

  /// 实时获取各提供商支持的模型列表（调用后端转发到官方接口）
  Future<Map<String, List<String>>> fetchLiveModels() async {
    final data = await _api.getJson('/api/models?source=live');
    final modelsData = (data['models'] as Map<String, dynamic>?) ?? const {};
    final models = <String, List<String>>{};
    modelsData.forEach((key, value) {
      models[key] = (value as List?)?.cast<String>() ?? const <String>[];
    });
    return models;
  }

  /// 实时获取单个提供商的模型列表
  Future<List<String>> fetchProviderLiveModels(String provider) async {
    final data = await _api.getJson('/api/providers/$provider/models?source=live');
    return ((data['models'] as List?)?.cast<String>() ?? const <String>[]);
  }

  /// 兼容 OpenAI 的通用拉取：POST /api/models/compatible-list
  Future<List<String>> fetchCompatibleModels({required String apiBase, required String apiKey}) async {
    final data = await _api.postJson('/api/models/compatible-list', {
      'api_base': apiBase,
      'api_key': apiKey,
    });
    return ((data['models'] as List?)?.cast<String>() ?? const <String>[]);
  }
}
