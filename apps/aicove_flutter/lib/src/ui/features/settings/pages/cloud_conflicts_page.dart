import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/sync/providers/cloud_sync_provider.dart';
import '../../../../features/sync/providers/lan_sync_provider.dart';
import '../../../../features/sync/data/cloud_document.dart';
import '../../../../features/sync/data/device_names.dart';
import '../../../../features/sync/domain/lan_sync_port.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';

/// Conflicts are grouped by the device whose edit arrived second. Choosing a
/// device keeps its edits; every other conflict keeps the version that synced
/// first. Per-record details are intentionally hidden: there can be hundreds.
class CloudConflictsPage extends ConsumerStatefulWidget {
  const CloudConflictsPage({super.key});
  @override
  ConsumerState<CloudConflictsPage> createState() => _CloudConflictsPageState();
}

/// Sentinel group for "keep whatever synced first" (its writer is not recorded).
const _firstSynced = '';

class _CloudConflictsPageState extends ConsumerState<CloudConflictsPage> {
  late Future<Map<String, dynamic>> _preview = _load();

  bool _busy = false;
  String? _error;
  String? _progress;

  Future<Map<String, dynamic>> _load() =>
      ref.read(cloudSyncProvider.notifier).conflicts();

  Future<void> _useDevice(
    Map<String, dynamic> preview,
    String device,
    String name,
  ) async {
    final conflicts = (preview['conflicts'] as List).cast<Map>();
    final approved = await showMeoTalkConfirm(
      context: context,
      title: '以「$name」为准？',
      message: device == _firstSynced
          ? '全部 ${conflicts.length} 项都保留先同步上来的版本，后到的修改不再采用。'
          : '采用这台设备的 ${conflicts.where((c) => c['device_id'] == device).length} 项修改；其余差异保留先同步上来的版本。',
      hint: '被替换的版本不会被删除，仍保留在同步记录中。',
      confirmText: '开始处理',
    );
    if (approved != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
      _progress = '正在处理 0/${conflicts.length}';
    });
    try {
      await ref
          .read(cloudSyncProvider.notifier)
          .resolveAll(
            preview,
            {
              for (final c in conflicts)
                c['conflict_id'] as String: c['device_id'] == device,
            },
            onProgress: (done, total) {
              if (mounted) setState(() => _progress = '正在处理 $done/$total');
            },
          );
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is CloudSyncFailure
              ? error.message
              : '处理未完成，已处理的部分会保留，请刷新后继续',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
          _preview = _load();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    // Cloud and LAN share one device ID and one synced name directory.
    final names = ref.watch(deviceNamesProvider).valueOrNull ?? const {};
    final lan = ref.watch(lanSyncStateProvider).valueOrNull;
    final peers = {
      for (final peer in lan?.peers ?? const <LanPeerView>[])
        peer.id: peer.name,
    };
    String nameOf(String id) => deviceLabel(
      id,
      ownId: ref.read(cloudSyncProvider.notifier).deviceId,
      ownName: lan?.name,
      names: names,
      peerNames: peers,
    );
    return MoePageScaffold(
      extendBodyBehindAppBar: true,
      appBar: const MoeAppBar(title: '处理同时修改', showBackButton: true),
      body: FutureBuilder<Map<String, dynamic>>(
        future: _preview,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done ||
              !snapshot.hasData) {
            return Center(
              child: Text(
                snapshot.hasError ? '无法读取，请返回后重试' : (_progress ?? '正在读取'),
              ),
            );
          }
          final preview = snapshot.data!;
          final conflicts = (preview['conflicts'] as List).cast<Map>();
          if (conflicts.isEmpty) {
            return const Center(child: Text('没有需要处理的同时修改'));
          }
          final counts = <String, int>{};
          for (final c in conflicts) {
            final id = c['device_id'] as String;
            counts[id] = (counts[id] ?? 0) + 1;
          }
          final groups = [
            for (final e in counts.entries)
              (e.key, nameOf(e.key), '${e.value} 项修改与其他设备不同'),
            (_firstSynced, '云端最后状态', '保留云端现在的版本'),
          ];
          return ListView(
            padding: moeUnderBarPadding(context, const EdgeInsets.all(24)),
            children: [
              Text(
                '共 ${conflicts.length} 项被多台设备同时修改。选择一台设备，以它的版本为准一次处理完。',
                style: TextStyle(color: colors.textSecondary, height: 1.5),
              ),
              if (_progress != null || _error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _progress ?? _error!,
                  style: TextStyle(
                    color: _error != null && _progress == null
                        ? Theme.of(context).colorScheme.error
                        : colors.muted,
                  ),
                ),
              ],
              const SizedBox(height: 16),
              for (final (id, name, detail) in groups) ...[
                MoeSettingsGroup(
                  margin: EdgeInsets.zero,
                  padding: const EdgeInsets.all(16),
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          name,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 4),
                        Text(detail, style: TextStyle(color: colors.muted)),
                        const SizedBox(height: 12),
                        MoeSecondaryButton(
                          label: '以此设备为准处理差异',
                          enabled: !_busy,
                          onPressed: () => _useDevice(preview, id, name),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 12),
              ],
            ],
          );
        },
      ),
    );
  }
}
