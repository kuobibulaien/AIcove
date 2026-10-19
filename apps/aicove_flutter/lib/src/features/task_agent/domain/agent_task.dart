import '../../../core/models/message_block.dart';

/// `queued → running → (needs_input → running)* → done | failed | cancelled
/// | interrupted` (ADR0088 §5).
enum AgentTaskStatus {
  queued,
  running,
  needsInput,
  done,
  failed,
  cancelled,
  interrupted;

  String get dbName => this == needsInput ? 'needs_input' : name;

  static AgentTaskStatus parse(String value) => value == 'needs_input'
      ? needsInput
      : AgentTaskStatus.values.firstWhere(
          (status) => status.name == value,
          orElse: () => failed,
        );

  bool get isTerminal =>
      this == done || this == failed || this == cancelled || this == interrupted;

  TaskReceiptStatus? get receiptStatus => switch (this) {
    done => TaskReceiptStatus.done,
    failed => TaskReceiptStatus.failed,
    needsInput => TaskReceiptStatus.needsInput,
    cancelled => TaskReceiptStatus.cancelled,
    interrupted => TaskReceiptStatus.interrupted,
    _ => null,
  };
}

/// Where a task came from: the chat model's `delegate_task`, or a schedule.
enum AgentTaskSource { chat, schedule }

class AgentTask {
  const AgentTask({
    required this.id,
    required this.requestKey,
    required this.conversationId,
    required this.source,
    required this.instruction,
    required this.status,
    required this.frozen,
    required this.notify,
    required this.receiptSeq,
    required this.questionReceiptId,
    required this.pendingReceipt,
    required this.sideEffectUncertain,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;

  /// Host-built key of the request that created it; null for schedules.
  final String? requestKey;

  /// The chat the task belongs to; receipts are written there. A role is a
  /// conversation in this app, so this is also the role.
  final String conversationId;
  final AgentTaskSource source;
  final String instruction;
  final AgentTaskStatus status;

  /// Stopped by the kill switch; resumes only by hand.
  final bool frozen;
  final TaskReceiptNotify notify;
  final int receiptSeq;

  /// The `needs_input` receipt a reply must answer.
  final String? questionReceiptId;

  /// Receipt block JSON recorded with the state change but not yet written
  /// as a chat message (outbox).
  final String? pendingReceipt;
  final bool sideEffectUncertain;
  final DateTime createdAt;
  final DateTime updatedAt;
}
