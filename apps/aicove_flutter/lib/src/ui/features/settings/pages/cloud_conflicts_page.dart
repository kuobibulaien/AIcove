import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/sync/providers/cloud_sync_provider.dart';
import '../../../../features/sync/data/cloud_document.dart';
import '../../../shared/widgets/index.dart';

class CloudConflictsPage extends ConsumerStatefulWidget {
  const CloudConflictsPage({super.key});
  @override
  ConsumerState<CloudConflictsPage> createState() => _CloudConflictsPageState();
}

class _CloudConflictsPageState extends ConsumerState<CloudConflictsPage> {
  late Future<Map<String, dynamic>> _preview = ref
      .read(cloudSyncProvider.notifier)
      .conflicts();
  bool _busy = false;
  String? _error;

  Future<void> _resolve(
    Map<String, dynamic> preview,
    String id,
    bool incoming,
  ) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(cloudSyncProvider.notifier).resolve(preview, id, incoming);
      if (mounted) {
        setState(
          () => _preview = ref.read(cloudSyncProvider.notifier).conflicts(),
        );
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is CloudSyncFailure
              ? error.message
              : '处理未完成，请刷新后重试',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _describe(Map document) {
    if (document['deleted'] == true || document['action'] == 'delete') {
      return '删除这条记录';
    }
    final payload = document['payload'] as Map? ?? {};
    final row = payload['row'] as Map?;
    if (row?['content'] is String) return row!['content'] as String;
    if (row?['display_name'] is String) return row!['display_name'] as String;
    final json = const JsonEncoder.withIndent('  ').convert(payload);
    return json.length > 3000
        ? '${json.substring(0, 3000)}\n…（完整版本仍在云端保留）'
        : json;
  }

  @override
  Widget build(BuildContext context) => MoePageScaffold(
    appBar: const MoeAppBar(title: '处理同时修改', showBackButton: true),
    body: FutureBuilder<Map<String, dynamic>>(
      future: _preview,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return Center(
            child: Text(snapshot.hasError ? '无法读取，请返回后重试' : '正在读取两个版本'),
          );
        }
        final preview = snapshot.data!;
        final conflicts = (preview['conflicts'] as List).cast<Map>();
        if (conflicts.isEmpty) return const Center(child: Text('没有需要处理的同时修改'));
        return ListView(
          padding: const EdgeInsets.all(24),
          children: [
            if (_error != null) Text(_error!),
            for (final conflict in conflicts)
              Padding(
                padding: const EdgeInsets.only(bottom: 32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('记录：${(conflict['incoming'] as Map)['entity_id']}'),
                    const SizedBox(height: 12),
                    const Text('云端现有版本'),
                    SelectableText(_describe(conflict['latest'] as Map)),
                    MoeSecondaryButton(
                      label: '保留云端版本',
                      enabled: !_busy,
                      onPressed: () => _resolve(
                        preview,
                        conflict['conflict_id'] as String,
                        false,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text('来自设备 ${conflict['device_id']} 的修改'),
                    SelectableText(_describe(conflict['incoming'] as Map)),
                    MoeSecondaryButton(
                      label: '采用这次修改',
                      enabled: !_busy,
                      onPressed: () => _resolve(
                        preview,
                        conflict['conflict_id'] as String,
                        true,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    ),
  );
}
