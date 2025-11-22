class MemoryConfig {
  final bool enabled;
  
  // Summarization Model Config
  final String summarizeModel;
  final String summarizeBaseUrl;
  final String summarizeApiKey;
  final String summarizePrompt;
  
  // Embedding Model Config
  final String embeddingModel;
  final String embeddingBaseUrl;
  final String embeddingApiKey;
  
  // Trigger Config
  final int triggerInterval; // Number of messages before triggering summarization

  MemoryConfig({
    this.enabled = true,
    this.summarizeModel = 'gpt-4o-mini',
    this.summarizeBaseUrl = 'https://api.openai.com/v1',
    this.summarizeApiKey = '',
    this.summarizePrompt = 'Analyze the following conversation and extract key facts about the user (preferences, life events, plans). Ignore small talk. Output concise statements.',
    this.embeddingModel = 'text-embedding-3-small',
    this.embeddingBaseUrl = 'https://api.openai.com/v1',
    this.embeddingApiKey = '',
    this.triggerInterval = 10,
  });

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'summarizeModel': summarizeModel,
    'summarizeBaseUrl': summarizeBaseUrl,
    'summarizeApiKey': summarizeApiKey,
    'summarizePrompt': summarizePrompt,
    'embeddingModel': embeddingModel,
    'embeddingBaseUrl': embeddingBaseUrl,
    'embeddingApiKey': embeddingApiKey,
    'triggerInterval': triggerInterval,
  };

  factory MemoryConfig.fromJson(Map<String, dynamic> json) {
    return MemoryConfig(
      enabled: json['enabled'] as bool? ?? true,
      summarizeModel: json['summarizeModel'] as String? ?? 'gpt-4o-mini',
      summarizeBaseUrl: json['summarizeBaseUrl'] as String? ?? 'https://api.openai.com/v1',
      summarizeApiKey: json['summarizeApiKey'] as String? ?? '',
      summarizePrompt: json['summarizePrompt'] as String? ?? 'Analyze the following conversation and extract key facts about the user (preferences, life events, plans). Ignore small talk. Output concise statements.',
      embeddingModel: json['embeddingModel'] as String? ?? 'text-embedding-3-small',
      embeddingBaseUrl: json['embeddingBaseUrl'] as String? ?? 'https://api.openai.com/v1',
      embeddingApiKey: json['embeddingApiKey'] as String? ?? '',
      triggerInterval: json['triggerInterval'] as int? ?? 10,
    );
  }
}
