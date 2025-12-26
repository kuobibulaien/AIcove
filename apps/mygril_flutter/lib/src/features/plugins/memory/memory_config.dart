/// 记忆系统配置
/// 
/// 支持从用户导入的模型渠道中选择嵌入模型和摘要模型
/// 混合模式：主嵌入服务失败时，可降级到备用嵌入服务
class MemoryConfig {
  final bool enabled;
  
  // === 摘要模型配置 (引用用户导入的渠道) ===
  final String? summarizeProviderId;  // 渠道ID，如 "openai"、"deepseek"
  final String? summarizeModelName;   // 模型名，如 "gpt-4o-mini"
  final String summarizePrompt;
  
  // === 主嵌入模型配置 (引用用户导入的渠道) ===
  final String? embeddingProviderId;  // 渠道ID
  final String? embeddingModelName;   // 模型名，如 "text-embedding-3-small"
  
  // === 备用嵌入模型配置 (降级方案，也引用用户导入的渠道) ===
  final bool fallbackEmbeddingEnabled;      // 是否启用降级
  final String? fallbackEmbeddingProviderId; // 备用渠道ID
  final String? fallbackEmbeddingModelName;  // 备用模型名
  
  // === 触发配置 ===
  final int triggerInterval; // 每隔多少条消息触发一次摘要

  MemoryConfig({
    this.enabled = true,
    this.summarizeProviderId,
    this.summarizeModelName,
    this.summarizePrompt = 'Analyze the following conversation and extract key facts about the user (preferences, life events, plans). Ignore small talk. Output concise statements.',
    this.embeddingProviderId,
    this.embeddingModelName,
    this.fallbackEmbeddingEnabled = false,
    this.fallbackEmbeddingProviderId,
    this.fallbackEmbeddingModelName,
    this.triggerInterval = 10,
  });

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'summarizeProviderId': summarizeProviderId,
    'summarizeModelName': summarizeModelName,
    'summarizePrompt': summarizePrompt,
    'embeddingProviderId': embeddingProviderId,
    'embeddingModelName': embeddingModelName,
    'fallbackEmbeddingEnabled': fallbackEmbeddingEnabled,
    'fallbackEmbeddingProviderId': fallbackEmbeddingProviderId,
    'fallbackEmbeddingModelName': fallbackEmbeddingModelName,
    'triggerInterval': triggerInterval,
  };

  factory MemoryConfig.fromJson(Map<String, dynamic> json) {
    return MemoryConfig(
      enabled: json['enabled'] as bool? ?? true,
      summarizeProviderId: json['summarizeProviderId'] as String?,
      summarizeModelName: json['summarizeModelName'] as String?,
      summarizePrompt: json['summarizePrompt'] as String? ?? 'Analyze the following conversation and extract key facts about the user (preferences, life events, plans). Ignore small talk. Output concise statements.',
      embeddingProviderId: json['embeddingProviderId'] as String?,
      embeddingModelName: json['embeddingModelName'] as String?,
      fallbackEmbeddingEnabled: json['fallbackEmbeddingEnabled'] as bool? ?? false,
      fallbackEmbeddingProviderId: json['fallbackEmbeddingProviderId'] as String?,
      fallbackEmbeddingModelName: json['fallbackEmbeddingModelName'] as String?,
      triggerInterval: json['triggerInterval'] as int? ?? 10,
    );
  }

  /// 检查嵌入模型是否已配置
  bool get hasEmbeddingConfig => 
      embeddingProviderId != null && 
      embeddingProviderId!.isNotEmpty &&
      embeddingModelName != null && 
      embeddingModelName!.isNotEmpty;

  /// 检查摘要模型是否已配置
  bool get hasSummarizeConfig => 
      summarizeProviderId != null && 
      summarizeProviderId!.isNotEmpty &&
      summarizeModelName != null && 
      summarizeModelName!.isNotEmpty;
}
