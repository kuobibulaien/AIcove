import '../../agent_context/domain/agent_runtime_contracts.dart';

class BackgroundAgentDefinition {
  final String id;
  final String name;
  final String objectivePrompt;

  /// Context layers and the conversation window this agent reads.
  final ContextProfile contextProfile;
  final List<String> allowedToolNames;
  final String? modelRef;
  final double? temperature;

  const BackgroundAgentDefinition({
    required this.id,
    required this.name,
    required this.objectivePrompt,
    this.contextProfile = ContextProfile.backgroundAnalyzer,
    this.allowedToolNames = const <String>[],
    this.modelRef,
    this.temperature,
  });

  ConversationWindowSpec get conversationWindow =>
      contextProfile.conversationWindow;

  BackgroundAgentDefinition copyWith({
    String? id,
    String? name,
    String? objectivePrompt,
    ContextProfile? contextProfile,
    List<String>? allowedToolNames,
    String? modelRef,
    bool clearModelRef = false,
    double? temperature,
    bool clearTemperature = false,
  }) {
    return BackgroundAgentDefinition(
      id: id ?? this.id,
      name: name ?? this.name,
      objectivePrompt: objectivePrompt ?? this.objectivePrompt,
      contextProfile: contextProfile ?? this.contextProfile,
      allowedToolNames: allowedToolNames ?? this.allowedToolNames,
      modelRef: clearModelRef ? null : (modelRef ?? this.modelRef),
      temperature:
          clearTemperature ? null : (temperature ?? this.temperature),
    );
  }
}
