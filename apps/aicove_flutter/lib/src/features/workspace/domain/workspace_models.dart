/// Limits from plan §3 that W1 enforces.
abstract final class WorkspaceLimits {
  static const maxWriteBytes = 1 << 20;
  static const maxFileBytes = 32 << 20;
  static const maxReadBytes = 50 << 10;
  static const maxReadLines = 2000;
  static const maxGrepLineChars = 500;
  static const maxResults = 200;
  static const maxResultBytes = 64 << 10;
  static const quotaBytes = 512 << 20;
  static const historyBytes = 1 << 30;
  static const historyAge = Duration(days: 30);
}

class WorkspaceInfo {
  const WorkspaceInfo({
    required this.id,
    required this.name,
    required this.description,
    required this.createdAt,
  });

  final String id;
  final String name;
  final String description;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'description': description,
    'createdAt': createdAt.toUtc().toIso8601String(),
  };
}

/// One indexed file; [revision] is the content SHA-256.
class WorkspaceFile {
  const WorkspaceFile({
    required this.path,
    required this.revision,
    required this.size,
    required this.updatedAt,
  });

  final String path;
  final String revision;
  final int size;
  final DateTime updatedAt;
}

/// A directory entry for listing: files carry their index row.
class WorkspaceEntry {
  const WorkspaceEntry.directory(this.name) : file = null;
  const WorkspaceEntry.file(this.name, WorkspaceFile this.file);

  final String name;
  final WorkspaceFile? file;

  bool get isDirectory => file == null;
}

enum WorkspaceOpKind { write, delete, move }

/// One committed or pending change. [beforeHash] / [afterHash] are empty
/// when the path does not exist on that side.
class WorkspaceOp {
  const WorkspaceOp({
    required this.id,
    required this.workspaceId,
    required this.runId,
    required this.seq,
    required this.kind,
    required this.path,
    required this.toPath,
    required this.beforeHash,
    required this.afterHash,
    required this.undoes,
    required this.phase,
    required this.createdAt,
  });

  final String id;
  final String workspaceId;
  final String runId;
  final int seq;
  final WorkspaceOpKind kind;
  final String path;
  final String? toPath;
  final String beforeHash;
  final String afterHash;
  final String? undoes;
  final String phase;
  final DateTime createdAt;

  /// Paths whose last-op stamp this op set.
  List<String> get paths => [path, if (toPath != null) toPath!];
}

/// A run's changes in one workspace, newest first in listings.
class WorkspaceRunSummary {
  const WorkspaceRunSummary({
    required this.runId,
    required this.opCount,
    required this.paths,
    required this.startedAt,
    required this.undone,
    this.commandPaths = const [],
  });

  final String runId;
  final int opCount;
  final List<String> paths;
  final DateTime startedAt;

  /// An undo of this run has completed.
  final bool undone;
  final List<String> commandPaths;
}

class WorkspaceUndoResult {
  const WorkspaceUndoResult({
    required this.undone,
    required this.conflicts,
    this.commandChanges = const [],
  });

  final List<String> commandChanges;
  List<String> get commandMessages => [
    for (final path in commandChanges) '命令造成的改动不能撤销：$path',
  ];

  final int undone;

  /// Paths left alone because something changed them after the run.
  final List<String> conflicts;
}
