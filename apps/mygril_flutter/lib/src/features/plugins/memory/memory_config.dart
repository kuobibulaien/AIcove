class MemoryConfig {
  final bool enabled;

  // model config
  final String? summarizeProviderId;
  final String? summarizeModelName;
  final String summarizePrompt;
  final String? embeddingProviderId;
  final String? embeddingModelName;
  final bool fallbackEmbeddingEnabled;
  final String? fallbackEmbeddingProviderId;
  final String? fallbackEmbeddingModelName;

  // rollout flags
  final bool enableCategoryClassification;
  final bool enableHybridSearch;
  final bool enableFourLayer;
  final bool enableProfileLayer;
  final bool enableNextDayTrigger;
  final bool enableConversationIsolation;
  final bool enableMemoryMerge;
  final bool enableCapacityCompress;
  final bool enablePreFlush;
  final bool enableEmbeddingCache;

  // strategy config
  final int roundSplitThreshold;
  final int localMaxMemories;

  /// Deprecated: replaced by next-day trigger.
  @Deprecated('Use roundSplitThreshold + next-day trigger instead.')
  final int triggerInterval;

  const MemoryConfig({
    this.enabled = true,
    this.summarizeProviderId,
    this.summarizeModelName,
    this.summarizePrompt = '',
    this.embeddingProviderId,
    this.embeddingModelName,
    this.fallbackEmbeddingEnabled = false,
    this.fallbackEmbeddingProviderId,
    this.fallbackEmbeddingModelName,
    this.enableCategoryClassification = true,
    this.enableHybridSearch = true,
    this.enableFourLayer = true,
    this.enableProfileLayer = true,
    this.enableNextDayTrigger = true,
    this.enableConversationIsolation = true,
    this.enableMemoryMerge = true,
    this.enableCapacityCompress = true,
    this.enablePreFlush = true,
    this.enableEmbeddingCache = false,
    this.roundSplitThreshold = 20,
    this.localMaxMemories = 800,
    this.triggerInterval = 10,
  });

  MemoryConfig copyWith({
    bool? enabled,
    String? summarizeProviderId,
    String? summarizeModelName,
    String? summarizePrompt,
    String? embeddingProviderId,
    String? embeddingModelName,
    bool? fallbackEmbeddingEnabled,
    String? fallbackEmbeddingProviderId,
    String? fallbackEmbeddingModelName,
    bool? enableCategoryClassification,
    bool? enableHybridSearch,
    bool? enableFourLayer,
    bool? enableProfileLayer,
    bool? enableNextDayTrigger,
    bool? enableConversationIsolation,
    bool? enableMemoryMerge,
    bool? enableCapacityCompress,
    bool? enablePreFlush,
    bool? enableEmbeddingCache,
    int? roundSplitThreshold,
    int? localMaxMemories,
    int? triggerInterval,
  }) {
    return MemoryConfig(
      enabled: enabled ?? this.enabled,
      summarizeProviderId: summarizeProviderId ?? this.summarizeProviderId,
      summarizeModelName: summarizeModelName ?? this.summarizeModelName,
      summarizePrompt: summarizePrompt ?? this.summarizePrompt,
      embeddingProviderId: embeddingProviderId ?? this.embeddingProviderId,
      embeddingModelName: embeddingModelName ?? this.embeddingModelName,
      fallbackEmbeddingEnabled:
          fallbackEmbeddingEnabled ?? this.fallbackEmbeddingEnabled,
      fallbackEmbeddingProviderId:
          fallbackEmbeddingProviderId ?? this.fallbackEmbeddingProviderId,
      fallbackEmbeddingModelName:
          fallbackEmbeddingModelName ?? this.fallbackEmbeddingModelName,
      enableCategoryClassification:
          enableCategoryClassification ?? this.enableCategoryClassification,
      enableHybridSearch: enableHybridSearch ?? this.enableHybridSearch,
      enableFourLayer: enableFourLayer ?? this.enableFourLayer,
      enableProfileLayer: enableProfileLayer ?? this.enableProfileLayer,
      enableNextDayTrigger: enableNextDayTrigger ?? this.enableNextDayTrigger,
      enableConversationIsolation:
          enableConversationIsolation ?? this.enableConversationIsolation,
      enableMemoryMerge: enableMemoryMerge ?? this.enableMemoryMerge,
      enableCapacityCompress:
          enableCapacityCompress ?? this.enableCapacityCompress,
      enablePreFlush: enablePreFlush ?? this.enablePreFlush,
      enableEmbeddingCache: enableEmbeddingCache ?? this.enableEmbeddingCache,
      roundSplitThreshold: roundSplitThreshold ?? this.roundSplitThreshold,
      localMaxMemories: localMaxMemories ?? this.localMaxMemories,
      triggerInterval: triggerInterval ?? this.triggerInterval,
    );
  }

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
        'enableCategoryClassification': enableCategoryClassification,
        'enableHybridSearch': enableHybridSearch,
        'enableFourLayer': enableFourLayer,
        'enableProfileLayer': enableProfileLayer,
        'enableNextDayTrigger': enableNextDayTrigger,
        'enableConversationIsolation': enableConversationIsolation,
        'enableMemoryMerge': enableMemoryMerge,
        'enableCapacityCompress': enableCapacityCompress,
        'enablePreFlush': enablePreFlush,
        'enableEmbeddingCache': enableEmbeddingCache,
        'roundSplitThreshold': roundSplitThreshold,
        'localMaxMemories': localMaxMemories,
        'triggerInterval': triggerInterval,
      };

  factory MemoryConfig.fromJson(Map<String, dynamic> json) {
    return MemoryConfig(
      enabled: json['enabled'] as bool? ?? true,
      summarizeProviderId: json['summarizeProviderId'] as String?,
      summarizeModelName: json['summarizeModelName'] as String?,
      summarizePrompt: json['summarizePrompt'] as String? ?? '',
      embeddingProviderId: json['embeddingProviderId'] as String?,
      embeddingModelName: json['embeddingModelName'] as String?,
      fallbackEmbeddingEnabled:
          json['fallbackEmbeddingEnabled'] as bool? ?? false,
      fallbackEmbeddingProviderId:
          json['fallbackEmbeddingProviderId'] as String?,
      fallbackEmbeddingModelName: json['fallbackEmbeddingModelName'] as String?,
      enableCategoryClassification:
          json['enableCategoryClassification'] as bool? ?? true,
      enableHybridSearch: json['enableHybridSearch'] as bool? ?? true,
      enableFourLayer: json['enableFourLayer'] as bool? ?? true,
      enableProfileLayer: json['enableProfileLayer'] as bool? ?? true,
      enableNextDayTrigger: json['enableNextDayTrigger'] as bool? ?? true,
      enableConversationIsolation:
          json['enableConversationIsolation'] as bool? ?? true,
      enableMemoryMerge: json['enableMemoryMerge'] as bool? ?? true,
      enableCapacityCompress: json['enableCapacityCompress'] as bool? ?? true,
      enablePreFlush: json['enablePreFlush'] as bool? ?? true,
      enableEmbeddingCache: json['enableEmbeddingCache'] as bool? ?? false,
      roundSplitThreshold: json['roundSplitThreshold'] as int? ?? 20,
      localMaxMemories: json['localMaxMemories'] as int? ?? 800,
      triggerInterval: json['triggerInterval'] as int? ?? 10,
    );
  }

  bool get hasEmbeddingConfig =>
      embeddingProviderId != null &&
      embeddingProviderId!.isNotEmpty &&
      embeddingModelName != null &&
      embeddingModelName!.isNotEmpty;

  bool get hasSummarizeConfig =>
      summarizeProviderId != null &&
      summarizeProviderId!.isNotEmpty &&
      summarizeModelName != null &&
      summarizeModelName!.isNotEmpty;
}
