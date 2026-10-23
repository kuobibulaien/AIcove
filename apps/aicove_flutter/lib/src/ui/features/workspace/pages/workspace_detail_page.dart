import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/workspace/data/workspace_store.dart';
import '../../../../features/workspace/domain/workspace_models.dart';
import '../../../../features/workspace/webapp/webapp_launcher.dart';
import '../../../../features/workspace/workspace_providers.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';
import 'workspace_file_page.dart';

/// Read-only browser of one workspace directory; the root also lists the
/// runs that changed it, each undoable as a whole (ADR0087 §3, §8).
class WorkspaceDetailPage extends ConsumerStatefulWidget {
  const WorkspaceDetailPage({
    super.key,
    required this.workspaceId,
    this.directory = '',
  });

  final String workspaceId;

  /// '' for the workspace root.
  final String directory;

  @override
  ConsumerState<WorkspaceDetailPage> createState() =>
      _WorkspaceDetailPageState();
}

class _WorkspaceDetail {
  const _WorkspaceDetail(this.store, this.info, this.entries, this.runs);
  final WorkspaceStore store;
  final WorkspaceInfo? info;
  final List<WorkspaceEntry> entries;
  final List<WorkspaceRunSummary> runs;
}

class _WorkspaceDetailPageState extends ConsumerState<WorkspaceDetailPage> {
  late Future<_WorkspaceDetail> _detail = _load();
  bool _undoing = false;

  bool get _isRoot => widget.directory.isEmpty;

  Future<_WorkspaceDetail> _load() async {
    final store = await ref.read(workspaceStoreProvider.future);
    return _WorkspaceDetail(
      store,
      await store.get(widget.workspaceId),
      await store.listDirectory(widget.workspaceId, widget.directory),
      _isRoot ? await store.runs(widget.workspaceId) : const [],
    );
  }

  void _reload() {
    final detail = _load();
    setState(() {
      _detail = detail;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    return FutureBuilder<_WorkspaceDetail>(
      future: _detail,
      builder: (context, snapshot) {
        final detail = snapshot.data;
        final title = _isRoot
            ? detail?.info?.name ?? '空间'
            : widget.directory.split('/').last;
        return MoePageScaffold(
          extendBodyBehindAppBar: true,
          backgroundColor: colors.surface,
          appBar: MoeAppBar(title: title, showBackButton: true),
          body: MoeSettingsContent(
            child: Builder(
              builder: (context) {
                if (snapshot.hasError) {
                  return MoeEmptyState(
                    icon: Icons.error_outline,
                    title: '读取失败',
                    description: '${snapshot.error}',
                  );
                }
                if (detail == null) {
                  return const Center(child: CircularProgressIndicator());
                }
                return _buildList(context, detail);
              },
            ),
          ),
        );
      },
    );
  }

  Widget _buildList(BuildContext context, _WorkspaceDetail detail) {
    final colors = context.moeColors;
    final description = detail.info?.description ?? '';
    return ListView(
      padding: moeUnderBarPadding(
        context,
        MoeSettingsLayout.verticalListPadding,
      ),
      children: [
        if (_isRoot && description.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              description,
              style: TextStyle(color: colors.textSecondary, fontSize: 14),
            ),
          ),
          const SizedBox(height: MoeSettingsLayout.sectionGap),
        ],
        MoeSettingsGroup(
          title: '文件',
          children: [
            if (detail.entries.isEmpty)
              const MoeSettingsRow(
                label: '空',
                trailingType: MoeSettingsRowTrailing.none,
                showDivider: false,
              ),
            for (final (index, entry) in detail.entries.indexed)
              MoeSettingsRow(
                key: ValueKey('workspace-entry-${entry.name}'),
                icon: entry.isDirectory
                    ? Icons.folder_outlined
                    : Icons.description_outlined,
                label: entry.name,
                trailingType: entry.isDirectory
                    ? MoeSettingsRowTrailing.chevron
                    : MoeSettingsRowTrailing.text,
                detailText: entry.file == null
                    ? null
                    : formatWorkspaceSize(entry.file!.size),
                showDivider: index < detail.entries.length - 1,
                onTap: () => _openEntry(context, entry),
              ),
          ],
        ),
        if (_isRoot) ...[
          const SizedBox(height: MoeSettingsLayout.sectionGap),
          MoeSettingsGroup(
            title: '修改记录',
            children: [
              if (detail.runs.isEmpty)
                const MoeSettingsRow(
                  label: '还没有 Agent 改过这里',
                  trailingType: MoeSettingsRowTrailing.none,
                  showDivider: false,
                ),
              for (final (index, run) in detail.runs.indexed)
                MoeSettingsRow(
                  key: ValueKey('workspace-run-${run.runId}'),
                  icon: Icons.history,
                  label: run.runId.startsWith('webapp-')
                      ? '${_time(run.startedAt)} · 网页存档'
                      : '${_time(run.startedAt)} · ${run.opCount} 处修改',
                  subtitle: _pathsText(run.paths),
                  trailingType: MoeSettingsRowTrailing.text,
                  detailText: run.undone ? '已撤销' : '撤销',
                  enabled: !run.undone && !_undoing,
                  showDivider: index < detail.runs.length - 1,
                  onTap: () => _undo(context, run),
                ),
            ],
          ),
        ],
      ],
    );
  }

  void _openEntry(BuildContext context, WorkspaceEntry entry) {
    final path = widget.directory.isEmpty
        ? entry.name
        : '${widget.directory}/${entry.name}';
    MoeWorkspace.open(
      context,
      entry.isDirectory
          ? WorkspaceDetailPage(
              workspaceId: widget.workspaceId,
              directory: path,
            )
          : WorkspaceFilePage(workspaceId: widget.workspaceId, path: path),
    );
  }

  Future<void> _undo(BuildContext context, WorkspaceRunSummary run) async {
    final confirmed = await showMeoTalkConfirm(
      context: context,
      title: '撤销这一轮修改？',
      message: [
        if (run.paths.length > run.commandPaths.length)
          '这一轮改过的 ${run.paths.length - run.commandPaths.length} 个文件'
              '会恢复到改之前的样子。之后又被别处改过的文件会保留现状。',
        if (run.commandPaths.isNotEmpty)
          '命令造成的改动不能撤销：\n${_pathList(run.commandPaths)}',
      ].join('\n\n'),
      confirmText: '撤销',
    );
    if (confirmed != true || !context.mounted) return;
    setState(() => _undoing = true);
    try {
      // The web app host pauses page saves around the undo (ADR0105 §4).
      final server = await ref.read(webAppServerProvider.future);
      final result = await server.undoRun(widget.workspaceId, run.runId);
      if (!context.mounted) return;
      if (result.conflicts.isEmpty && result.commandChanges.isEmpty) {
        MoeToast.success(context, '已撤销 ${result.undone} 处修改');
      } else {
        await showMeoTalkAlert(
          context: context,
          title: '部分文件没有撤销',
          message: [
            if (result.conflicts.isNotEmpty)
              '这些文件在这一轮之后又被改过，已保留现状：\n'
                  '${_pathList(result.conflicts)}',
            if (result.commandChanges.isNotEmpty)
              '命令造成的改动不能撤销：\n${_pathList(result.commandChanges)}',
          ].join('\n\n'),
        );
      }
    } catch (error) {
      if (context.mounted) MoeToast.error(context, '撤销失败：$error');
    } finally {
      if (mounted) {
        _undoing = false;
        _reload();
      }
    }
  }

  /// Up to five paths, then a count of the rest.
  static String _pathList(List<String> paths) => [
    ...paths.take(5),
    if (paths.length > 5) '等 ${paths.length} 个文件',
  ].join('\n');

  static String _time(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.month}月${time.day}日 ${two(time.hour)}:${two(time.minute)}';
  }

  static String _pathsText(List<String> paths) => paths.length <= 3
      ? paths.join('、')
      : '${paths.take(3).join('、')} 等 ${paths.length} 个文件';
}

String formatWorkspaceSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1 << 20) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';
}
