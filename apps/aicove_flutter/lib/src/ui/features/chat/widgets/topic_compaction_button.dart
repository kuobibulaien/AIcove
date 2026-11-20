import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../features/context/application/context_manager.dart';
import '../../../../features/context/domain/context_summary.dart';
import '../../../../features/context/providers/context_providers.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';

/// 聊天页「更多」菜单的手动压缩入口；仅在未进入整理/待确认且生成中时提示不打开。
Future<void> showTopicCompactionDialog(
  BuildContext context,
  WidgetRef ref, {
  required String ownerId,
  required bool isGenerating,
}) async {
  final session = ref.read(manualCompactionSessionProvider);
  final state = session.stateOf(ownerId);
  if (isGenerating && !state.preparing && state.draft == null) {
    MoeToast.info(context, '请等本轮回复结束后再压缩。');
    return;
  }
  session.markForeground(ownerId);
  final result = await showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (_) => TopicCompactionDialog(
      ownerId: ownerId,
      port: ref.read(manualCompactionProvider),
      session: session,
    ),
  );
  if (context.mounted && result != null) MoeToast.info(context, result);
}

/// 只操作应用层 Port；确认前不会移动 raw 边界。宽屏 760px，窄屏/键盘下内容滚动。
class TopicCompactionDialog extends StatefulWidget {
  const TopicCompactionDialog({
    super.key,
    required this.ownerId,
    required this.port,
    this.session,
  });
  final String ownerId;
  final ManualCompactionPort port;
  final ManualCompactionSessionStore? session;
  @override
  State<TopicCompactionDialog> createState() => _TopicCompactionDialogState();
}

class _TopicCompactionDialogState extends State<TopicCompactionDialog> {
  final _text = TextEditingController();
  late ManualCompactionSessionStore _session;
  bool _ownsSession = false;

  @override
  void initState() {
    super.initState();
    _attachSession();
    _syncOwnerSession();
  }

  void _attachSession() {
    final external = widget.session;
    if (external != null) {
      _session = external;
      _ownsSession = false;
    } else {
      _session = ManualCompactionSessionStore.fromPort(widget.port);
      _ownsSession = true;
    }
    _session.addListener(_onSessionChanged);
  }

  void _syncOwnerSession() {
    final state = _session.stateOf(widget.ownerId);
    if (state.backgrounded || state.notice != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _session.markForeground(widget.ownerId);
      });
    }
    if (_text.text != state.draftText) {
      _text.text = state.draftText;
    }
    if (state.currentSummary == null &&
        !state.preparing &&
        !state.committing) {
      _session.loadCurrent(widget.ownerId);
    }
  }

  void _onSessionChanged(String changedOwnerId) {
    if (!mounted || changedOwnerId != widget.ownerId) return;
    final state = _session.stateOf(widget.ownerId);
    if (_text.text != state.draftText) {
      _text.text = state.draftText;
    }
    setState(() {});
  }

  @override
  void didUpdateWidget(covariant TopicCompactionDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    final sessionChanged =
        oldWidget.session != widget.session ||
        (_ownsSession && oldWidget.port != widget.port);
    if (sessionChanged) {
      _session.removeListener(_onSessionChanged);
      if (_ownsSession) {
        _session.dispose();
      }
      _attachSession();
      _syncOwnerSession();
    } else if (oldWidget.ownerId != widget.ownerId) {
      _syncOwnerSession();
    }
  }

  @override
  void dispose() {
    _session.removeListener(_onSessionChanged);
    if (_ownsSession) {
      _session.dispose();
    }
    _text.dispose();
    super.dispose();
  }

  Future<void> _commit() async {
    final ok = await _session.commit(widget.ownerId, _text.text);
    if (ok && mounted) {
      Navigator.of(context).pop('已保留内容，新话题将使用最新角色卡。');
    }
  }

  Future<void> _undo() async {
    final accepted = await showMeoTalkDialog(
      context: context,
      title: '撤销上次压缩',
      content: const Text('恢复上次压缩前的对话，聊天记录不会删除。'),
      confirmText: '恢复上下文',
    );
    if (accepted != true || !mounted) return;
    final ok = await _session.undo(widget.ownerId);
    if (ok && mounted) {
      Navigator.of(context).pop('已恢复上次压缩前的上下文；长期记忆未撤回。');
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = _session.stateOf(widget.ownerId);
    final busy = state.preparing || state.committing;
    final maxHeight = (MediaQuery.sizeOf(context).height -
            MediaQuery.viewInsetsOf(context).bottom -
            240)
        .clamp(80.0, 500.0);
    return PopScope(
      canPop: !state.committing,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop && _session.stateOf(widget.ownerId).preparing) {
          _session.enterBackground(widget.ownerId);
        }
      },
      child: Center(
          child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: MeoTalkDialog(
          title: state.draft != null && !state.preparing
              ? '确认保留的内容'
              : '压缩并开启新话题',
          cancelText: state.preparing ? '取消整理' : '取消',
          showCancelButton: !state.committing,
          onCancel: () {
            if (state.preparing) {
              _session.cancelPrepare(widget.ownerId);
            } else if (state.draft != null) {
              _session.discardDraft(widget.ownerId);
            }
            Navigator.of(context).pop();
          },
          confirmText: state.preparing
              ? '后台整理'
              : (state.draft == null ? '整理内容' : '保存并开启'),
          onConfirm: state.committing
              ? null
              : state.preparing
                  ? () {
                      _session.enterBackground(widget.ownerId);
                      Navigator.of(context)
                          .pop('已转入后台整理，完成后打开「压缩上下文」即可确认开启。');
                    }
                  : (state.draft == null
                      ? () => _session.prepare(widget.ownerId)
                      : _commit),
          content: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: SingleChildScrollView(
                child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('把前面的对话整理成摘要，聊天记录不会删除。'),
                const SizedBox(height: 12),
                if (busy) ...[
                  Text(state.progress),
                  const LinearProgressIndicator()
                ],
                if (state.draft != null && !busy) ...[
                  MoeTextField(
                    controller: _text,
                    minLines: 4,
                    maxLines: 8,
                    label: '新话题内容摘要（可修改）',
                    onChanged: (value) =>
                        _session.updateDraftText(widget.ownerId, value),
                  ),
                  const Text('确认后将整理进长期记忆。'),
                  IntrinsicWidth(
                    child: MoeSecondaryButton(
                      label: '重新整理（保留原话题）',
                      icon: Icons.refresh,
                      size: MoeSecondaryButtonSize.sm,
                      onPressed: () => _session.prepare(widget.ownerId),
                    ),
                  ),
                ],
                if (state.draft == null && !busy) ...[
                  if (state.currentSummary != null)
                    Text('上次内容摘要：\n${state.currentSummary!.summary}',
                        maxLines: 4, overflow: TextOverflow.ellipsis),
                  IntrinsicWidth(
                    child: MoeSecondaryButton(
                      label: '撤销上次压缩',
                      icon: Icons.undo,
                      size: MoeSecondaryButtonSize.sm,
                      onPressed: _undo,
                    ),
                  ),
                ],
                if (state.error != null)
                  Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(state.error!,
                          style: TextStyle(color: context.moeColors.text))),
              ],
            )),
          ),
        ),
      )),
    );
  }
}
