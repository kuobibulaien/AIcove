import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../features/context/domain/context_summary.dart';
import '../../../../features/context/providers/context_providers.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';

class TopicCompactionButton extends ConsumerStatefulWidget {
  const TopicCompactionButton(
      {super.key, required this.ownerId, required this.isGenerating});
  final String ownerId;
  final bool isGenerating;
  @override
  ConsumerState<TopicCompactionButton> createState() =>
      _TopicCompactionButtonState();
}

class _TopicCompactionButtonState extends ConsumerState<TopicCompactionButton> {
  bool _open = false;
  @override
  Widget build(BuildContext context) => IconButton(
        icon: Icon(Icons.edit_note_rounded,
            color: context.moeColors.headerContentColor),
        tooltip: '压缩并开启新话题',
        onPressed: widget.isGenerating || _open
            ? null
            : () async {
                final owner = widget.ownerId;
                setState(() => _open = true);
                try {
                  final result = await showDialog<String>(
                      context: context,
                      barrierDismissible: false,
                      builder: (_) => TopicCompactionDialog(
                          ownerId: owner,
                          port: ref.read(manualCompactionProvider)));
                  if (context.mounted &&
                      widget.ownerId == owner &&
                      result != null) {
                    MoeToast.info(context, result);
                  }
                } finally {
                  if (mounted) setState(() => _open = false);
                }
              },
      );
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
        content: const Text(
            '恢复压缩前的上下文边界，聊天记录不会删除。已经整理进长期记忆的内容不会撤回；恢复旧消息后也可能恢复旧格式的影响。'),
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
                const Text('保留事实、经历与约定，不沿用旧回复格式。新话题按最新角色卡表达，原聊天记录不会删除。'),
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
                  const Text('请检查摘要，删掉不想保留的内容。保存后，该角色若启用了记忆库，会在后台把这段对话整理进长期记忆。'),
                  TextButton(
                      onPressed: _prepare, child: const Text('重新整理（保留原话题）')),
                ],
                if (_draft == null && !_busy) ...[
                  const Text(
                      '整理会使用配置的压缩模型，未配置时使用默认聊天模型；会产生一次或多次模型调用。确认摘要后才切换。'),
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
