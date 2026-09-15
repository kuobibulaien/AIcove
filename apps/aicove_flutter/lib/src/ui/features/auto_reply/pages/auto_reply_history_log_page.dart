/// AutoReplyHistoryLogPage - 主动回复历史日志页面
///
/// 从设置页独立出来的完整日志列表，本地最多保留最近 200 条。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/auto_reply/data/auto_reply_trigger.dart';
import '../../../../features/auto_reply/data/auto_reply_trigger_controller.dart';
import '../../../../features/auto_reply/data/auto_reply_trigger_storage.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../widgets/auto_reply_history_log_card.dart';

class AutoReplyHistoryLogPage extends ConsumerStatefulWidget {
  const AutoReplyHistoryLogPage({super.key});

  @override
  ConsumerState<AutoReplyHistoryLogPage> createState() =>
      _AutoReplyHistoryLogPageState();
}

class _AutoReplyHistoryLogPageState
    extends ConsumerState<AutoReplyHistoryLogPage> {
  final AutoReplyTriggerStorage _storage = AutoReplyTriggerStorage();
  List<AutoReplyTriggerLog> _logs = const <AutoReplyTriggerLog>[];
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load(silent: true));
  }

  Future<void> _load({bool silent = false}) async {
    if (mounted) setState(() => _loading = true);
    try {
      final logs = await _storage.loadLogs();
      if (!mounted) return;
      setState(() => _logs = logs);
    } catch (e) {
      if (mounted && !silent) {
        MoeToast.error(context, '读取历史日志失败: $e');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AutoReplyTriggerEvent?>(autoReplyTriggerEventProvider, (
      previous,
      next,
    ) {
      if (next == null) return;
      unawaited(_load(silent: true));
    });

    return MoePageScaffold(
      appBar: const MoeAppBar(title: '历史记录', showBackButton: true),
      backgroundColor: context.moeColors.surface,
      body: MoeSettingsContent(
        child: ListView(
          padding: MoeSettingsLayout.verticalListPadding,
          children: [
            AutoReplyHistoryLogCard(
              logs: _logs,
              loading: _loading,
              maxItems: 200,
              onRefresh: _load,
            ),
          ],
        ),
      ),
    );
  }
}
