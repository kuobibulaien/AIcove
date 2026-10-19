import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/workspace/domain/workspace_errors.dart';
import '../../../../features/workspace/domain/workspace_models.dart';
import '../../../../features/workspace/workspace_providers.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';
import 'workspace_detail_page.dart';

/// Home tab listing the Agent workspaces on this device (ADR0087 §8).
class WorkspaceListPage extends ConsumerWidget {
  const WorkspaceListPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.moeColors;
    final workspaces = ref.watch(workspacesProvider);
    return Scaffold(
      backgroundColor: MoeSurfaceGroup.contains(context)
          ? Colors.transparent
          : colors.surface,
      extendBodyBehindAppBar: true,
      appBar: MoeAppBar(
        title: '空间',
        centerTitle: true,
        actions: [
          MoeIconButton(
            icon: Icons.add,
            tooltip: '新建空间',
            onTap: () => _create(context, ref),
          ),
        ],
      ),
      body: MoeSettingsContent(
        child: Builder(
          builder: (bodyContext) => workspaces.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => MoeEmptyState(
              icon: Icons.error_outline,
              title: '空间加载失败',
              description: '$error',
            ),
            // Never empty: the store always holds the AIcove workspace.
            data: (items) => ListView(
              // The body context, under the translucent app bar.
              padding: moeUnderBarPadding(
                bodyContext,
                MoeSettingsLayout.verticalListPadding,
              ),
              children: [
                MoeSettingsGroup(
                  children: [
                    for (final (index, workspace) in items.indexed)
                      MoeSettingsRow(
                        key: ValueKey('workspace-${workspace.id}'),
                        label: workspace.name,
                        subtitle: workspace.description.isEmpty
                            ? null
                            : workspace.description,
                        showDivider: index < items.length - 1,
                        onTap: () => MoeWorkspace.open(
                          context,
                          WorkspaceDetailPage(workspaceId: workspace.id),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static Future<void> _create(BuildContext context, WidgetRef ref) async {
    var name = '';
    var description = '';
    final confirmed = await showMeoTalkDialog(
      context: context,
      title: '新建空间',
      confirmText: '新建',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          MoeTextField(
            hint: '名称',
            autofocus: true,
            onChanged: (value) => name = value,
          ),
          const SizedBox(height: 12),
          MoeTextField(
            hint: '一句话说明用途（可不填）',
            onChanged: (value) => description = value,
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final WorkspaceInfo created;
    try {
      final store = await ref.read(workspaceStoreProvider.future);
      created = await store.create(name: name, description: description);
    } on WorkspaceException catch (error) {
      if (context.mounted) MoeToast.error(context, error.message);
      return;
    }
    ref.invalidate(workspacesProvider);
    if (context.mounted) {
      MoeWorkspace.open(context, WorkspaceDetailPage(workspaceId: created.id));
    }
  }
}
