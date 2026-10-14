/// A reversible change made by a `write` or `destructive` tool. [before] is
/// enough to restore the previous state; for deletions it is the backup.
class ReversibleChange {
  const ReversibleChange({
    required this.kind,
    required this.description,
    required this.before,
    required this.after,
  });

  /// Selects the host applier that knows how to write this kind back.
  final String kind;
  final String description;
  final Map<String, Object?> before;
  final Map<String, Object?> after;
}

class JournalEntry {
  const JournalEntry({
    required this.id,
    required this.toolName,
    required this.change,
    required this.createdAt,
    this.undoneAt,
  });

  final String id;
  final String toolName;
  final ReversibleChange change;
  final DateTime createdAt;
  final DateTime? undoneAt;
}

/// Local, unsynced log of agent changes (batch 2 decision). Implementations
/// record [ReversibleChange.before] before applying, and undo by writing it
/// back and logging the reverse change.
abstract interface class ChangeJournal {
  Future<JournalEntry> append(String toolName, ReversibleChange change);

  Future<List<JournalEntry>> recent({int limit = 50});

  Future<JournalEntry> undo(String entryId);
}
