import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/workspace/domain/workspace_models.dart';
import '../../../../features/workspace/webapp/webapp_launcher.dart';
import '../../../../features/workspace/webapp/webapp_server.dart';
import '../../../../features/workspace/workspace_providers.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';
import 'workspace_detail_page.dart' show formatWorkspaceSize;

/// Read-only view of one workspace file. Text and images show in place;
/// anything else opens in the device's default app, and HTML pages can also
/// run in the default browser (ADR0105).
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

  static const _imageExtensions = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'};

  static bool isImage(String path) => _imageExtensions.contains(
    path.split('/').last.split('.').last.toLowerCase(),
  );

  @override
  ConsumerState<WorkspaceFilePage> createState() => _WorkspaceFilePageState();
}

/// What the page shows: [bytes] is null when the file is too large to read.
typedef _Content = ({Uint8List? bytes, String? text, int size});

class _WorkspaceFilePageState extends ConsumerState<WorkspaceFilePage> {
  late final Future<_Content> _content = _load();
  final _openKey = GlobalKey();
  bool _launching = false;
  bool _opening = false;

  Future<_Content> _load() async {
    final store = await ref.read(workspaceStoreProvider.future);
    final size = (await store.stat(widget.workspaceId, widget.path))?.size;
    if (size != null && size > WorkspaceLimits.maxFileBytes) {
      return (bytes: null, text: null, size: size);
    }
    final (bytes, _) = await store.read(widget.workspaceId, widget.path);
    String? text;
    if (!WorkspaceFilePage.isImage(widget.path)) {
      try {
        text = utf8.decode(bytes);
      } on FormatException {
        text = null;
      }
    }
    return (bytes: bytes, text: text, size: bytes.length);
  }

  Future<void> _openExternally() async {
    final box = _openKey.currentContext?.findRenderObject() as RenderBox?;
    final origin = box == null
        ? null
        : box.localToGlobal(Offset.zero) & box.size;
    setState(() => _opening = true);
    try {
      final opener = await ref.read(workspaceFileOpenerProvider.future);
      final opened = await opener.open(
        widget.workspaceId,
        widget.path,
        origin: origin,
      );
      if (!opened && mounted) MoeToast.info(context, '这台设备上没有能打开它的应用');
    } catch (error) {
      if (mounted) MoeToast.error(context, '打开失败：$error');
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Future<void> _run() async {
    setState(() => _launching = true);
    try {
      final launcher = await ref.read(webAppLauncherProvider.future);
      final result = await launcher.open(widget.workspaceId, widget.path);
      if (!mounted) return;
      MoeToast.info(
        context,
        result.portChanged
            ? '已在浏览器打开。这次换了端口，之前存在浏览器里的 IndexedDB 进度不会跟过来'
            : '已在浏览器打开，进度会自动存回空间',
      );
    } catch (error) {
      if (mounted) MoeToast.error(context, '运行失败：$error');
    } finally {
      if (mounted) setState(() => _launching = false);
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
        actions: [
          if (WebAppServer.isHtml(widget.path))
            MoeIconButton(
              key: const ValueKey('workspace-file-run'),
              icon: Icons.play_arrow_rounded,
              semanticLabel: '在浏览器中运行',
              onTap: _launching ? null : _run,
            ),
          MoeIconButton(
            key: _openKey,
            icon: Icons.open_in_new_rounded,
            semanticLabel: '用默认应用打开',
            onTap: _opening ? null : _openExternally,
          ),
        ],
      ),
      body: FutureBuilder<_Content>(
        future: _content,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return _underBar(
              MoeEmptyState(
                icon: Icons.error_outline,
                title: '读取失败',
                description: '${snapshot.error}',
              ),
            );
          }
          final data = snapshot.data;
          if (data == null) {
            return const Center(child: CircularProgressIndicator());
          }
          final bytes = data.bytes;
          if (bytes != null && WorkspaceFilePage.isImage(widget.path)) {
            return _image(context, bytes, data.size);
          }
          final text = data.text;
          if (text == null) return _other(data.size);
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

  Widget _image(BuildContext context, Uint8List bytes, int size) {
    final provider = MemoryImage(bytes);
    final heroTag = 'workspace-image-${widget.workspaceId}-${widget.path}';
    return Padding(
      padding: moeUnderBarPadding(context, const EdgeInsets.all(16)),
      child: Center(
        child: GestureDetector(
          onTap: () =>
              MoeImagePreview.show(context, provider, heroTag: heroTag),
          child: Hero(
            tag: heroTag,
            child: Image(
              key: const ValueKey('workspace-file-image'),
              image: provider,
              fit: BoxFit.contain,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => _otherCard(size),
            ),
          ),
        ),
      ),
    );
  }

  /// Centered so the floating bar never covers it.
  Widget _underBar(Widget child) => Padding(
    padding: moeUnderBarPadding(context, EdgeInsets.zero),
    child: Center(child: SingleChildScrollView(child: child)),
  );

  Widget _other(int size) => _underBar(_otherCard(size));

  Widget _otherCard(int size) => MoeEmptyState(
    icon: Icons.insert_drive_file_outlined,
    title: '这里不能直接显示',
    description: '${formatWorkspaceSize(size)}，可以交给设备上的默认应用打开',
    action: MoePrimaryButton(
      key: const ValueKey('workspace-file-open'),
      label: '用默认应用打开',
      icon: Icons.open_in_new_rounded,
      isLoading: _opening,
      onPressed: _openExternally,
    ),
  );
}
