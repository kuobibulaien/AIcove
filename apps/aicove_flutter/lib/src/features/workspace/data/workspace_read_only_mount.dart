import 'dart:typed_data';

/// A live, host-owned view. Paths are relative to the registered prefix.
abstract interface class WorkspaceReadOnlyMount {
  Future<Map<String, MountedWorkspaceFile>> files();
}

/// Enumeration is metadata-only; bytes are loaded only by an explicit read.
class MountedWorkspaceFile {
  const MountedWorkspaceFile({
    required this.size,
    required this.revision,
    required this.updatedAt,
    required this.read,
  });
  final int size;
  final String revision;
  final DateTime updatedAt;
  final Future<Uint8List> Function() read;
}

const stickerViewReadOnly = '这里是表情库的只读视图，不能修改。改标签请用 aicove_sticker_set_tags。';
