import 'workspace_read_only_mount.dart';
import 'package:aicove_quickjs/process.dart' show DesktopFileLock;
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show QueryRow;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../../core/app_logger.dart';
import '../domain/workspace_errors.dart';
import '../domain/workspace_grants.dart';
import '../domain/workspace_models.dart';
import '../domain/workspace_path_rules.dart';
import 'workspace_index.dart';

export '../domain/workspace_grants.dart' show defaultWorkspaceId;

part 'workspace_shell_store.dart';

/// Run id of host-maintained writes (metadata); never listed or undone.
const hostRunId = 'host';

const _uuid = Uuid();

/// Local workspace store (ADR0087 §2–3): the registry, the conditional
/// commit coordinator every writer goes through, crash recovery and undo.
///
/// Each change takes three steps:
/// 1. one `BEGIN IMMEDIATE` transaction checks the revision, occupies the
///    paths, reserves quota, keeps the old content and records the intent;
/// 2. the file is written to a temp file and renamed (or deleted, moved);
/// 3. a second transaction updates the index, completes the intent and
///    releases the paths.
///
/// Intents left unfinished are resolved from the disk state when the store
/// opens, or when a write finds a path occupied by an intent older than
/// [staleAfter].
class WorkspaceStore {
  WorkspaceStore._(
    this.root,
    this.index,
    this.staleAfter,
    this._now,
    this.quotaBytes,
    this.historyBytes,
  );

  static Future<WorkspaceStore> open(
    Directory root, {
    Duration staleAfter = const Duration(seconds: 30),
    DateTime Function()? clock,
    int quotaBytes = WorkspaceLimits.quotaBytes,
    int historyBytes = WorkspaceLimits.historyBytes,
  }) async {
    await root.create(recursive: true);
    final index = WorkspaceIndex(File(p.join(root.path, '.index.sqlite')));
    final store = WorkspaceStore._(
      root,
      index,
      staleAfter,
      clock ?? DateTime.now,
      quotaBytes,
      historyBytes,
    );
    await index.fetch('SELECT 1');
    await store.recoverCommands();
    await store.recover();
    await store.prune();
    return store;
  }

  final Directory root;
  final WorkspaceIndex index;
  final Duration staleAfter;
  final DateTime Function() _now;
  final int quotaBytes;
  final int historyBytes;

  /// Test hooks between the three steps; an exception thrown here behaves
  /// like the process dying at that point.
  @visibleForTesting
  Future<void> Function(WorkspaceOp op)? afterIntent;
  @visibleForTesting
  Future<void> Function(WorkspaceOp op)? afterApply;

  final _mounts = <(String, String), WorkspaceReadOnlyMount>{};
  static const _commitGuardKey = #workspaceCommitGuard;

  /// Host invocations keep their cancellation guard across every async step,
  /// including nested file tools. Existing callers retain their old contract.
  static Future<T> guardCommits<T>(
    bool Function() active,
    Future<T> Function() body,
  ) {
    final outer = Zone.current[_commitGuardKey] as bool Function()?;
    return runZoned(
      body,
      zoneValues: {_commitGuardKey: () => active() && (outer?.call() ?? true)},
    );
  }

  static void _checkCommitGuard() {
    if (!((Zone.current[_commitGuardKey] as bool Function()?)?.call() ??
        true)) {
      throw const WorkspaceException(
        'cancelled',
        'Script invocation closed; write cancelled',
      );
    }
  }

  void registerReadOnlyMount(
    String workspaceId,
    String prefix,
    WorkspaceReadOnlyMount mount,
  ) {
    _mounts[(workspaceId, WorkspacePathRules.normalize(prefix))] = mount;
  }

  (String, WorkspaceReadOnlyMount)? _mount(String ws, String path) {
    for (final e in _mounts.entries) {
      if (e.key.$1 == ws &&
          (WorkspacePathRules.fold(path) == WorkspacePathRules.fold(e.key.$2) ||
              WorkspacePathRules.fold(
                path,
              ).startsWith('${WorkspacePathRules.fold(e.key.$2)}/'))) {
        return (e.key.$2, e.value);
      }
    }
    return null;
  }

  void checkWritablePath(String workspaceId, String path) {
    if (_mount(workspaceId, WorkspacePathRules.normalize(path)) != null) {
      throw const WorkspaceException.readOnly(stickerViewReadOnly);
    }
  }

  Future<void> close() => index.close();

  // ---------------------------------------------------------------------
  // Registry
  // ---------------------------------------------------------------------

  Directory directoryOf(String workspaceId) =>
      Directory(p.join(root.path, workspaceId));

  /// A real local source for package import, after the caller checks its grant.
  /// Virtual mounts, links and paths outside this workspace are never sources.
  Future<FileSystemEntity> packageImportSource(String workspaceId, String path) async {
    if (await get(workspaceId) == null) throw const WorkspaceException.notFound('工作区不存在');
    final normalized = WorkspacePathRules.normalizeDirectory(path);
    if (normalized.isNotEmpty && _mount(workspaceId, normalized) != null) {
      throw const WorkspaceException.invalidPath('只能从本地工作区目录导入');
    }
    await _checkAncestors(workspaceId, normalized.isEmpty ? '__source' : '$normalized/__source');
    final source = normalized.isEmpty ? directoryOf(workspaceId).path : _fileAt(workspaceId, normalized).path;
    final type = await FileSystemEntity.type(source, followLinks: false);
    if (type == FileSystemEntityType.directory) return Directory(source);
    if (type == FileSystemEntityType.file) return File(source);
    throw const WorkspaceException.invalidPath('安装来源必须是本地文件夹或 zip，不能是链接');
  }

  Future<List<WorkspaceInfo>> list() async => [
    for (final row in await index.fetch(
      'SELECT * FROM workspaces ORDER BY created_at, id',
    ))
      _infoOf(row),
  ];

  Future<WorkspaceInfo?> get(String id) async {
    final rows = await index.fetch('SELECT * FROM workspaces WHERE id=?', [id]);
    return rows.isEmpty ? null : _infoOf(rows.single);
  }

  /// Registers the built-in [defaultWorkspaceId] workspace if missing, so
  /// the device always has at least one (reserved for the tutorial Agent).
  Future<void> ensureDefault() async {
    if (await get(defaultWorkspaceId) != null) return;
    await create(name: 'AIcove', description: '默认空间', id: defaultWorkspaceId);
  }

  /// Creates an empty workspace with its host metadata file.
  Future<WorkspaceInfo> create({
    required String name,
    String description = '',
    String? id,
  }) async {
    _checkCommitGuard();
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw const WorkspaceException.invalidPath('空间名称不能为空');
    }
    if (trimmed.length > 50) {
      throw const WorkspaceException.limit('空间名称最多 50 个字符');
    }
    final info = WorkspaceInfo(
      id: id ?? _uuid.v4(),
      name: trimmed,
      description: description.trim(),
      createdAt: _now(),
    );
    final directory = directoryOf(info.id);
    if (!WorkspacePathRules.rootFits(
      directory.path,
      windows: Platform.isWindows,
    )) {
      throw WorkspaceException.limit(
        '本机应用数据目录过长（${directory.path.length} 个字符），'
        '放不下 ${WorkspacePathRules.maxPathUnits} 个字符的空间路径，无法新建',
      );
    }
    _checkCommitGuard();
    await directory.create(recursive: true);
    await index.immediate(() async {
      _checkCommitGuard();
      await index.run('INSERT INTO workspaces VALUES (?,?,?,?)', [
        info.id,
        info.name,
        info.description,
        info.createdAt.millisecondsSinceEpoch,
      ]);
      _checkCommitGuard();
    });
    await write(
      info.id,
      '${WorkspacePathRules.hostDirectory}/workspace.json',
      utf8.encode(const JsonEncoder.withIndent('  ').convert(info.toJson())),
      runId: hostRunId,
      allowHost: true,
    );
    return info;
  }

  static WorkspaceInfo _infoOf(QueryRow row) => WorkspaceInfo(
    id: row.read<String>('id'),
    name: row.read<String>('name'),
    description: row.read<String>('description'),
    createdAt: DateTime.fromMillisecondsSinceEpoch(row.read<int>('created_at')),
  );

  Future<void> _requireWorkspace(String id) async {
    if (await get(id) == null) {
      throw WorkspaceException.notFound('本机没有空间 $id');
    }
  }

  // ---------------------------------------------------------------------
  // Reads
  // ---------------------------------------------------------------------

  /// Live files of a workspace, by path.
  Future<List<WorkspaceFile>> files(String workspaceId) async {
    await _checkAncestors(workspaceId, '_files');
    final files = <WorkspaceFile>[];
    for (final row in await index.fetch(
      "SELECT * FROM files WHERE ws=? AND revision<>'' ORDER BY path",
      [workspaceId],
    )) {
      final path = row.read<String>('path');
      if (_mount(workspaceId, path) != null) continue;
      await _checkAncestors(workspaceId, path);
      files.add(_fileOf(row));
    }
    for (final entry in _mounts.entries) {
      if (entry.key.$1 != workspaceId) continue;
      for (final file in (await entry.value.files()).entries) {
        files.add(
          WorkspaceFile(
            path: '${entry.key.$2}/${file.key}',
            revision: file.value.revision,
            size: file.value.size,
            updatedAt: file.value.updatedAt,
          ),
        );
      }
    }
    return files;
  }

  Future<WorkspaceFile?> stat(String workspaceId, String path) async {
    final normalized = WorkspacePathRules.normalize(path);
    await _checkAncestors(workspaceId, normalized);
    if (_mount(workspaceId, normalized) != null) {
      try {
        final mount = _mount(workspaceId, normalized)!;
        if (normalized.length == mount.$1.length) return null;
        final file = (await mount.$2
            .files())[normalized.substring(mount.$1.length + 1)];
        if (file == null) return null;
        return WorkspaceFile(
          path: normalized,
          revision: file.revision,
          size: file.size,
          updatedAt: file.updatedAt,
        );
      } on WorkspaceException {
        return null;
      }
    }
    final rows = await index.fetch(
      "SELECT * FROM files WHERE ws=? AND path=? AND revision<>''",
      [workspaceId, normalized],
    );
    return rows.isEmpty ? null : _fileOf(rows.single);
  }

  /// Direct children of [directory] ('' = root), directories first.
  Future<List<WorkspaceEntry>> listDirectory(
    String workspaceId,
    String directory,
  ) async {
    final dir = WorkspacePathRules.normalizeDirectory(directory);
    await _checkAncestors(workspaceId, dir.isEmpty ? '_list' : '$dir/_list');
    final prefix = dir.isEmpty ? '' : '$dir/';
    final directories = <String>{};
    final entries = <WorkspaceEntry>[];
    for (final file in await files(workspaceId)) {
      if (!file.path.startsWith(prefix)) continue;
      final rest = file.path.substring(prefix.length);
      final slash = rest.indexOf('/');
      if (slash < 0) {
        entries.add(WorkspaceEntry.file(rest, file));
      } else {
        directories.add(rest.substring(0, slash));
      }
    }
    return [
      for (final name in directories.toList()..sort())
        WorkspaceEntry.directory(name),
      ...entries,
    ];
  }

  /// Content and revision read from disk.
  Future<(Uint8List, String)> read(String workspaceId, String path) async {
    await _requireWorkspace(workspaceId);
    final normalized = WorkspacePathRules.normalize(path);
    final mount = _mount(workspaceId, normalized);
    if (mount != null) {
      final read =
          WorkspacePathRules.fold(normalized) ==
              WorkspacePathRules.fold(mount.$1)
          ? null
          : (await mount.$2.files())[normalized.substring(mount.$1.length + 1)];
      if (read == null) throw WorkspaceException.notFound('文件不存在：$normalized');
      final bytes = await read.read();
      return (bytes, read.revision);
    }
    await _checkAncestors(workspaceId, normalized);
    final file = _fileAt(workspaceId, normalized);
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type != FileSystemEntityType.file) {
      throw WorkspaceException.notFound('文件不存在：$normalized');
    }
    // Commands may create files beyond the ordinary store write limit.
    // Full reads keep that same bound; readRange remains available for chunks.
    if (await file.length() > WorkspaceLimits.maxFileBytes) {
      throw const WorkspaceException.limit(
        '文件超过 ${WorkspaceLimits.maxFileBytes >> 20} MiB 上限',
      );
    }
    final bytes = await file.readAsBytes();
    return (bytes, _hash(bytes));
  }

  static WorkspaceFile _fileOf(QueryRow row) => WorkspaceFile(
    path: row.read<String>('path'),
    revision: row.read<String>('revision'),
    size: row.read<int>('size'),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(row.read<int>('updated_at')),
  );

  /// Bounded host byte reads avoid loading the rest of an ordinary file.
  Future<Uint8List> readRange(
    String workspaceId,
    String path, {
    required int offset,
    required int length,
  }) async {
    if (offset < 0 || length < 0) throw ArgumentError('Invalid byte range');
    await _requireWorkspace(workspaceId);
    final normalized = WorkspacePathRules.normalize(path);
    if (_mount(workspaceId, normalized) != null) {
      final (bytes, _) = await read(workspaceId, normalized);
      return Uint8List.sublistView(
        bytes,
        offset.clamp(0, bytes.length),
        (offset + length).clamp(0, bytes.length),
      );
    }
    await _checkAncestors(workspaceId, normalized);
    final file = _fileAt(workspaceId, normalized);
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw WorkspaceException.notFound('文件不存在：$normalized');
    }
    final handle = await file.open();
    try {
      await handle.setPosition(offset);
      return await handle.read(length);
    } finally {
      await handle.close();
    }
  }

  // ---------------------------------------------------------------------
  // Conditional commit
  // ---------------------------------------------------------------------

  /// Creates or overwrites a file. Overwriting needs the current
  /// [expectedRevision]; creating must not pass one.
  Future<WorkspaceFile> write(
    String workspaceId,
    String path,
    List<int> bytes, {
    String? expectedRevision,
    required String runId,
    String? undoes,
    bool allowHost = false,
  }) async {
    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    if (data.length > WorkspaceLimits.maxFileBytes) {
      throw const WorkspaceException.limit(
        '文件超过 ${WorkspaceLimits.maxFileBytes >> 20} MiB 上限',
      );
    }
    final op = await _commit(
      workspaceId: workspaceId,
      kind: WorkspaceOpKind.write,
      path: path,
      data: data,
      expectedRevision: expectedRevision,
      runId: runId,
      undoes: undoes,
      allowHost: allowHost,
    );
    return WorkspaceFile(
      path: op.path,
      revision: op.afterHash,
      size: data.length,
      updatedAt: op.createdAt,
    );
  }

  Future<void> delete(
    String workspaceId,
    String path, {
    required String expectedRevision,
    required String runId,
    String? undoes,
  }) => _commit(
    workspaceId: workspaceId,
    kind: WorkspaceOpKind.delete,
    path: path,
    expectedRevision: expectedRevision,
    runId: runId,
    undoes: undoes,
  );

  /// Renames [from] to [to]; [to] must not exist.
  Future<void> move(
    String workspaceId,
    String from,
    String to, {
    required String expectedRevision,
    required String runId,
    String? undoes,
  }) => _commit(
    workspaceId: workspaceId,
    kind: WorkspaceOpKind.move,
    path: from,
    toPath: to,
    expectedRevision: expectedRevision,
    runId: runId,
    undoes: undoes,
  );

  Future<WorkspaceOp> _commit({
    required String workspaceId,
    required WorkspaceOpKind kind,
    required String path,
    String? toPath,
    Uint8List? data,
    String? expectedRevision,
    required String runId,
    String? undoes,
    bool allowHost = false,
  }) async {
    _checkCommitGuard();
    await _requireWorkspace(workspaceId);
    final source = WorkspacePathRules.normalize(path);
    final target = toPath == null ? null : WorkspacePathRules.normalize(toPath);
    if (_mount(workspaceId, source) != null ||
        (target != null && _mount(workspaceId, target) != null)) {
      throw const WorkspaceException.readOnly(stickerViewReadOnly);
    }
    if (!allowHost &&
        (WorkspacePathRules.isHostPath(source) ||
            (target != null && WorkspacePathRules.isHostPath(target)))) {
      throw const WorkspaceException.readOnly('.aicove/ 由应用维护，文件工具只能读取');
    }
    if (target != null &&
        WorkspacePathRules.fold(target) == WorkspacePathRules.fold(source)) {
      throw const WorkspaceException.invalidPath('移动的源路径与目标路径相同');
    }
    final op = await _intent(
      workspaceId: workspaceId,
      kind: kind,
      source: source,
      target: target,
      data: data,
      expectedRevision: expectedRevision,
      runId: runId,
      undoes: undoes,
    );
    await afterIntent?.call(op);
    try {
      await _apply(op, data);
    } catch (error) {
      await _resolve(op.id);
      rethrow;
    }
    await afterApply?.call(op);
    await index.immediate(() => _finish(op));
    return op;
  }

  /// Step 1. Retries once after resolving a stale intent that blocks it.
  Future<WorkspaceOp> _intent({
    required String workspaceId,
    required WorkspaceOpKind kind,
    required String source,
    required String? target,
    required Uint8List? data,
    required String? expectedRevision,
    required String runId,
    required String? undoes,
  }) async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await index.immediate(
          () => _intentInTransaction(
            workspaceId: workspaceId,
            kind: kind,
            source: source,
            target: target,
            data: data,
            expectedRevision: expectedRevision,
            runId: runId,
            undoes: undoes,
          ),
        );
      } on _StaleClaim catch (stale) {
        if (attempt > 0) {
          throw const WorkspaceException.busy('这个文件正在写入，请稍后重试');
        }
        await _resolve(stale.opId);
      }
    }
  }

  Future<WorkspaceOp> _intentInTransaction({
    required String workspaceId,
    required WorkspaceOpKind kind,
    required String source,
    required String? target,
    required Uint8List? data,
    required String? expectedRevision,
    required String runId,
    required String? undoes,
  }) async {
    _checkCommitGuard();
    await _checkCommandLock(workspaceId);
    final paths = [source, ?target];
    for (final path in paths) {
      final claim = await index.rows(
        'SELECT c.op_id, o.created_at FROM claims c '
        'LEFT JOIN ops o ON o.id=c.op_id WHERE c.ws=? AND c.fold=?',
        [workspaceId, WorkspacePathRules.fold(path)],
      );
      if (claim.isEmpty) continue;
      final createdAt = claim.single.readNullable<int>('created_at') ?? 0;
      final age = _now().millisecondsSinceEpoch - createdAt;
      if (age >= staleAfter.inMilliseconds) {
        throw _StaleClaim(claim.single.read<String>('op_id'));
      }
      throw const WorkspaceException.busy('这个文件正在写入，请稍后重试');
    }

    final before = await _diskHash(workspaceId, source);
    final after = switch (kind) {
      WorkspaceOpKind.write => _hash(data!),
      WorkspaceOpKind.delete => '',
      WorkspaceOpKind.move => before,
    };
    _checkRevision(kind, source, before, expectedRevision);
    if (target != null) {
      if (await _diskHash(workspaceId, target) != '') {
        throw WorkspaceException.invalidPath('目标已存在：$target');
      }
    }
    for (final path in [if (kind != WorkspaceOpKind.delete) target ?? source]) {
      await _checkLayout(workspaceId, path);
    }

    if (kind == WorkspaceOpKind.write) {
      final used = await _usedBytes(workspaceId);
      final oldSize = before.isEmpty
          ? 0
          : await _fileAt(workspaceId, source).length();
      if (used - oldSize + data!.length > quotaBytes) {
        throw WorkspaceException.limit('空间超过 ${_sizeText(quotaBytes)} 配额');
      }
    }
    if (before.isNotEmpty && kind != WorkspaceOpKind.move) {
      await _keepBlob(workspaceId, source, before);
    }

    final seqRows = await index.rows(
      'SELECT COALESCE(MAX(seq), 0) AS seq FROM ops WHERE run_id=? AND ws=?',
      [runId, workspaceId],
    );
    final op = WorkspaceOp(
      id: _uuid.v4(),
      workspaceId: workspaceId,
      runId: runId,
      seq: seqRows.single.read<int>('seq') + 1,
      kind: kind,
      path: source,
      toPath: target,
      beforeHash: before,
      afterHash: after,
      undoes: undoes,
      phase: 'pending',
      createdAt: _now(),
    );
    _checkCommitGuard();
    await index.run('INSERT INTO ops VALUES (?,?,?,?,?,?,?,?,?,?,?,?)', [
      op.id,
      op.workspaceId,
      op.runId,
      op.seq,
      op.kind.name,
      op.path,
      op.toPath,
      op.beforeHash,
      op.afterHash,
      op.undoes,
      op.phase,
      op.createdAt.millisecondsSinceEpoch,
    ]);
    for (final path in paths) {
      await index.run('INSERT INTO claims VALUES (?,?,?)', [
        workspaceId,
        WorkspacePathRules.fold(path),
        op.id,
      ]);
    }
    _checkCommitGuard();
    return op;
  }

  static void _checkRevision(
    WorkspaceOpKind kind,
    String path,
    String current,
    String? expected,
  ) {
    if (kind == WorkspaceOpKind.write && current.isEmpty) {
      if (expected != null && expected.isNotEmpty) {
        throw WorkspaceException.revisionMismatch('文件已不存在：$path');
      }
      return;
    }
    if (current.isEmpty) throw WorkspaceException.notFound('文件不存在：$path');
    if (expected == null || expected.isEmpty) {
      throw WorkspaceException.revisionMismatch(
        '$path 已存在，修改它需要带上读取时得到的 revision',
      );
    }
    if (expected != current) {
      throw WorkspaceException.revisionMismatch('$path 在读取之后被改过，请重新读取后再改');
    }
  }

  /// Rejects case-insensitive duplicates and file/directory clashes.
  Future<void> _checkLayout(String workspaceId, String path) async {
    final fold = WorkspacePathRules.fold(path);
    final clash = await index.rows(
      "SELECT path FROM files WHERE ws=? AND revision<>'' AND "
      '((fold=? AND path<>?) OR substr(fold, 1, ?)=? OR '
      'substr(?, 1, length(fold) + 1)=fold || \'/\')',
      [workspaceId, fold, path, fold.length + 1, '$fold/', fold],
    );
    if (clash.isNotEmpty) {
      throw WorkspaceException.invalidPath(
        '$path 与已有的 ${clash.first.read<String>('path')} 冲突'
        '（忽略大小写后重名，或文件与目录同名）',
      );
    }
  }

  Future<int> _usedBytes(String workspaceId) async {
    final rows = await index.rows(
      "SELECT COALESCE(SUM(size), 0) AS used FROM files "
      "WHERE ws=? AND revision<>''",
      [workspaceId],
    );
    return rows.single.read<int>('used');
  }

  /// Step 2.
  Future<void> _apply(WorkspaceOp op, Uint8List? data) async {
    _checkCommitGuard();
    final source = _fileAt(op.workspaceId, op.path);
    switch (op.kind) {
      case WorkspaceOpKind.write:
        final temp = File(p.join(root.path, '.tmp', op.id));
        await temp.parent.create(recursive: true);
        await temp.writeAsBytes(data!, flush: true);
        await source.parent.create(recursive: true);
        _checkCommitGuard();
        await temp.rename(source.path);
      case WorkspaceOpKind.delete:
        await source.delete();
        await _pruneEmptyParents(op.workspaceId, source.parent);
      case WorkspaceOpKind.move:
        final target = _fileAt(op.workspaceId, op.toPath!);
        await target.parent.create(recursive: true);
        _checkCommitGuard();
        await source.rename(target.path);
        await _pruneEmptyParents(op.workspaceId, source.parent);
    }
  }

  Future<void> _pruneEmptyParents(String workspaceId, Directory dir) async {
    final top = directoryOf(workspaceId).path;
    var current = dir;
    while (p.isWithin(top, current.path)) {
      try {
        if (!await current.list().isEmpty) return;
        await current.delete();
      } on FileSystemException {
        return;
      }
      current = current.parent;
    }
  }

  /// Step 3, inside a transaction. An intent resolved meanwhile by another
  /// writer's recovery is re-resolved from the disk.
  Future<void> _finish(WorkspaceOp op) async {
    final phase = await index.rows('SELECT phase FROM ops WHERE id=?', [op.id]);
    if (phase.isEmpty || phase.single.read<String>('phase') != 'pending') {
      await _markConflict(op);
      return;
    }
    switch (op.kind) {
      case WorkspaceOpKind.write:
        await _setRow(op, op.path, op.afterHash);
      case WorkspaceOpKind.delete:
        await _setRow(op, op.path, '');
      case WorkspaceOpKind.move:
        await _setRow(op, op.path, '');
        await _setRow(op, op.toPath!, op.afterHash);
    }
    await _close(op, 'done');
  }

  Future<void> _setRow(WorkspaceOp op, String path, String revision) async {
    final fold = WorkspacePathRules.fold(path);
    await index.run('DELETE FROM files WHERE ws=? AND fold=? AND path<>?', [
      op.workspaceId,
      fold,
      path,
    ]);
    final size = revision.isEmpty
        ? 0
        : await _fileAt(op.workspaceId, path).length();
    await index.run('INSERT OR REPLACE INTO files VALUES (?,?,?,?,?,?,?)', [
      op.workspaceId,
      path,
      fold,
      revision,
      size,
      op.id,
      _now().millisecondsSinceEpoch,
    ]);
    await index.run('INSERT OR IGNORE INTO sync_dirty VALUES (?,?)', [
      op.workspaceId,
      path,
    ]);
  }

  Future<void> _close(WorkspaceOp op, String phase) async {
    await index.run('UPDATE ops SET phase=? WHERE id=?', [phase, op.id]);
    await index.run('DELETE FROM claims WHERE op_id=?', [op.id]);
  }

  /// The index follows whatever the disk holds; the path is reported.
  Future<void> _markConflict(WorkspaceOp op) async {
    for (final path in op.paths) {
      await _setRow(op, path, await _diskHash(op.workspaceId, path));
    }
    await _close(op, 'conflict');
    AppLogger.warning(
      'Workspace',
      '修改中断后磁盘内容与记录都不一致，已按磁盘内容登记',
      metadata: {'workspace': op.workspaceId, 'op': op.id},
    );
  }

  // ---------------------------------------------------------------------
  // Recovery
  // ---------------------------------------------------------------------

  /// Resolves every unfinished intent older than [staleAfter].
  Future<void> recover() async {
    final cutoff = _now().subtract(staleAfter).millisecondsSinceEpoch;
    final rows = await index.fetch(
      "SELECT id FROM ops WHERE phase='pending' AND created_at<=? "
      'ORDER BY created_at',
      [cutoff],
    );
    for (final row in rows) {
      await _resolve(row.read<String>('id'));
    }
  }

  Future<void> _resolve(String opId) => index.immediate(() async {
    final rows = await index.rows('SELECT * FROM ops WHERE id=?', [opId]);
    if (rows.isEmpty) {
      await index.run('DELETE FROM claims WHERE op_id=?', [opId]);
      return;
    }
    final op = _opOf(rows.single);
    if (op.phase != 'pending') return;
    final source = await _diskHash(op.workspaceId, op.path);
    final target = op.toPath == null
        ? null
        : await _diskHash(op.workspaceId, op.toPath!);
    final (applied, untouched) = switch (op.kind) {
      WorkspaceOpKind.write => (
        source == op.afterHash,
        source == op.beforeHash,
      ),
      WorkspaceOpKind.delete => (source.isEmpty, source == op.beforeHash),
      WorkspaceOpKind.move => (
        source.isEmpty && target == op.afterHash,
        source == op.beforeHash && target == '',
      ),
    };
    if (applied) {
      await _finish(op);
    } else if (untouched) {
      await _close(op, 'void');
    } else {
      await _markConflict(op);
    }
  });

  // ---------------------------------------------------------------------
  // History and undo
  // ---------------------------------------------------------------------

  /// Runs that changed [workspaceId], newest first.
  Future<List<WorkspaceRunSummary>> runs(String workspaceId) async {
    final rows = await index.fetch(
      'SELECT o.run_id, COUNT(*) AS n, MIN(o.created_at) AS started, '
      "GROUP_CONCAT(o.path, char(10)) AS paths, "
      "GROUP_CONCAT(CASE WHEN c.op_id IS NOT NULL THEN o.path END, char(10)) AS command_paths, "
      "u.status FROM ops o LEFT JOIN command_changes c ON c.op_id=o.id "
      'LEFT JOIN undo_runs u ON u.run_id=o.run_id AND u.ws=o.ws '
      "WHERE o.ws=? AND o.phase='done' AND o.run_id<>? "
      'GROUP BY o.run_id ORDER BY started DESC',
      [workspaceId, hostRunId],
    );
    return [
      for (final row in rows)
        WorkspaceRunSummary(
          runId: row.read<String>('run_id'),
          opCount: row.read<int>('n'),
          paths: (row.read<String>('paths').split('\n').toSet().toList()
            ..sort()),
          startedAt: DateTime.fromMillisecondsSinceEpoch(
            row.read<int>('started'),
          ),
          undone:
              row.readNullable<String>('status') == 'done' &&
              row.readNullable<String>('command_paths') == null,
          commandPaths:
              (row
                        .readNullable<String>('command_paths')
                        ?.split('\n')
                        .toSet()
                        .toList() ??
                    [])
                ..sort(),
        ),
    ];
  }

  /// Undoes [runId]'s changes in [workspaceId] in reverse order (ADR0087
  /// §3). A path changed by anything after the run is left alone together
  /// with the run's earlier changes to it, and reported. Progress is kept,
  /// so calling again after a crash continues.
  Future<WorkspaceUndoResult> undoRun(String workspaceId, String runId) async {
    await index.immediate(() => _checkCommandLock(workspaceId));
    final commandRows = await index.fetch(
      'SELECT o.path FROM ops o JOIN command_changes c ON c.op_id=o.id '
      "WHERE o.ws=? AND o.run_id=? AND o.phase='done' ORDER BY o.seq",
      [workspaceId, runId],
    );
    final commandPaths = commandRows
        .map((r) => r.read<String>('path'))
        .toSet()
        .toList();
    final progress = await index.immediate(() async {
      final rows = await index.rows(
        'SELECT * FROM undo_runs WHERE run_id=? AND ws=?',
        [runId, workspaceId],
      );
      if (rows.isNotEmpty) return rows.single;
      await index.run('INSERT INTO undo_runs VALUES (?,?,?,?,?,?,?)', [
        runId,
        workspaceId,
        'undo:${_uuid.v4()}',
        'running',
        '[]',
        '[]',
        _now().millisecondsSinceEpoch,
      ]);
      return (await index.rows(
        'SELECT * FROM undo_runs WHERE run_id=? AND ws=?',
        [runId, workspaceId],
      )).single;
    });
    final undoRunId = progress.read<String>('undo_run_id');
    final skipped = {
      for (final path in jsonDecode(progress.read<String>('skipped')) as List)
        path as String,
    };
    final conflicts = [
      for (final path in jsonDecode(progress.read<String>('conflicts')) as List)
        path as String,
    ];
    if (progress.read<String>('status') == 'done') {
      return WorkspaceUndoResult(
        undone: await _undoneCount(undoRunId),
        conflicts: conflicts,
        commandChanges: commandPaths,
      );
    }

    final entries = [
      for (final row in await index.fetch(
        "SELECT * FROM ops WHERE run_id=? AND ws=? AND phase='done' "
        'ORDER BY seq DESC',
        [runId, workspaceId],
      ))
        _opOf(row),
    ];
    Future<void> save(String status) => index.immediate(
      () => index.run(
        'UPDATE undo_runs SET status=?, skipped=?, conflicts=? '
        'WHERE run_id=? AND ws=?',
        [
          status,
          jsonEncode(skipped.toList()),
          jsonEncode(conflicts),
          runId,
          workspaceId,
        ],
      ),
    );
    void skip(WorkspaceOp entry) {
      for (final path in entry.paths) {
        skipped.add(path);
        if (!conflicts.contains(path)) conflicts.add(path);
      }
    }

    final commandBlocked = <String>{};
    for (final entry in entries) {
      if ((await index.fetch('SELECT 1 FROM command_changes WHERE op_id=?', [
        entry.id,
      ])).isNotEmpty) {
        commandBlocked.addAll(entry.paths);
      }
      if (entry.paths.any(commandBlocked.contains)) {
        commandBlocked.addAll(entry.paths);
        skipped.addAll(entry.paths);
        await save('running');
        continue;
      }
      final reverted = await index.fetch(
        "SELECT 1 FROM ops WHERE undoes=? AND run_id=? AND phase='done'",
        [entry.id, undoRunId],
      );
      if (reverted.isNotEmpty) continue;
      if (entry.paths.any(skipped.contains) ||
          !await _undoable(entry, undoRunId)) {
        skip(entry);
        await save('running');
        continue;
      }
      try {
        await _revert(entry, undoRunId);
      } on WorkspaceException catch (error) {
        AppLogger.warning(
          'Workspace',
          '撤销一项修改失败，已跳过',
          metadata: {'op': entry.id, 'reason': error.code},
        );
        skip(entry);
      }
      await save('running');
    }
    await save('done');
    return WorkspaceUndoResult(
      undone: await _undoneCount(undoRunId),
      conflicts: conflicts,
      commandChanges: commandPaths,
    );
  }

  Future<int> _undoneCount(String undoRunId) async => (await index.fetch(
    "SELECT COUNT(*) AS n FROM ops WHERE run_id=? AND phase='done'",
    [undoRunId],
  )).single.read<int>('n');

  /// Every path of [entry] was last changed by [entry] itself, or by this
  /// undo reverting a later entry of the same run.
  Future<bool> _undoable(WorkspaceOp entry, String undoRunId) async {
    for (final path in entry.paths) {
      final rows = await index.fetch(
        'SELECT f.last_op, o.run_id, o.undoes, u.run_id AS undone_run, '
        'u.seq AS undone_seq FROM files f '
        'LEFT JOIN ops o ON o.id=f.last_op '
        'LEFT JOIN ops u ON u.id=o.undoes '
        'WHERE f.ws=? AND f.path=?',
        [entry.workspaceId, path],
      );
      if (rows.isEmpty) return false;
      final row = rows.single;
      if (row.read<String>('last_op') == entry.id) continue;
      final viaUndo =
          row.readNullable<String>('run_id') == undoRunId &&
          row.readNullable<String>('undone_run') == entry.runId &&
          (row.readNullable<int>('undone_seq') ?? 0) > entry.seq;
      if (!viaUndo) return false;
    }
    return true;
  }

  Future<void> _revert(WorkspaceOp entry, String undoRunId) async {
    switch (entry.kind) {
      case WorkspaceOpKind.write when entry.beforeHash.isEmpty:
        await delete(
          entry.workspaceId,
          entry.path,
          expectedRevision: entry.afterHash,
          runId: undoRunId,
          undoes: entry.id,
        );
      case WorkspaceOpKind.write || WorkspaceOpKind.delete:
        await write(
          entry.workspaceId,
          entry.path,
          await _blob(entry.beforeHash),
          expectedRevision: entry.afterHash.isEmpty ? null : entry.afterHash,
          runId: undoRunId,
          undoes: entry.id,
        );
      case WorkspaceOpKind.move:
        await move(
          entry.workspaceId,
          entry.toPath!,
          entry.path,
          expectedRevision: entry.afterHash,
          runId: undoRunId,
          undoes: entry.id,
        );
    }
  }

  /// Drops history older than 30 days, then the oldest history beyond
  /// 1 GiB, then content no remaining history refers to. Runs with an undo
  /// in progress keep their history.
  Future<void> prune() async {
    const protectedRuns =
        "SELECT run_id FROM undo_runs WHERE status='running' "
        "UNION SELECT undo_run_id FROM undo_runs WHERE status='running'";
    final cutoff = _now()
        .subtract(WorkspaceLimits.historyAge)
        .millisecondsSinceEpoch;
    await index.immediate(
      () => index.run(
        "DELETE FROM ops WHERE phase<>'pending' AND created_at<? "
        'AND run_id NOT IN ($protectedRuns)',
        [cutoff],
      ),
    );
    while (await _historyBytes() > historyBytes) {
      final oldest = await index.fetch(
        "SELECT run_id FROM ops WHERE phase<>'pending' "
        "AND before_hash<>'' AND run_id NOT IN ($protectedRuns) "
        'ORDER BY created_at LIMIT 1',
      );
      if (oldest.isEmpty) break;
      await index.immediate(
        () => index.run("DELETE FROM ops WHERE run_id=? AND phase<>'pending'", [
          oldest.single.read<String>('run_id'),
        ]),
      );
      await _dropUnreferencedBlobs();
    }
    await _dropUnreferencedBlobs();
  }

  Future<int> _historyBytes() async => (await index.fetch(
    'SELECT COALESCE(SUM(size), 0) AS n FROM blobs',
  )).single.read<int>('n');

  Future<void> _dropUnreferencedBlobs() async {
    final orphans = await index.immediate(() async {
      final rows = await index.rows(
        'SELECT hash FROM blobs WHERE hash NOT IN '
        '(SELECT before_hash FROM ops)',
      );
      final hashes = [for (final row in rows) row.read<String>('hash')];
      for (final hash in hashes) {
        await index.run('DELETE FROM blobs WHERE hash=?', [hash]);
      }
      return hashes;
    });
    for (final hash in orphans) {
      try {
        await _blobFile(hash).delete();
      } on FileSystemException {
        // Already gone.
      }
    }
  }

  /// Keeps the current content of [path] (hash [hash]) for undo.
  Future<void> _keepBlob(String workspaceId, String path, String hash) async {
    final known = await index.rows('SELECT 1 FROM blobs WHERE hash=?', [hash]);
    final file = _blobFile(hash);
    if (known.isNotEmpty && await file.exists()) return;
    final size = await _fileAt(workspaceId, path).length();
    if (await _historyBytesIn() + size > historyBytes) {
      throw const WorkspaceException.limit('修改历史已满，请先在空间页清理历史');
    }
    await file.parent.create(recursive: true);
    final temp = File(p.join(root.path, '.tmp', 'blob-$hash'));
    await temp.parent.create(recursive: true);
    await _fileAt(workspaceId, path).copy(temp.path);
    await temp.rename(file.path);
    await index.run('INSERT OR REPLACE INTO blobs VALUES (?,?,?)', [
      hash,
      size,
      _now().millisecondsSinceEpoch,
    ]);
  }

  Future<int> _historyBytesIn() async => (await index.rows(
    'SELECT COALESCE(SUM(size), 0) AS n FROM blobs',
  )).single.read<int>('n');

  Future<Uint8List> _blob(String hash) async {
    final file = _blobFile(hash);
    if (!await file.exists()) {
      throw const WorkspaceException.notFound('修改前的内容已被清理，无法撤销');
    }
    return file.readAsBytes();
  }

  File _blobFile(String hash) =>
      File(p.join(root.path, '.history', 'blobs', hash.substring(0, 2), hash));

  // ---------------------------------------------------------------------

  Future<void> _checkAncestors(String workspaceId, String path) async {
    var current = directoryOf(workspaceId).path;
    for (final part in [
      '',
      ...path.split('/').take(path.split('/').length - 1),
    ]) {
      if (part.isNotEmpty) current = p.join(current, part);
      if (await FileSystemEntity.type(current, followLinks: false) ==
          FileSystemEntityType.link) {
        throw WorkspaceException.invalidPath('$path 的祖先目录是符号链接');
      }
    }
  }

  File _fileAt(String workspaceId, String normalizedPath) => File(
    p.joinAll([directoryOf(workspaceId).path, ...normalizedPath.split('/')]),
  );

  /// SHA-256 of the file at [path], or '' when nothing is there. A
  /// directory or link in the way is a layout error.
  Future<String> _diskHash(String workspaceId, String path) async {
    await _checkAncestors(workspaceId, path);
    final file = _fileAt(workspaceId, path);
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    return switch (type) {
      FileSystemEntityType.notFound => '',
      FileSystemEntityType.file => _hash(await file.readAsBytes()),
      _ => throw WorkspaceException.invalidPath('$path 是目录或链接，不是文件'),
    };
  }

  static String _sizeText(int bytes) =>
      bytes >= 1 << 20 ? '${bytes >> 20} MiB' : '$bytes 字节';

  static String _hash(List<int> bytes) => sha256.convert(bytes).toString();

  static WorkspaceOp _opOf(QueryRow row) => WorkspaceOp(
    id: row.read<String>('id'),
    workspaceId: row.read<String>('ws'),
    runId: row.read<String>('run_id'),
    seq: row.read<int>('seq'),
    kind: WorkspaceOpKind.values.byName(row.read<String>('kind')),
    path: row.read<String>('path'),
    toPath: row.readNullable<String>('to_path'),
    beforeHash: row.read<String>('before_hash'),
    afterHash: row.read<String>('after_hash'),
    undoes: row.readNullable<String>('undoes'),
    phase: row.read<String>('phase'),
    createdAt: DateTime.fromMillisecondsSinceEpoch(row.read<int>('created_at')),
  );
}

class _StaleClaim implements Exception {
  const _StaleClaim(this.opId);
  final String opId;
}
