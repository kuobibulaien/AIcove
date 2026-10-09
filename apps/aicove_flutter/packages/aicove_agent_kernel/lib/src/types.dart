/// Opaque provider message. The kernel never inspects provider-specific
/// structure (OpenAI, Claude blocks, Gemini parts); stages own the format.
typedef KernelMessage = Map<String, dynamic>;

class KernelToolCall {
  const KernelToolCall({
    required this.id,
    required this.name,
    this.arguments = const {},
    this.rawArguments,
    this.origin,
  });

  final String id;
  final String name;
  final Map<String, dynamic> arguments;
  final String? rawArguments;

  /// The provider-side call object, passed through untouched so fields the
  /// kernel does not model (e.g. thought signatures) survive the round trip.
  final Object? origin;
}

class KernelToolResult {
  const KernelToolResult({
    required this.callId,
    required this.name,
    required this.content,
    this.isError = false,
    this.payload,
  });

  final String callId;
  final String name;
  final String content;
  final bool isError;

  /// Stage-owned extra data (e.g. collected media), passed through untouched.
  final Object? payload;
}

/// One assistant response for a round, after unpacking.
class AssistantTurn {
  const AssistantTurn({
    required this.text,
    this.toolCalls = const [],
    this.hiddenThoughtParts = const [],
    this.raw,
    this.presetConsumed = false,
  });

  final String text;
  final List<KernelToolCall> toolCalls;
  final List<Map<String, dynamic>> hiddenThoughtParts;

  /// Provider raw response, owned by the model port and continuation encoder.
  final Object? raw;

  /// True when a preset transport consumed part of this response; text tool
  /// fallback must then be skipped.
  final bool presetConsumed;

  AssistantTurn copyWith({
    String? text,
    List<KernelToolCall>? toolCalls,
    List<Map<String, dynamic>>? hiddenThoughtParts,
    Object? raw,
    bool clearRaw = false,
    bool? presetConsumed,
  }) {
    return AssistantTurn(
      text: text ?? this.text,
      toolCalls: toolCalls ?? this.toolCalls,
      hiddenThoughtParts: hiddenThoughtParts ?? this.hiddenThoughtParts,
      raw: clearRaw ? null : (raw ?? this.raw),
      presetConsumed: presetConsumed ?? this.presetConsumed,
    );
  }
}

class ResolvedToolCalls {
  const ResolvedToolCalls(this.calls, {this.usesFallback = false});

  final List<KernelToolCall> calls;

  /// True when calls were parsed from text instead of native tool calls.
  final bool usesFallback;

  bool get isEmpty => calls.isEmpty;
}

/// Messages for one request: [running] is the canonical, source-derived list
/// (compaction applies to it); [request] is what is actually sent.
class PreparedRound {
  const PreparedRound({required this.running, required this.request});

  final List<KernelMessage> running;
  final List<KernelMessage> request;
}

enum PrepareMode {
  /// Full preparation at the start of a round.
  initial,

  /// After a context overflow: forced compaction and re-render only.
  recovery,
}

enum BatchMode { serial, parallel }

class TurnVerdict {
  const TurnVerdict._(this.shouldContinue, this.reason);

  const TurnVerdict.proceed() : this._(true, null);

  const TurnVerdict.stop(String reason) : this._(false, reason);

  final bool shouldContinue;
  final String? reason;
}

enum LoopStatus {
  /// The model answered without tool calls.
  completed,

  /// A post-tool decision or the round limit ended the run.
  stopped,

  cancelled,
}

class AgentLoopResult {
  const AgentLoopResult({
    required this.status,
    required this.rounds,
    required this.runningMessages,
    required this.toolCalls,
    required this.toolResults,
    this.lastTurn,
    this.stopReason,
  });

  final LoopStatus status;
  final int rounds;
  final List<KernelMessage> runningMessages;
  final List<KernelToolCall> toolCalls;
  final List<KernelToolResult> toolResults;
  final AssistantTurn? lastTurn;
  final String? stopReason;
}

/// Thrown by a model port when the request exceeds the context window,
/// including the local post-transform budget check.
class KernelContextOverflow implements Exception {
  const KernelContextOverflow(this.message, {this.cause, this.causeStackTrace});

  final String message;

  /// The original error, rethrown by adapters when recovery is not possible.
  final Object? cause;
  final StackTrace? causeStackTrace;

  @override
  String toString() => 'KernelContextOverflow: $message';
}
