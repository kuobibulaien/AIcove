import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../features/context/domain/context_summary.dart';
import '../../../../features/context/providers/context_providers.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';

/// 聊天页「更多」菜单的手动压缩入口；目标角色生成中只提示不打开。
Future<void> showTopicCompactionDialog(
  BuildContext context,
  WidgetRef ref, {
  required String ownerId,
  required bool isGenerating,
}) async {
  if (isGenerating) {
    MoeToast.info(context, '请等本轮回复结束后再压缩。');
    return;
  }
  final result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => TopicCompactionDialog(
          ownerId: ownerId, port: ref.read(manualCompactionProvider)));
  if (context.mounted && result != null) MoeToast.info(context, result);
}

/// 只操作应用层 Port；确认前不会移动 raw 边界。宽屏 760px，窄屏/键盘下内容滚动。
class TopicCompactionDialog extends StatefulWidget {
  const TopicCompactionDialog(
      {super.key, required this.ownerId, required this.port});
  final String ownerId;
  final ManualCompactionPort port;
  @override
  State<TopicCompactionDialog> createState() => _TopicCompactionDialogState();
}

class _TopicCompactionDialogState extends State<TopicCompactionDialog> {
  final _text = TextEditingController();
  ManualCompactionDraft? _draft;
  ContextSummary? _current;
  bool _busy = false, _committing = false, _cancelled = false;
  int _generation = 0;
  String? _error;
  String _progress = '';

  @override
  void initState() {
    super.initState();
    _loadCurrent();
  }

  @override
  void didUpdateWidget(covariant TopicCompactionDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ownerId != widget.ownerId) {
      _generation++;
      _draft = null;
      _current = null;
      _text.clear();
      _busy = false;
      _committing = false;
      _cancelled = false;
      _error = null;
      _loadCurrent();
    }
  }

  bool _valid(int generation) =>
      mounted && !_cancelled && generation == _generation;
  Future<void> _loadCurrent() async {
    final generation = _generation;
    try {
      final current = await widget.port.current(widget.ownerId);
      if (_valid(generation)) setState(() => _current = current);
    } catch (_) {/* 仍保留撤销入口，损坏/失效摘要不冒充正常摘要展示。 */}
  }

  @override
  void dispose() {
    _cancelled = true;
    _text.dispose();
    super.dispose();
  }

  String _errorText(Object error) => error is ContextCompactionException
      ? error.message
      : '整理或保存失败，请检查模型/网络后重试。确认前原话题不会改变。';

  Future<void> _prepare() async {
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _error = null;
      _progress = '正在读取原始聊天…';
    });
    try {
      final draft = await widget.port.prepare(widget.ownerId,
          isCancelled: () => !_valid(generation),
          onProgress: (done, total) {
            if (_valid(generation)) {
              setState(() => _progress = '整理内容 $done / $total');
            }
          });
      if (!_valid(generation)) return;
      setState(() {
        _draft = draft;
        _text.text = draft.summary;
      });
    } catch (error) {
      if (_valid(generation)) setState(() => _error = _errorText(error));
    } finally {
      if (_valid(generation)) setState(() => _busy = false);
    }
  }

  Future<void> _commit() async {
    final draft = _draft;
    if (draft == null) return;
    final generation = _generation;
    setState(() {
      _busy = true;
      _committing = true;
      _error = null;
      _progress = '正在保存内容交接…';
    });
    try {
      await widget.port.commit(draft, _text.text);
      if (mounted && _valid(generation)) {
        Navigator.of(context).pop('已保留内容，新话题将使用最新角色卡。');
      }
    } catch (error) {
      if (_valid(generation)) setState(() => _error = _errorText(error));
    } finally {
      if (_valid(generation)) {
        setState(() {
          _busy = false;
          _committing = false;
        });
      }
    }
  }

  Future<void> _undo() async {
    final generation = _generation;
    final owner = widget.ownerId;
    final port = widget.port;
    final accepted = await showMeoTalkDialog(
        context: context,
        title: '撤销上次压缩',
        content: const Text('恢复上次压缩前的对话，聊天记录不会删除。'),
        confirmText: '恢复上下文');
    if (accepted != true || !_valid(generation)) return;
    setState(() {
      _busy = true;
      _committing = true;
      _error = null;
      _progress = '正在恢复…';
    });
    try {
      await port.undo(owner);
      if (mounted && _valid(generation)) {
        Navigator.of(context).pop('已恢复上次压缩前的上下文；长期记忆未撤回。');
      }
    } catch (error) {
      if (_valid(generation)) setState(() => _error = _errorText(error));
    } finally {
      if (_valid(generation)) {
        setState(() {
          _busy = false;
          _committing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final maxHeight = (MediaQuery.sizeOf(context).height -
            MediaQuery.viewInsetsOf(context).bottom -
            240)
        .clamp(80.0, 500.0);
    return PopScope(
      canPop: !_committing,
      child: Center(
          child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: MeoTalkDialog(
          title: _draft == null ? '压缩并开启新话题' : '确认保留的内容',
          cancelText: _busy ? '取消整理' : '取消',
          showCancelButton: !_committing,
          onCancel: () {
            _cancelled = true;
            Navigator.of(context).pop();
          },
          confirmText: _draft == null ? '整理内容' : '保存并开启',
          onConfirm: _busy ? null : (_draft == null ? _prepare : _commit),
          content: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: SingleChildScrollView(
                child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('把前面的对话整理成摘要，聊天记录不会删除。'),
                const SizedBox(height: 12),
                if (_busy) ...[
                  Text(_progress),
                  const LinearProgressIndicator()
                ],
                if (_draft != null && !_busy) ...[
                  MoeTextField(
                      controller: _text,
                      minLines: 4,
                      maxLines: 8,
                      label: '新话题内容摘要（可修改）'),
                  const Text('确认后将整理进长期记忆。'),
                  TextButton(
                      onPressed: _prepare, child: const Text('重新整理（保留原话题）')),
                ],
                if (_draft == null && !_busy) ...[
                  if (_current != null)
                    Text('上次内容摘要：\n${_current!.summary}',
                        maxLines: 4, overflow: TextOverflow.ellipsis),
                  TextButton(
                      onPressed: _undo, child: const Text('撤销上次压缩')),
                ],
                if (_error != null)
                  Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(_error!,
                          style: TextStyle(color: context.moeColors.text))),
              ],
            )),
          ),
        ),
      )),
    );
  }
}
