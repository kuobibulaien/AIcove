import 'background_context_spec.dart';

class BackgroundAgentDefinition {
  final String id;
  final String name;
  final String objectivePrompt;
  final BackgroundContextSpec contextSpec;
  final List<String> allowedToolNames;
  final String? modelRef;
  final double? temperature;
  final int maxRounds;

  const BackgroundAgentDefinition({
    required this.id,
    required this.name,
    required this.objectivePrompt,
    this.contextSpec = const BackgroundContextSpec(),
    this.allowedToolNames = const <String>[],
    this.modelRef,
    this.temperature,
    this.maxRounds = 5,
  });

  BackgroundAgentDefinition copyWith({
    String? id,
    String? name,
    String? objectivePrompt,
    BackgroundContextSpec? contextSpec,
    List<String>? allowedToolNames,
    String? modelRef,
    bool clearModelRef = false,
    double? temperature,
    bool clearTemperature = false,
    int? maxRounds,
  }) {
    return BackgroundAgentDefinition(
      id: id ?? this.id,
      name: name ?? this.name,
      objectivePrompt: objectivePrompt ?? this.objectivePrompt,
      contextSpec: contextSpec ?? this.contextSpec,
      allowedToolNames: allowedToolNames ?? this.allowedToolNames,
      modelRef: clearModelRef ? null : (modelRef ?? this.modelRef),
      temperature:
          clearTemperature ? null : (temperature ?? this.temperature),
      maxRounds: maxRounds ?? this.maxRounds,
    );
  }
}
