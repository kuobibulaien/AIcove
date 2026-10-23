import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// The errand agent's full process record for one task (ADR0088 §4): kept
/// only on the executing device, never in the chat context, never synced.
///
/// `<id>.json` is the checkpoint the next run continues from; `<id>.log`
/// appends every run's calls and results for the task card.
class TaskProcessRecord {
  TaskProcessRecord(this.directory);

  final Directory directory;

  File _checkpoint(String taskId) =>
      File(p.join(directory.path, '$taskId.json'));
  File _log(String taskId) => File(p.join(directory.path, '$taskId.log'));

  Future<TaskCheckpoint?> checkpoint(String taskId) async {
    final file = _checkpoint(taskId);
    if (!await file.exists()) return null;
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    return TaskCheckpoint(
      transcript: json['transcript'] as String,
      lastLog: json['last_log'] as String? ?? '',
      question: json['question'] as String?,
      messages: (json['messages'] as List?)
          ?.map((m) => Map<String, dynamic>.from(m as Map))
          .toList(),
    );
  }

  /// Written before the task's state moves on, through a temp file.
  Future<void> saveCheckpoint(String taskId, TaskCheckpoint checkpoint) async {
    await directory.create(recursive: true);
    final temp = File(p.join(directory.path, '$taskId.json.tmp'));
    await temp.writeAsString(
      jsonEncode({
        'transcript': checkpoint.transcript,
        'last_log': checkpoint.lastLog,
        if (checkpoint.question != null) 'question': checkpoint.question,
        if (checkpoint.messages != null) 'messages': checkpoint.messages,
      }),
      flush: true,
    );
    await temp.rename(_checkpoint(taskId).path);
  }

  Future<void> appendLog(String taskId, String heading, String text) async {
    await directory.create(recursive: true);
    await _log(taskId).writeAsString(
      '## $heading\n$text\n\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  /// Null on other devices: they only have the receipts.
  Future<String?> log(String taskId) async {
    final file = _log(taskId);
    return await file.exists() ? file.readAsString() : null;
  }
}

class TaskCheckpoint {
  const TaskCheckpoint({
    required this.transcript,
    this.lastLog = '',
    this.question,
    this.messages,
  });

  /// What the next run receives as its brief.
  final String transcript;

  /// The latest run's process, folded into [transcript] on reply.
  final String lastLog;

  /// The open question, while waiting for the user.
  final String? question;

  /// Full canonical execution transcript (assistant calls, tool results and user controls). Keeping
  /// these as separate messages lets the shared runtime compress old steps
  /// without treating the entire accumulated transcript as the latest input.
  final List<Map<String, dynamic>>? messages;

  /// Old checkpoints remain readable without a database or file migration.
  List<Map<String, dynamic>> get contextMessages =>
      messages ??
      [
        {'role': 'user', 'content': transcript},
        if (lastLog.isNotEmpty) {'role': 'assistant', 'content': lastLog},
      ];
}
