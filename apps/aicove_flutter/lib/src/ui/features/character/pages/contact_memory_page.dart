import 'package:flutter/material.dart';
import 'package:aicove_flutter/src/ui/shared/animations/parallax_slide_page_route.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../../features/memory/domain/contact_memory_port.dart';
import '../../../../features/memory/providers/contact_memory_provider.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/theme/tokens.dart';
import '../widgets/character_text_editor_sheet.dart';

/// 仅操作显式 owner 的应用层端口；不从当前活动会话推断所属角色。
class ContactMemoryPage extends ConsumerStatefulWidget {
  const ContactMemoryPage(
      {super.key, required this.ownerId, required this.displayName});
  final String ownerId;
  final String displayName;

  @override
  ConsumerState<ContactMemoryPage> createState() => _ContactMemoryPageState();
}

class _ContactMemoryPageState extends ConsumerState<ContactMemoryPage>
    with MoeAutoSaveState<ContactMemoryPage> {
  ContactMemoryNotebook? _draft;
  String? _error;
  bool _busy = false;
  bool _conflicted = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant ContactMemoryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ownerId != widget.ownerId) {
      _generation++;
      _draft = null;
      _load();
    }
  }

  bool _isCurrent(int generation) => mounted && generation == _generation;

  Future<void> _load() async {
    final generation = _generation;
    final ownerId = widget.ownerId;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final notebook = await ref.read(contactMemoryPortProvider).load(ownerId);
      if (_isCurrent(generation)) {
        setState(() {
          _draft = notebook;
          _conflicted = false;
          autoSave.configure(save: _save, snapshot: _signature);
        });
      }
    } catch (_) {
      if (_isCurrent(generation)) setState(() => _error = '无法读取记忆文档；原文未覆盖。');
    } finally {
      if (_isCurrent(generation)) setState(() => _busy = false);
    }
  }

  String _signature() => moeAutoSaveSignature([
        _draft?.ownerId,
        _draft?.enabled,
        _draft?.core,
        for (final event in _draft?.events ?? <ContactMemoryEvent>[])
          [
            event.id,
            event.title,
            event.body,
            event.occurredAt.toIso8601String()
          ],
      ]);

  Future<void> _save() async {
    final generation = _generation;
    final draft = _draft;
    if (draft == null) throw const FormatException('请等待记忆加载完成');
    final ContactMemoryNotebook saved;
    try {
      saved = await ref.read(contactMemoryPortProvider).save(draft);
    } on ContactMemoryConflict {
      if (_isCurrent(generation)) _conflicted = true;
      throw const FormatException('自动保存失败：记忆已被其他操作更新，修改已保留。可重新加载最新记忆。');
    }
    if (_isCurrent(generation)) {
      _conflicted = false;
      // A newer edit may have arrived during the write; advance only its revision.
      _draft = _draft!.copyWith(revision: saved.revision);
    }
  }

  Future<void> _reload() async {
    if (_conflicted) {
      final reload = await showMeoTalkDialog(
        context: context,
        title: '重新加载最新记忆？',
        content: const Text('当前修改与其他操作发生冲突。重新加载会放弃本页尚未保存的修改。'),
        confirmText: '重新加载',
        cancelText: '继续编辑',
      );
      if (reload == true && mounted) await _load();
    } else if (await autoSave.flush() && mounted) {
      await _load();
    }
  }

  void _change(ContactMemoryNotebook next) {
    setState(() {
      _draft = next;
      _error = null;
    });
  }

  Future<void> _editCore() async {
    final draft = _draft!;
    final text = await showCharacterTextEditorSheet(
      context: context,
      title: '常驻记忆',
      initialValue: draft.core,
      onChanged: (text) {
        if (mounted && draft.ownerId == widget.ownerId) {
          _change(_draft!.copyWith(core: text));
        }
      },
      hint: '记录明确偏好、相处约定和正在进行的事。事件细节放进往事。',
    );
    if (text != null && mounted && draft.ownerId == widget.ownerId) {
      _change(_draft!.copyWith(core: text));
    }
  }

  Future<void> _editEvent([ContactMemoryEvent? event]) async {
    final generation = _generation;
    final updated = await Navigator.of(context)
        .push<ContactMemoryEvent>(ParallaxSlidePageRoute(
      page: _EventEditor(
          event: event,
          onChanged: (updated) async {
            if (!_isCurrent(generation)) return;
            _updateEvent(updated);
            if (!await autoSave.flush()) {
              throw autoSave.error ?? StateError('记忆保存失败');
            }
          }),
    ));
    if (updated == null || !_isCurrent(generation)) return;
    _updateEvent(updated);
  }

  void _updateEvent(ContactMemoryEvent updated) {
    final events = [..._draft!.events];
    final index = events.indexWhere((e) => e.id == updated.id);
    if (index < 0) {
      events.add(updated);
    } else {
      events[index] = updated;
    }
    _change(_draft!.copyWith(events: events));
  }

  Future<void> _forget(ContactMemoryEvent event) async {
    final generation = _generation;
    final confirmed = await showMeoTalkDialog(
      context: context,
      title: '从记忆文档移除这件往事？',
      content: const Text('保存后角色不能再通过记忆工具读取此项。不会删除原聊天，也不代表模型看不到近期聊天中的相同内容。'),
      confirmText: '移除',
      isDanger: true,
    );
    if (confirmed == true && _isCurrent(generation)) {
      _change(_draft!.copyWith(
          events: _draft!.events.where((e) => e.id != event.id).toList()));
    }
  }

  @override
  Widget build(BuildContext context) {
    final draft = _draft;
    final colors = context.moeColors;
    return autoSavePage(
      MoePageScaffold(
        backgroundColor: colors.surface,
        appBar: MoeAppBar(
          title: '${widget.displayName}的记忆',
          showBackButton: true,
          actions: [
            MoeIconButton(
              icon: Icons.refresh,
              semanticLabel: '重新加载记忆',
              enabled: !_busy,
              onTap: _reload,
            )
          ],
        ),
        body: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: draft == null && _busy
                ? const Center(child: MoeLoadingIndicator())
                : ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: Text(_error!,
                              style: TextStyle(color: colors.text)),
                        ),
                      if (draft != null) ...[
                        MoeSettingsGroup(margin: EdgeInsets.zero, children: [
                          MoeSettingsRow(
                            icon: Icons.description_outlined,
                            label: '使用独立 MD 记忆',
                            subtitle: '开启后停用该角色旧库的读取与自动写入；关闭可回到旧模式，旧库不删除。',
                            trailingType: MoeSettingsRowTrailing.switchControl,
                            switchValue: draft.enabled,
                            enabled: !_busy,
                            onSwitchChanged: (value) =>
                                _change(draft.copyWith(enabled: value)),
                            showDivider: false,
                          ),
                        ]),
                        const SizedBox(height: 12),
                        const Text(
                            '每个联系人独立一份 MEMORY.md，同名或同人设也不共享。聊天中仍需启用全局及该联系人的“长期记忆”插件。'),
                        const SizedBox(height: 8),
                        const Text(
                            '当前为手动维护版，尚不自动整理聊天。记忆存本机；用于聊天的片段会发送给当前模型服务。'),
                        const SizedBox(height: 20),
                        MoeSettingsGroup(
                            title: '常驻记忆',
                            margin: EdgeInsets.zero,
                            children: [
                              MoeSettingsRow(
                                icon: Icons.edit_note,
                                label: '编辑常驻笔记',
                                subtitle: '每轮直接带入；超出约 2000 tokens 时需把细节移到往事。',
                                enabled: !_busy,
                                onTap: _editCore,
                                showDivider: false,
                              ),
                            ]),
                        Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: SelectableText(
                                draft.core.isEmpty ? '暂无常驻记忆' : draft.core)),
                        MoeSecondaryButton(
                            label: '添加往事',
                            onPressed: _busy ? null : () => _editEvent()),
                        const SizedBox(height: 12),
                        for (final event in draft.events.reversed)
                          MoeListTile(
                            title: Text(event.title),
                            subtitle:
                                Text('${_date(event.occurredAt)} · 点击查看和编辑'),
                            enabled: !_busy,
                            onTap: () => _editEvent(event),
                            trailing: MoeIconButton(
                                icon: Icons.delete_outline,
                                semanticLabel: '移除${event.title}',
                                enabled: !_busy,
                                onTap: () => _forget(event)),
                          ),
                        const SizedBox(height: 20),
                      ],
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

String _date(DateTime value) => value.toIso8601String().split('T').first;

class _EventEditor extends StatefulWidget {
  const _EventEditor({this.event, required this.onChanged});
  final Future<void> Function(ContactMemoryEvent) onChanged;
  final ContactMemoryEvent? event;
  @override
  State<_EventEditor> createState() => _EventEditorState();
}

class _EventEditorState extends State<_EventEditor>
    with MoeAutoSaveState<_EventEditor> {
  late final _title = TextEditingController(text: widget.event?.title ?? '');
  late final _dateController = TextEditingController(
      text: _date(widget.event?.occurredAt ?? DateTime.now()));
  late final _body = TextEditingController(text: widget.event?.body ?? '');
  late final String _eventId = widget.event?.id ?? const Uuid().v4();
  @override
  void initState() {
    super.initState();
    autoSave.configure(
        save: _done,
        snapshot: () => moeAutoSaveSignature(
            [_title.text, _dateController.text, _body.text]),
        fields: [_title, _dateController, _body]);
  }

  @override
  void dispose() {
    _title.dispose();
    _dateController.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _done() async {
    final date = DateTime.tryParse(_dateController.text.trim());
    if (_title.text.trim().isEmpty ||
        _title.text.length > 120 ||
        _body.text.trim().isEmpty ||
        _body.text.length > 20000 ||
        date == null ||
        _date(date) != _dateController.text.trim()) {
      throw const FormatException(
          '请填写标题（最多120字）、正文（最多20000字）及有效日期 YYYY-MM-DD。');
    }
    await widget.onChanged(ContactMemoryEvent(
      id: _eventId,
      title: _title.text.trim(),
      body: _body.text.trim(),
      occurredAt: date,
    ));
  }

  @override
  Widget build(BuildContext context) => autoSavePage(MoePageScaffold(
        backgroundColor: context.moeColors.surface,
        appBar: const MoeAppBar(title: '编辑往事', showBackButton: true),
        body: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: ListView(padding: const EdgeInsets.all(16), children: [
                MoeTextField(controller: _title, label: '事件标题', maxLength: 120),
                const SizedBox(height: 12),
                MoeTextField(
                    controller: _dateController,
                    label: '发生日期',
                    hint: 'YYYY-MM-DD'),
                const SizedBox(height: 12),
                MoeTextField(
                    controller: _body,
                    label: '事件正文',
                    minLines: 8,
                    maxLines: 18,
                    maxLength: 20000),
                const SizedBox(height: 16),
              ]),
            )),
      ));
}
