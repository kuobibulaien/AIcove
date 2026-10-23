part of 'workspace_store.dart';

final _activeCommands = <String>{};
final _commandGroups = <String, _CommandGroup>{};

/// Concurrent commands of one run in one workspace (ADR0110): the first
/// takes the durable lease, the last to leave restores and scans once.
class _CommandGroup {
  _CommandGroup(this.key, this.runId) {
    ready.future.ignore();
  }
  final String key, runId;
  final ready = Completer<WorkspaceCommandLease>();
  int members = 1;
  bool unsettled = false;
}

/// Durable workspace-wide lease; metadata backup is outside the command cwd.
/// Each command holds its own lease object; a group's members share one id.
class WorkspaceCommandLease {
  WorkspaceCommandLease._(
    this.workspace,
    this.id,
    this.runId,
    this.backup,
    this.lock, [
    this._group,
  ]);
  WorkspaceCommandLease._member(
    WorkspaceCommandLease owner,
    _CommandGroup group,
  ) : this._(
        owner.workspace,
        owner.id,
        owner.runId,
        owner.backup,
        owner.lock,
        group,
      );
  final String workspace, id, runId;
  final Directory backup;
  final DesktopFileLock lock;
  final _CommandGroup? _group;
  bool _released = false, _left = false;

  /// True when this was the last command of its group still running.
  bool _leave({required bool settled}) {
    final group = _group;
    if (group == null) return true;
    if (_left) return false;
    _left = true;
    group.unsettled |= !settled;
    if (--group.members > 0) return false;
    if (identical(_commandGroups[group.key], group)) {
      _commandGroups.remove(group.key);
    }
    return true;
  }

  Future<void> _release() async {
    if (_released) return;
    _released = true;
    _activeCommands.remove(id);
    lock.close();
  }

  /// Releases ownership but retains the intent: recovery must finish it.
  /// Other running commands of the group keep the lease until they leave.
  Future<void> releaseForRecovery() async {
    if (_leave(settled: false)) await _release();
  }
}

class WorkspaceCommandScan {
  const WorkspaceCommandScan(this.changed, this.unindexed);
  final List<String> changed, unindexed;
}

extension WorkspaceCommands on WorkspaceStore {
  Future<void> _checkCommandLock(String workspace) async {
    if ((await index.rows('SELECT 1 FROM shell_intents WHERE ws=?', [
      workspace,
    ])).isNotEmpty) {
      throw const WorkspaceException.busy('空间里有命令正在运行，结束前不能写入，请稍后重试');
    }
  }

  /// Joins the run's running group, or takes a new lease (ADR0110).
  Future<WorkspaceCommandLease> beginCommand(
    String workspace,
    String runId,
  ) async {
    final key = '${root.path}\x00$workspace';
    final running = _commandGroups[key];
    if (running != null) {
      if (running.runId != runId) {
        throw const WorkspaceException.busy('空间里有别的任务的命令正在运行，请等它结束后再试');
      }
      running.members++;
      try {
        return WorkspaceCommandLease._member(
          await running.ready.future,
          running,
        );
      } on Object {
        running.members--;
        rethrow;
      }
    }
    final group = _commandGroups[key] = _CommandGroup(key, runId);
    try {
      final lease = await _takeCommandLease(workspace, runId, group);
      group.ready.complete(lease);
      return lease;
    } catch (error, stack) {
      if (identical(_commandGroups[key], group)) _commandGroups.remove(key);
      group.ready.completeError(error, stack);
      rethrow;
    }
  }

  Future<WorkspaceCommandLease> _takeCommandLease(
    String workspace,
    String runId,
    _CommandGroup group,
  ) async {
    WorkspaceStore._checkCommitGuard();
    await _requireWorkspace(workspace);
    await _checkAncestors(workspace, '.aicove/workspace.json');
    final id = _uuid.v4();
    final backup = Directory(p.join(root.path, '.shell', id));
    await backup.create(recursive: true);
    final lock = DesktopFileLock.tryOpen(p.join(backup.path, 'owner.lock'));
    if (lock == null) {
      throw const WorkspaceException.busy('Cannot acquire command lease');
    }
    final lease = WorkspaceCommandLease._(
      workspace,
      id,
      runId,
      backup,
      lock,
      group,
    );
    _activeCommands.add(id);
    var claimed = false;
    try {
      await index.immediate(() async {
        WorkspaceStore._checkCommitGuard();
        await _checkCommandLock(workspace);
        if ((await index.rows('SELECT 1 FROM claims WHERE ws=?', [
          workspace,
        ])).isNotEmpty) {
          throw const WorkspaceException.busy('空间里有文件正在写入，请稍后重试');
        }
        await index.run('INSERT INTO shell_intents VALUES (?,?,?,?)', [
          workspace,
          id,
          runId,
          'preparing',
        ]);
        claimed = true;
      });
      final host = p.join(directoryOf(workspace).path, '.aicove');
      final hostType = await FileSystemEntity.type(host, followLinks: false);
      if (hostType != FileSystemEntityType.directory &&
          hostType != FileSystemEntityType.notFound) {
        throw FileSystemException('Invalid host metadata directory', host);
      }
      await _copyCommandTree(host, p.join(backup.path, 'metadata'));
      final phase = hostType == FileSystemEntityType.notFound
          ? 'ready_absent'
          : 'ready';
      await index.immediate(
        () => index.run('UPDATE shell_intents SET phase=? WHERE id=?', [
          phase,
          id,
        ]),
      );
      return lease;
    } catch (_) {
      if (claimed) {
        await index.immediate(
          () => index.run('DELETE FROM shell_intents WHERE id=?', [id]),
        );
      }
      await lease._release();
      await backup.delete(recursive: true);
      rethrow;
    }
  }

  /// Idempotent: metadata first, then one atomic rescan/index/history update.
  /// Only the group's last command does it; the others return no changes.
  /// A failure retains the durable lease and backup, blocking other writes.
  Future<WorkspaceCommandScan> finishCommand(
    WorkspaceCommandLease lease,
  ) async {
    if (!lease._leave(settled: true)) {
      return const WorkspaceCommandScan([], []);
    }
    if (lease._group?.unsettled ?? false) {
      await lease._release();
      throw StateError(
        'Another command of this run did not settle; workspace remains locked for recovery',
      );
    }
    try {
      await _checkAncestors(lease.workspace, '_shell');
      final intent = (await index.fetch(
        'SELECT phase FROM shell_intents WHERE ws=? AND id=?',
        [lease.workspace, lease.id],
      )).single;
      final phase = intent.read<String>('phase');
      final snapshot = p.join(lease.backup.path, 'metadata');
      if (phase != 'ready_absent' &&
          (phase != 'ready' ||
              await FileSystemEntity.type(snapshot, followLinks: false) !=
                  FileSystemEntityType.directory)) {
        throw FileSystemException(
          'Complete metadata backup required for recovery',
          snapshot,
        );
      }
      final host = p.join(directoryOf(lease.workspace).path, '.aicove');
      await _removeCommandTree(host);
      await _copyCommandTree(p.join(lease.backup.path, 'metadata'), host);
      final scan = await _scanCommandFiles(lease.workspace);
      final changed = <String>[];
      await index.immediate(() async {
        final rows = await index.rows('SELECT * FROM files WHERE ws=?', [
          lease.workspace,
        ]);
        final previous = {
          for (final row in rows) row.read<String>('path'): row,
        };
        final seq = (await index.rows(
          'SELECT COALESCE(MAX(seq),0) AS n FROM ops WHERE ws=? AND run_id=?',
          [lease.workspace, lease.runId],
        )).single.read<int>('n');
        var sequence = seq;
        // Tombstones first: a case-only rename must end with the live row.
        final paths = {...previous.keys, ...scan.$1.keys}.toList()
          ..sort((a, b) {
            final aLive = scan.$1.containsKey(a),
                bLive = scan.$1.containsKey(b);
            return aLive == bLive
                ? a.compareTo(b)
                : aLive
                ? 1
                : -1;
          });
        for (final path in paths) {
          if (_mount(lease.workspace, path) != null) continue;
          final old = previous[path]?.read<String>('revision') ?? '';
          final next = scan.$1[path];
          final revision = next?.$1 ?? '';
          if (old == revision) continue;
          final op = WorkspaceOp(
            id: _uuid.v4(),
            workspaceId: lease.workspace,
            runId: lease.runId,
            seq: ++sequence,
            kind: revision.isEmpty
                ? WorkspaceOpKind.delete
                : WorkspaceOpKind.write,
            path: path,
            toPath: null,
            beforeHash: old,
            afterHash: revision,
            undoes: null,
            phase: 'done',
            createdAt: _now(),
          );
          await index.run('INSERT INTO ops VALUES (?,?,?,?,?,?,?,?,?,?,?,?)', [
            op.id,
            op.workspaceId,
            op.runId,
            op.seq,
            op.kind.name,
            op.path,
            null,
            old,
            revision,
            null,
            'done',
            op.createdAt.millisecondsSinceEpoch,
          ]);
          await index.run('INSERT INTO command_changes VALUES (?)', [op.id]);
          await _setRow(op, path, revision);
          changed.add(path);
        }
        await index.run('DELETE FROM shell_intents WHERE id=?', [lease.id]);
      });
      await lease._release();
      await lease.backup.delete(recursive: true);
      return WorkspaceCommandScan(changed, scan.$2);
    } catch (_) {
      await lease._release();
      rethrow;
    }
  }

  Future<void> recoverCommands() async {
    for (final row in await index.fetch(
      'SELECT * FROM shell_intents ORDER BY ws',
    )) {
      final id = row.read<String>('id');
      if (_activeCommands.contains(id)) continue;
      final backup = Directory(p.join(root.path, '.shell', id));
      final lock = DesktopFileLock.tryOpen(p.join(backup.path, 'owner.lock'));
      if (lock == null) {
        continue; // A command in another isolate/process still owns it.
      }
      final lease = WorkspaceCommandLease._(
        row.read<String>('ws'),
        id,
        row.read<String>('run_id'),
        backup,
        lock,
      );
      _activeCommands.add(id);
      if (row.read<String>('phase') == 'preparing') {
        // No command is launched until the complete snapshot is marked ready.
        await index.immediate(
          () => index.run('DELETE FROM shell_intents WHERE id=?', [id]),
        );
        await lease._release();
        await backup.delete(recursive: true);
      } else {
        await finishCommand(lease);
      }
    }
  }

  Future<(Map<String, (String, int, DateTime)>, List<String>)>
  _scanCommandFiles(String workspace) async {
    final found = <String, (String, int, DateTime)>{};
    final invalid = <String>[];
    final folds = <String, String>{};
    final base = directoryOf(workspace);
    Future<void> scan(Directory dir) async {
      await for (final entity in dir.list(followLinks: false)) {
        final relative = p
            .relative(entity.path, from: base.path)
            .split(p.separator)
            .join('/');
        if (_mount(workspace, relative) != null) continue;
        try {
          if (WorkspacePathRules.normalize(relative) != relative) {
            throw const FormatException('Noncanonical path');
          }
        } on Object {
          invalid.add(relative);
          continue;
        }
        final type = await FileSystemEntity.type(
          entity.path,
          followLinks: false,
        );
        if (type == FileSystemEntityType.directory) {
          await scan(Directory(entity.path));
        } else if (type == FileSystemEntityType.file) {
          final fold = WorkspacePathRules.fold(relative);
          if (folds.containsKey(fold)) {
            final other = folds[fold]!;
            invalid.addAll([other, relative]);
            found.remove(other);
            continue;
          }
          folds[fold] = relative;
          final file = File(entity.path);
          final stat = await file.stat();
          if ((stat.mode & 0xf000) != 0x8000) {
            invalid.add(relative);
            continue; // FIFO/devices must never block scanning.
          }
          // Same size AND mtime is not proof of same contents after a shell.
          final hash = (await sha256.bind(file.openRead()).first).toString();
          found[relative] = (hash, stat.size, stat.modified);
        } else {
          invalid.add(relative); // Never follow links out of the workspace.
        }
      }
    }

    await scan(base);
    return (found, invalid);
  }
}

Future<void> _removeCommandTree(String path) async {
  switch (await FileSystemEntity.type(path, followLinks: false)) {
    case FileSystemEntityType.directory:
      await Directory(path).delete(recursive: true);
    case FileSystemEntityType.link:
      await Link(path).delete();
    case FileSystemEntityType.file:
      await File(path).delete();
    case FileSystemEntityType.notFound:
      break;
    default:
      throw FileSystemException('Unsupported metadata entry', path);
  }
}

Future<void> _copyCommandTree(String source, String target) async {
  switch (await FileSystemEntity.type(source, followLinks: false)) {
    case FileSystemEntityType.directory:
      await Directory(target).create(recursive: true);
      await for (final child in Directory(source).list(followLinks: false)) {
        await _copyCommandTree(
          child.path,
          p.join(target, p.basename(child.path)),
        );
      }
    case FileSystemEntityType.file:
      await Directory(p.dirname(target)).create(recursive: true);
      await File(source).copy(target);
    case FileSystemEntityType.link:
      await Directory(p.dirname(target)).create(recursive: true);
      await Link(target).create(await Link(source).target());
    case FileSystemEntityType.notFound:
      break;
    default:
      throw FileSystemException('Unsupported metadata entry', source);
  }
}
