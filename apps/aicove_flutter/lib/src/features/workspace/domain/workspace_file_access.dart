import 'dart:typed_data';
import 'workspace_models.dart';

/// File operations independent of managed workspaces and native directories.
abstract interface class WorkspaceFileAccess {
  String? get workspaceId;
  String get rootPath;
  bool get isLocal;
  void checkWritable(String path);
  Future<(Uint8List, String)> read(String path);
  Future<Uint8List> readRange(
    String path, {
    required int offset,
    required int length,
  });
  Stream<List<int>> openRead(String path);
  Future<String?> revision(String path);
  Future<WorkspaceFile?> stat(String path);
  Future<WorkspaceFile> write(
    String path,
    List<int> bytes, {
    String? expectedRevision,
  });
  Future<void> delete(String path, {required String expectedRevision});
  Future<void> move(String from, String to, {required String expectedRevision});
  Future<List<WorkspaceEntry>> listDirectory(
    String path, {
    List<String>? skipped,
  });
  Future<List<WorkspaceFile>> files({
    String path,
    bool includeIgnored,
    List<String>? skipped,
  });
}

class WorkspaceFileTarget {
  const WorkspaceFileTarget(this.access, this.path);
  final WorkspaceFileAccess access;
  final String path;
}
