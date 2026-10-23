import 'dart:async';
import 'dart:convert';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart' show ToolEffect;

import '../../plugins/domain/handlers/ai_tool.dart';
import 'assistant_review.dart';

/// A set of the assistant's tools that rates and describes its own calls, so
/// a new area of the app plugs into the tool list, the review gate and the
/// approval card in one place.
abstract class AssistantToolGroup {
  List<AITool> tools();

  /// Risk of [toolName] with [args]; only called for this group's tools.
  AssistantRisk riskOf(String toolName, Map<String, dynamic> args);

  /// What the user sees when asked to approve the call; may look up the
  /// target so the card names it.
  FutureOr<ApprovalPrompt> describe(String toolName, Map<String, dynamic> args);

  late final Set<String> names = {for (final tool in tools()) tool.name};

  bool owns(String toolName) => names.contains(toolName);
}

extension AssistantToolGroups on List<AssistantToolGroup> {
  AssistantToolGroup? ownerOf(String toolName) {
    for (final group in this) {
      if (group.owns(toolName)) return group;
    }
    return null;
  }
}

/// One assistant tool with a JSON schema whose handler returns a JSON object.
AITool assistantTool(
  String name,
  String description,
  Map<String, Object> properties,
  List<String> required,
  ToolEffect effect,
  Future<Map<String, Object?>> Function(Map<String, dynamic> args) run,
) => AITool(
  name: name,
  description: description,
  parameters: const {},
  inputSchema: {
    'type': 'object',
    'properties': properties,
    'required': required,
  },
  effect: effect,
  handler: (args) async => jsonEncode(await run(args)),
);

/// The error shape every assistant tool returns.
Map<String, Object?> assistantToolError(String message) => {
  'error': 'invalid',
  'message': message,
};
