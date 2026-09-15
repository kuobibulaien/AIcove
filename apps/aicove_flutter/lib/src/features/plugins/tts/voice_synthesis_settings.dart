/// One complete voice preset's synthesis parameters. Credentials remain in
/// provider management; providerId references that exact configuration, not an
/// adapter type, display name or model vendor.
class VoiceSynthesisSettings {
  const VoiceSynthesisSettings({
    required this.providerId,
    required this.modelId,
    this.voiceId,
    this.speed = 1,
    this.maxCharsPerChunk = 20,
    this.voiceFrequency = 60,
    this.systemPromptTemplate,
  });

  final String providerId;
  final String modelId;
  final String? voiceId;
  final double speed;
  final int maxCharsPerChunk;
  final int voiceFrequency;
  final String? systemPromptTemplate;

  bool get hasValidParameters =>
      providerId.trim().isNotEmpty &&
      modelId.trim().isNotEmpty &&
      speed.isFinite &&
      speed >= 0.5 &&
      speed <= 2 &&
      maxCharsPerChunk > 0 &&
      voiceFrequency >= 0 &&
      voiceFrequency <= 100;

  Map<String, dynamic> toJson() => {
    'providerId': providerId,
    'modelId': modelId,
    'voiceId': voiceId,
    'speed': speed,
    'maxCharsPerChunk': maxCharsPerChunk,
    'voiceFrequency': voiceFrequency,
    if (systemPromptTemplate != null)
      'systemPromptTemplate': systemPromptTemplate,
  };

  factory VoiceSynthesisSettings.fromJson(Map<String, dynamic> json) =>
      VoiceSynthesisSettings(
        providerId: json['providerId'] as String? ?? '',
        modelId: json['modelId'] as String? ?? '',
        voiceId: json['voiceId'] as String?,
        speed: (json['speed'] as num?)?.toDouble() ?? 1,
        maxCharsPerChunk: json['maxCharsPerChunk'] as int? ?? 20,
        voiceFrequency: json['voiceFrequency'] as int? ?? 60,
        systemPromptTemplate: json['systemPromptTemplate'] as String?,
      );
}
