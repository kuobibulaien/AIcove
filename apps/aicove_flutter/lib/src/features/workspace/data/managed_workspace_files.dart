import 'dart:typed_data';
import 'package:path/path.dart' as p;
import '../domain/workspace_file_access.dart';
import '../domain/workspace_models.dart';
import '../domain/workspace_path_rules.dart';
import 'workspace_store.dart';

class ManagedWorkspaceFiles implements WorkspaceFileAccess {
  ManagedWorkspaceFiles(this.store, this.workspaceId, this.runId);
  final WorkspaceStore store;
  @override
  final String workspaceId;
  final String runId;
  @override
  bool get isLocal => false;
  @override
  String get rootPath => store.directoryOf(workspaceId).path;
  @override
  void checkWritable(String path) => store.checkWritablePath(workspaceId, path);
  @override
  Future<(Uint8List, String)> read(String path) =>
      store.read(workspaceId, path);
  @override
  Future<Uint8List> readRange(
    String path, {
    required int offset,
    required int length,
  }) => store.readRange(workspaceId, path, offset: offset, length: length);
  @override
  Stream<List<int>> openRead(String path) async* {
    yield (await read(path)).$1;
  }

  @override
  Future<String?> revision(String path) async =>
      await stat(path) == null ? null : (await read(path)).$2;
  @override
  Future<WorkspaceFile?> stat(String path) => store.stat(workspaceId, path);
  @override
  Future<WorkspaceFile> write(
    String path,
    List<int> bytes, {
    String? expectedRevision,
  }) => store.write(
    workspaceId,
    path,
    bytes,
    expectedRevision: expectedRevision,
    runId: runId,
  );
  @override
  Future<void> delete(String path, {required String expectedRevision}) =>
      store.delete(
        workspaceId,
        path,
        expectedRevision: expectedRevision,
        runId: runId,
      );
  @override
  Future<void> move(
    String from,
    String to, {
    required String expectedRevision,
  }) => store.move(
    workspaceId,
    from,
    to,
    expectedRevision: expectedRevision,
    runId: runId,
  );
  @override
  Future<List<WorkspaceEntry>> listDirectory(
    String path, {
    List<String>? skipped,
  }) => store.listDirectory(workspaceId, path);
  @override
  Future<List<WorkspaceFile>> files({
    String path = '',
    bool includeIgnored = false,
    List<String>? skipped,
  }) async {
    final dir = WorkspacePathRules.normalizeDirectory(path);
    return [
      for (final file in await store.files(workspaceId))
        if (dir.isEmpty || file.path == dir || p.posix.isWithin(dir, file.path))
          file,
    ];
  }
}
