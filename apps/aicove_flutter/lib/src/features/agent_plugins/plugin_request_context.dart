/// Read-only inputs available when a plugin builds its system prompt for one
/// request, after the request messages are known.
class PluginRequestContext {
  const PluginRequestContext({
    required this.userMessage,
    required this.supportsToolCalling,
    this.conversationId,
    this.hasInternalImageContext = false,
    this.readOnly = false,
  });

  final String userMessage;
  final bool supportsToolCalling;

  /// Request owner; plugins with per-role data fail closed without it.
  final String? conversationId;

  /// The request messages carry internal image context blocks.
  final bool hasInternalImageContext;

  /// A context preview: assemble only, start no background work and write
  /// nothing.
  final bool readOnly;
}
