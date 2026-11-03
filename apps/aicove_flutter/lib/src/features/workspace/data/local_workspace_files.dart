import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import '../domain/workspace_errors.dart';
import '../domain/workspace_file_access.dart';
import '../domain/workspace_models.dart';
import 'gitignore_matcher.dart';
import 'workspace_store.dart';

/// Resolves the nearest existing ancestor, including aliases of missing files.
Future<String> canonicalLocalPath(String input) async {
  var path = p.absolute(input);
  final tail = <String>[];
  while (await FileSystemEntity.type(path, followLinks: false) ==
      FileSystemEntityType.notFound) {
    final parent = p.dirname(path);
    if (parent == path) break;
    tail.add(p.basename(path));
    path = parent;
  }
  final base = await File(path).resolveSymbolicLinks();
  return p.joinAll([base, ...tail.reversed]);
}

/// Native files have no managed quota, index, or undo history.
class LocalWorkspaceFiles implements WorkspaceFileAccess {
  LocalWorkspaceFiles(
    this.rootPath, {
    required this.protectedRoot,
    required this.beforeCommit,
  });
  @override
  final String rootPath;
  final String protectedRoot;
  final void Function() beforeCommit;
  static final _queues = <String, Future<void>>{};
  @override
  String? get workspaceId => null;
  @override
  bool get isLocal => true;
  String absolute(String path) =>
      p.isAbsolute(path) ? path : p.join(rootPath, path);
  @override
  void checkWritable(String path) {
    if (path.contains('\x00'))
      throw const WorkspaceException.invalidPath('路径包含 NUL');
  }

  Future<String> checked(String path) async {
    checkWritable(path);
    final resolved = await canonicalLocalPath(absolute(path));
    final managed = await canonicalLocalPath(protectedRoot);
    if (p.equals(resolved, managed) || p.isWithin(managed, resolved)) {
      throw const WorkspaceException.invalidPath('应用管理目录必须通过内部空间访问');
    }
    return resolved;
  }

  Future<File> _file(String path) async {
    final file = File(await checked(path));
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file ||
        (!Platform.isWindows && (stat.mode & 0xf000) != 0x8000)) {
      throw WorkspaceException.notFound('不是普通文件：$path');
    }
    return file;
  }

  @override
  Future<(Uint8List, String)> read(String path) async {
    final bytes = await (await _file(path)).readAsBytes();
    return (bytes, sha256.convert(bytes).toString());
  }

  @override
  Stream<List<int>> openRead(String path) async* {
    yield* (await _file(path)).openRead();
  }

  @override
  Future<Uint8List> readRange(
    String path, {
    required int offset,
    required int length,
  }) async {
    final handle = await (await _file(path)).open();
    try {
      await handle.setPosition(offset);
      return await handle.read(length);
    } finally {
      await handle.close();
    }
  }

  @override
  Future<String?> revision(String path) async {
    final resolved = await checked(path);
    if (await FileSystemEntity.type(resolved, followLinks: false) ==
        FileSystemEntityType.notFound)
      return null;
    return (await sha256.bind((await _file(path)).openRead()).first).toString();
  }

  @override
  Future<WorkspaceFile?> stat(String path) async {
    final resolved = await checked(path);
    final stat = await File(resolved).stat();
    if (stat.type != FileSystemEntityType.file) return null;
    return WorkspaceFile(
      path: path,
      revision: '',
      size: stat.size,
      updatedAt: stat.modified,
    );
  }

  Future<T> _locked<T>(List<String> paths, Future<T> Function() body) async {
    final keys = paths.toSet().toList()..sort();
    final previous = [
      for (final key in keys)
        if (_queues[key] != null) _queues[key]!,
    ];
    final done = Completer<void>();
    for (final key in keys) {
      _queues[key] = done.future;
    }
    try {
      await Future.wait(previous);
      return await body();
    } finally {
      done.complete();
      for (final key in keys) {
        if (identical(_queues[key], done.future)) _queues.remove(key);
      }
    }
  }

  void _beforeCommit() {
    WorkspaceStore.checkCommitAllowed();
    beforeCommit();
  }

  Future<void> _checkRevision(String path, String? expected) async {
    if (await revision(path) != expected) {
      throw const WorkspaceException.revisionMismatch('文件刚被改过，请重新读取');
    }
  }

  @override
  Future<WorkspaceFile> write(
    String path,
    List<int> bytes, {
    String? expectedRevision,
  }) async {
    final resolved = await checked(path);
    return _locked([resolved], () async {
      await _checkRevision(resolved, expectedRevision);
      final target = File(resolved);
      _beforeCommit();
      await target.parent.create(recursive: true);
      final staging = await target.parent.createTemp('.aicove-write-');
      final temp = File(p.join(staging.path, 'content'));
      try {
        await temp.writeAsBytes(bytes, flush: true);
        if (await target.exists() && !Platform.isWindows) {
          final mode = (await target.stat()).mode & 0xfff;
          final result = await Process.run('/bin/chmod', [
            mode.toRadixString(8),
            temp.path,
          ]);
          if (result.exitCode != 0) throw FileSystemException('无法保留文件权限', path);
        }
        await _checkRevision(resolved, expectedRevision);
        // Recheck aliases before the final commit; cancellation never leaves a partial file.
        if (await checked(path) != resolved)
          throw const WorkspaceException.invalidPath('目标路径已变化');
        _beforeCommit();
        await temp.rename(resolved);
      } finally {
        await staging.delete(recursive: true);
      }
      return WorkspaceFile(
        path: path,
        revision: sha256.convert(bytes).toString(),
        size: bytes.length,
        updatedAt: DateTime.now(),
      );
    });
  }

  @override
  Future<void> delete(String path, {required String expectedRevision}) async {
    final resolved = await checked(path);
    await _locked([resolved], () async {
      await _checkRevision(resolved, expectedRevision);
      final requested = absolute(path);
      if (await FileSystemEntity.type(requested, followLinks: false) ==
          FileSystemEntityType.link) {
        _beforeCommit();
        await Link(requested).delete();
      } else {
        final file = await _file(resolved);
        _beforeCommit();
        await file.delete();
      }
    });
  }

  @override
  Future<void> move(
    String from,
    String to, {
    required String expectedRevision,
  }) async {
    final source = await checked(from), target = await checked(to);
    await _locked([source, target], () async {
      await _checkRevision(source, expectedRevision);
      if (await FileSystemEntity.type(target, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw const WorkspaceException.invalidPath('目标已经存在');
      }
      _beforeCommit();
      await File(target).parent.create(recursive: true);
      final requested = absolute(from);
      if (await FileSystemEntity.type(requested, followLinks: false) ==
          FileSystemEntityType.link) {
        _beforeCommit();
        await Link(requested).rename(target);
      } else {
        final file = await _file(source);
        _beforeCommit();
        await file.rename(target);
      }
    });
  }

  @override
  Future<List<WorkspaceEntry>> listDirectory(
    String path, {
    List<String>? skipped,
  }) async {
    final entries = <WorkspaceEntry>[];
    await for (final entity in Directory(await checked(path)).list()) {
      try {
        final resolved = await checked(entity.path);
        final stat = await File(resolved).stat();
        final name = p.basename(entity.path);
        if (stat.type == FileSystemEntityType.directory)
          entries.add(WorkspaceEntry.directory(name));
        if (stat.type == FileSystemEntityType.file)
          entries.add(
            WorkspaceEntry.file(
              name,
              WorkspaceFile(
                path: entity.path,
                revision: '',
                size: stat.size,
                updatedAt: stat.modified,
              ),
            ),
          );
      } on WorkspaceException catch (e) {
        skipped?.add('${entity.path}: ${e.message}');
      } on FileSystemException catch (e) {
        skipped?.add('${entity.path}: ${e.message}');
      }
    }
    entries.sort(
      (a, b) => a.isDirectory != b.isDirectory
          ? (a.isDirectory ? -1 : 1)
          : a.name.compareTo(b.name),
    );
    return entries;
  }

  static const ignoredDirectories = {
    '.git',
    'node_modules',
    '.dart_tool',
    'build',
    '.venv',
    'venv',
    '__pycache__',
  };
  @override
  Future<List<WorkspaceFile>> files({
    String path = '',
    bool includeIgnored = false,
    List<String>? skipped,
  }) async {
    final result = <WorkspaceFile>[];
    final start = await checked(path);
    final canonicalRoot = await checked(rootPath);
    final ruleRoot =
        p.equals(start, canonicalRoot) || p.isWithin(canonicalRoot, start)
        ? canonicalRoot
        : (await File(start).stat()).type == FileSystemEntityType.directory
        ? start
        : p.dirname(start);
    String relative(String at) =>
        p.relative(at, from: ruleRoot).split(p.separator).join('/');
    Future<GitignoreMatcher> loadRules(
      String directory,
      GitignoreMatcher matcher,
    ) async {
      if (includeIgnored) return matcher;
      final ignorePath = p.join(directory, '.gitignore');
      try {
        if (await FileSystemEntity.type(ignorePath, followLinks: false) !=
            FileSystemEntityType.file) {
          return matcher;
        }
        final content = await (await _file(ignorePath)).readAsString();
        return matcher.withRules(
          content,
          base: p.equals(directory, ruleRoot) ? '' : relative(directory),
        );
      } on FileSystemException catch (e) {
        skipped?.add('$ignorePath: ${e.message}');
      } on WorkspaceException catch (e) {
        skipped?.add('$ignorePath: ${e.message}');
      } on FormatException catch (e) {
        skipped?.add('$ignorePath: ${e.message}');
      }
      return matcher;
    }

    bool ignored(String at, bool isDirectory, GitignoreMatcher matcher) =>
        !includeIgnored &&
        ((isDirectory && ignoredDirectories.contains(p.basename(at))) ||
            matcher.ignores(relative(at), isDirectory: isDirectory));

    // Searches starting below the workspace still inherit ancestor rules.
    var inherited = GitignoreMatcher();
    var ancestor = ruleRoot;
    final parents = <String>[];
    for (
      var at = p.dirname(start);
      p.isWithin(ruleRoot, at);
      at = p.dirname(at)
    ) {
      parents.add(at);
    }
    if (!p.equals(start, ruleRoot)) {
      inherited = await loadRules(ancestor, inherited);
      for (ancestor in parents.reversed) {
        if (ignored(ancestor, true, inherited)) return result;
        inherited = await loadRules(ancestor, inherited);
      }
    }
    Future<void> visit(String at, GitignoreMatcher matcher) async {
      try {
        final type = await FileSystemEntity.type(at, followLinks: false);
        if (!p.equals(at, ruleRoot) &&
            ignored(at, type == FileSystemEntityType.directory, matcher)) {
          return;
        }
        final resolved = await checked(at);
        final stat = await File(resolved).stat();
        if (stat.type == FileSystemEntityType.file) {
          if (!Platform.isWindows && (stat.mode & 0xf000) != 0x8000) {
            skipped?.add('$at: 非普通文件');
            return;
          }
          result.add(
            WorkspaceFile(
              path: p
                  .relative(at, from: canonicalRoot)
                  .split(p.separator)
                  .join('/'),
              revision: '',
              size: stat.size,
              updatedAt: stat.modified,
            ),
          );
        } else if (stat.type == FileSystemEntityType.directory &&
            type != FileSystemEntityType.link) {
          matcher = await loadRules(at, matcher);
          final children = await Directory(
            at,
          ).list(followLinks: false).toList();
          children.sort((a, b) => a.path.compareTo(b.path));
          for (final child in children) {
            await visit(child.path, matcher);
          }
        } else {
          skipped?.add('$at: 未跟随目录链接或非普通文件');
        }
      } on FileSystemException catch (e) {
        skipped?.add('$at: ${e.message}');
      } on WorkspaceException catch (e) {
        skipped?.add('$at: ${e.message}');
      }
    }

    await visit(start, inherited);
    return result;
  }
}
