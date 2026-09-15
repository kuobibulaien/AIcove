import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/chat/conversation_providers.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';

class ChatShareSheet extends ConsumerStatefulWidget {
  const ChatShareSheet({
    super.key,
    required this.onExport,
    required this.onSend,
  });

  final VoidCallback onExport;
  final Future<void> Function(String conversationId, String note) onSend;

  @override
  ConsumerState<ChatShareSheet> createState() => _ChatShareSheetState();
}

class _ChatShareSheetState extends ConsumerState<ChatShareSheet> {
  final _note = TextEditingController();
  final _selected = <String>{};
  final _sent = <String>{};
  bool _sending = false;
  bool _noteOpen = false;
  String? _error;

  Future<void> _askForNote() async {
    if (_sending || _noteOpen || _selected.isEmpty) return;
    setState(() => _noteOpen = true);
    final confirmed = await showDialog<bool>(
      context: context,
      useRootNavigator: false,
      builder: (dialogContext) => Dialog(
        key: const ValueKey('share-note-dialog'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        child: MoeFloatingSurface(
          radius: 28,
          padding: const EdgeInsets.all(24),
          child: SizedBox(
            width: 360,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '附加留言',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: context.moeColors.text,
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _note,
                    autofocus: true,
                    textAlign: TextAlign.center,
                    textAlignVertical: TextAlignVertical.center,
                    decoration: const InputDecoration(
                      hintText: '写一句留言（可留空）',
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                    ),
                    minLines: 1,
                    maxLines: 4,
                  ),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Expanded(
                        child: MoeSecondaryButton(
                          label: '取消',
                          onPressed: () =>
                              Navigator.of(dialogContext).pop(false),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: MoePrimaryButton(
                          label: '发送',
                          onPressed: () =>
                              Navigator.of(dialogContext).pop(true),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (!mounted) return;
    setState(() => _noteOpen = false);
    if (confirmed == true) await _send(_note.text);
  }

  Future<void> _send(String note) async {
    if (_sending || _selected.isEmpty) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      for (final id in _selected.toList()) {
        await widget.onSend(id, note);
        _sent.add(id);
        _selected.remove(id);
        if (!mounted) return;
      }
      if (mounted) Navigator.of(context).pop('sent');
    } catch (_) {
      if (mounted) setState(() => _error = '部分联系人未发送成功，请重试；已发送的不会重复发送。');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final contacts = ref.watch(conversationsProvider);
    return PopScope(
      canPop: !_sending,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: contacts.when(
              loading: () => const SizedBox(
                height: 80,
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (_, __) => Center(
                heightFactor: 1,
                child: TextButton(
                  onPressed: () => ref.invalidate(conversationsProvider),
                  child: const Text('联系人加载失败，点击重试'),
                ),
              ),
              data: (items) {
                if (items.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.all(20),
                    child: Center(heightFactor: 1, child: Text('暂无联系人')),
                  );
                }
                return GridView.builder(
                  shrinkWrap: true,
                  primary: false,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 100,
                    mainAxisExtent:
                        62 + MediaQuery.textScalerOf(context).scale(14) * 1.5,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 12,
                  ),
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final contact = items[index];
                    final selected = _selected.contains(contact.id);
                    final sent = _sent.contains(contact.id);
                    return Semantics(
                      button: true,
                      selected: selected,
                      label: '${contact.displayName}${sent ? '，已发送' : ''}',
                      child: GestureDetector(
                        key: ValueKey('share-contact-${contact.id}'),
                        behavior: HitTestBehavior.opaque,
                        onTap: _sending || sent
                            ? null
                            : () => setState(() {
                                if (!_selected.remove(contact.id)) {
                                  _selected.add(contact.id);
                                }
                              }),
                        child: Column(
                          children: [
                            Stack(
                              children: [
                                MoeAvatar(
                                  name: contact.displayName,
                                  avatarUrl: contact.avatarUrl,
                                  characterImage: contact.characterImage,
                                  size: 56,
                                ),
                                if (selected || sent)
                                  Positioned(
                                    right: 0,
                                    bottom: 0,
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        color: context.moeColors.primary,
                                        shape: BoxShape.circle,
                                      ),
                                      child: const Padding(
                                        padding: EdgeInsets.all(3),
                                        child: Icon(
                                          Icons.check,
                                          color: Colors.white,
                                          size: 16,
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              contact.displayName,
                              style: const TextStyle(fontSize: 14, height: 1.5),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: Row(
              children: [
                Expanded(
                  child: MoeSecondaryButton(
                    label: '导出为图片',
                    enabled: !_sending && !_noteOpen,
                    onPressed: widget.onExport,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: MoePrimaryButton(
                    label: '直接分享',
                    enabled: _selected.isNotEmpty && !_sending && !_noteOpen,
                    isLoading: _sending,
                    onPressed: _askForNote,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
