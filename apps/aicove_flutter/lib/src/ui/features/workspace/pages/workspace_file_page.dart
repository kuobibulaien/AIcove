import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/workspace/workspace_providers.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';
import 'workspace_detail_page.dart' show formatWorkspaceSize;

/// Read-only view of one workspace file.
class WorkspaceFilePage extends ConsumerStatefulWidget {
  const WorkspaceFilePage({
    super.key,
    required this.workspaceId,
    required this.path,
  });

  final String workspaceId;
  final String path;

  /// Longer text shows only its beginning.
  static const previewChars = 200000;

  @override
  ConsumerState<WorkspaceFilePage> createState() => _WorkspaceFilePageState();
}

class _WorkspaceFilePageState extends ConsumerState<WorkspaceFilePage> {
  late final Future<(String?, int)> _content = _load();

  Future<(String?, int)> _load() async {
    final store = await ref.read(workspaceStoreProvider.future);
    final (bytes, _) = await store.read(widget.workspaceId, widget.path);
    try {
      return (utf8.decode(bytes), bytes.length);
    } on FormatException {
      return (null, bytes.length);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    return MoePageScaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: colors.surface,
      appBar: MoeAppBar(
        title: widget.path.split('/').last,
        showBackButton: true,
      ),
      body: FutureBuilder<(String?, int)>(
        future: _content,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return MoeEmptyState(
              icon: Icons.error_outline,
              title: '读取失败',
              description: '${snapshot.error}',
            );
          }
          final data = snapshot.data;
          if (data == null) {
            return const Center(child: CircularProgressIndicator());
          }
          final (text, size) = data;
          if (text == null) {
            return MoeEmptyState(
              icon: Icons.insert_drive_file_outlined,
              title: '二进制文件',
              description: '${formatWorkspaceSize(size)}，无法按文字显示',
            );
          }
          final cut = text.length > WorkspaceFilePage.previewChars;
          return SingleChildScrollView(
            padding: moeUnderBarPadding(context, const EdgeInsets.all(16)),
            child: SelectableText(
              cut
                  ? '${text.substring(0, WorkspaceFilePage.previewChars)}\n\n'
                        '（文件较长，只显示开头部分）'
                  : text,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                height: 1.5,
                color: colors.text,
              ),
            ),
          );
        },
      ),
    );
  }
}
