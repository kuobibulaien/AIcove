part of 'message_block.dart';

/// Outcome of an errand task as stored in the chat (ADR0088 §4). The text
/// content is the short event label the chat model reads; cards and the
/// request copy derive from these fields only, never from a local task table.
enum TaskReceiptStatus { done, failed, needsInput, cancelled, interrupted }

/// Whether a receipt is relayed to the user in persona. `needs_input` is
/// always relayed whatever this says.
enum TaskReceiptNotify { always, onFailure, never }

class TaskArtifact {
  const TaskArtifact({required this.workspaceId, required this.path});

  final String workspaceId;
  final String path;

  factory TaskArtifact.fromJson(Map<String, dynamic> json) => TaskArtifact(
    workspaceId: json['workspace'] as String,
    path: json['path'] as String,
  );

  Map<String, dynamic> toJson() => {'workspace': workspaceId, 'path': path};
}

/// Limits from the implementation plan §3.
abstract final class TaskReceiptLimits {
  static const summaryChars = 600;
  static const questionChars = 300;
  static const fieldBytes = 2048;
  static const artifacts = 20;
  static const blockBytes = 8192;
}

class TaskReceiptBlock extends TextBlock {
  TaskReceiptBlock._({
    super.id,
    required super.messageId,
    required this.receiptId,
    required this.taskId,
    required this.receiptStatus,
    required this.summary,
    required this.question,
    required this.artifacts,
    required this.executorDevice,
    required this.sideEffectUncertain,
    required this.notify,
    required this.truncated,
    super.status,
  }) : super(
         content: taskReceiptLabel(
           receiptStatus,
           taskId: taskId,
           summary: summary,
           question: question,
         ),
       );

  /// Applies every limit: fields first, then the whole block, shrinking
  /// artifacts, question and summary in that order.
  factory TaskReceiptBlock({
    String? id,
    required String messageId,
    required String receiptId,
    required String taskId,
    required TaskReceiptStatus receiptStatus,
    String summary = '',
    String? question,
    List<TaskArtifact> artifacts = const [],
    required String executorDevice,
    bool sideEffectUncertain = false,
    TaskReceiptNotify notify = TaskReceiptNotify.always,
  }) {
    var truncated = false;
    String cut(String text, int chars) {
      final result = _truncate(text.trim(), chars, TaskReceiptLimits.fieldBytes);
      if (result != text.trim()) truncated = true;
      return result;
    }

    var kept = artifacts;
    if (kept.length > TaskReceiptLimits.artifacts) {
      kept = kept.sublist(0, TaskReceiptLimits.artifacts);
      truncated = true;
    }
    var shortSummary = cut(summary, TaskReceiptLimits.summaryChars);
    var shortQuestion = question == null
        ? null
        : cut(question, TaskReceiptLimits.questionChars);
    TaskReceiptBlock build() => TaskReceiptBlock._(
      id: id,
      messageId: messageId,
      receiptId: receiptId,
      taskId: taskId,
      receiptStatus: receiptStatus,
      summary: shortSummary,
      question: shortQuestion,
      artifacts: kept,
      executorDevice: executorDevice,
      sideEffectUncertain: sideEffectUncertain,
      notify: notify,
      truncated: truncated,
    );

    var block = build();
    while (block.byteSize > TaskReceiptLimits.blockBytes) {
      truncated = true;
      if (kept.isNotEmpty) {
        kept = kept.sublist(0, kept.length ~/ 2);
      } else if ((shortQuestion?.length ?? 0) > 0) {
        shortQuestion = _truncate(
          shortQuestion!,
          shortQuestion.length ~/ 2,
          1 << 30,
        );
      } else if (shortSummary.isNotEmpty) {
        shortSummary = _truncate(shortSummary, shortSummary.length ~/ 2, 1 << 30);
      } else {
        break;
      }
      block = build();
    }
    return block;
  }

  static const version = 1;

  final String receiptId;
  final String taskId;
  final TaskReceiptStatus receiptStatus;
  final String summary;
  final String? question;
  final List<TaskArtifact> artifacts;
  final String executorDevice;

  /// Cancelled or interrupted after an outside request may have gone out.
  final bool sideEffectUncertain;
  final TaskReceiptNotify notify;

  /// A field or the block was shortened to fit its limit.
  final bool truncated;

  /// Whether this receipt is relayed to the user in persona.
  bool get relays => switch (receiptStatus) {
    TaskReceiptStatus.needsInput => true,
    _ => switch (notify) {
      TaskReceiptNotify.always => true,
      TaskReceiptNotify.never => false,
      TaskReceiptNotify.onFailure => receiptStatus != TaskReceiptStatus.done,
    },
  };

  int get byteSize => utf8.encode(jsonEncode(toJson())).length;

  static String _truncate(String text, int maxChars, int maxBytes) {
    var chars = text.characters;
    var cut = false;
    if (chars.length > maxChars) {
      chars = chars.take(maxChars);
      cut = true;
    }
    var result = chars.toString();
    while (utf8.encode(result).length > maxBytes - 3 && chars.isNotEmpty) {
      chars = chars.skipLast(1);
      result = chars.toString();
      cut = true;
    }
    return cut ? '$result…' : result;
  }

  factory TaskReceiptBlock.fromJson(Map<String, dynamic> json) {
    final record = Map<String, dynamic>.from(json['taskReceipt'] as Map);
    return TaskReceiptBlock._(
      id: json['id'] as String,
      messageId: json['messageId'] as String,
      receiptId: record['receipt_id'] as String,
      taskId: record['task_id'] as String,
      receiptStatus: _statusOf(record['status']),
      summary: record['summary'] as String? ?? '',
      question: record['question'] as String?,
      artifacts: [
        for (final item in record['artifacts'] as List? ?? const [])
          if (item is Map) TaskArtifact.fromJson(Map<String, dynamic>.from(item)),
      ],
      executorDevice: record['executor_device'] as String? ?? '',
      sideEffectUncertain: record['side_effect_uncertain'] == true,
      notify: switch (record['notify']) {
        'never' => TaskReceiptNotify.never,
        'on_failure' => TaskReceiptNotify.onFailure,
        _ => TaskReceiptNotify.always,
      },
      truncated: record['truncated'] == true,
      status: BlockStatus.values.firstWhere(
        (value) => value.name == json['status'],
        orElse: () => BlockStatus.success,
      ),
    );
  }

  static TaskReceiptStatus _statusOf(Object? value) => switch (value) {
    'done' => TaskReceiptStatus.done,
    'needs_input' => TaskReceiptStatus.needsInput,
    'cancelled' => TaskReceiptStatus.cancelled,
    'interrupted' => TaskReceiptStatus.interrupted,
    _ => TaskReceiptStatus.failed,
  };

  static String statusName(TaskReceiptStatus status) => switch (status) {
    TaskReceiptStatus.done => 'done',
    TaskReceiptStatus.failed => 'failed',
    TaskReceiptStatus.needsInput => 'needs_input',
    TaskReceiptStatus.cancelled => 'cancelled',
    TaskReceiptStatus.interrupted => 'interrupted',
  };

  @override
  Map<String, dynamic> toJson() => {
    ...super.toJson(),
    'taskReceipt': {
      'v': version,
      'receipt_id': receiptId,
      'task_id': taskId,
      'status': statusName(receiptStatus),
      'summary': summary,
      if (question != null) 'question': question,
      if (artifacts.isNotEmpty)
        'artifacts': [for (final item in artifacts) item.toJson()],
      'executor_device': executorDevice,
      if (sideEffectUncertain) 'side_effect_uncertain': true,
      'notify': switch (notify) {
        TaskReceiptNotify.always => 'always',
        TaskReceiptNotify.onFailure => 'on_failure',
        TaskReceiptNotify.never => 'never',
      },
      if (truncated) 'truncated': true,
    },
  };
}

/// The text the chat model and older clients read for a receipt.
String taskReceiptLabel(
  TaskReceiptStatus status, {
  required String taskId,
  required String summary,
  String? question,
}) {
  final head = switch (status) {
    TaskReceiptStatus.done => '[杂活回执：已完成]',
    TaskReceiptStatus.failed => '[杂活回执：失败]',
    TaskReceiptStatus.needsInput => '[杂活回执：需要用户回答]',
    TaskReceiptStatus.cancelled => '[杂活回执：已取消]',
    TaskReceiptStatus.interrupted => '[杂活回执：中断]',
  };
  return [
    '$head 任务 $taskId',
    if (summary.isNotEmpty) summary,
    if (question != null && question.isNotEmpty) '问题：$question',
  ].join('\n');
}

/// A receipt as one line of text for chat exports (ADR0088 §4): the label
/// only, no card fields, so an import never revives it as a live receipt.
String taskReceiptExportLine(String label) => label
    .split('\n')
    .map((line) => line.trim())
    .where((line) => line.isNotEmpty)
    .join(' ');

enum TaskControlKind { reply, cancel }

/// A `reply` or `cancel` of a task, stored before the tool returns so it
/// reaches the executing device even if the chat turn fails (ADR0088 §6).
/// Never shown and never part of the request copy.
class TaskControlBlock extends TextBlock {
  TaskControlBlock({
    super.id,
    required super.messageId,
    required this.controlId,
    required this.taskId,
    required this.kind,
    this.answersReceiptId,
    this.text = '',
    this.executable = true,
    super.status,
  }) : super(content: '');

  final String controlId;
  final String taskId;
  final TaskControlKind kind;

  /// For a reply: the `needs_input` receipt it answers.
  final String? answersReceiptId;
  final String text;

  /// False for controls that arrive through import or history edits; only
  /// controls created online may act.
  final bool executable;

  factory TaskControlBlock.fromJson(Map<String, dynamic> json) {
    final record = Map<String, dynamic>.from(json['taskControl'] as Map);
    return TaskControlBlock(
      id: json['id'] as String,
      messageId: json['messageId'] as String,
      controlId: record['control_id'] as String,
      taskId: record['task_id'] as String,
      kind: record['kind'] == 'cancel'
          ? TaskControlKind.cancel
          : TaskControlKind.reply,
      answersReceiptId: record['answers_receipt_id'] as String?,
      text: record['text'] as String? ?? '',
      executable: record['executable'] == true,
    );
  }

  /// A copy that can no longer act, for imports and history edits.
  TaskControlBlock inert() => TaskControlBlock(
    id: id,
    messageId: messageId,
    controlId: controlId,
    taskId: taskId,
    kind: kind,
    answersReceiptId: answersReceiptId,
    text: text,
    executable: false,
    status: status,
  );

  @override
  Map<String, dynamic> toJson() => {
    ...super.toJson(),
    'taskControl': {
      'v': 1,
      'control_id': controlId,
      'task_id': taskId,
      'kind': kind.name,
      if (answersReceiptId != null) 'answers_receipt_id': answersReceiptId,
      if (text.isNotEmpty) 'text': text,
      if (executable) 'executable': true,
    },
  };
}
