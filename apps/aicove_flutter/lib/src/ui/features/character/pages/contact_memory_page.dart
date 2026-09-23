import 'dart:async';

import 'package:aicove_flutter/src/ui/shared/animations/parallax_slide_page_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/memory/application/memory_keeper_service.dart';
import '../../../../features/memory/domain/memory_item.dart';
import '../../../../features/memory/providers/memory_providers.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/theme/tokens.dart';

/// 角色的长期记忆（ADR0038）：常驻与档案两栏，可编辑、锁定、删除、从聊天记录重建。
/// 只操作显式传入的 owner，不从当前活动会话推断所属角色。
class ContactMemoryPage extends ConsumerStatefulWidget {
  const ContactMemoryPage({
    super.key,
    required this.ownerId,
    required this.displayName,
  });
  final String ownerId;
  final String displayName;

  @override
  ConsumerState<ContactMemoryPage> createState() => _ContactMemoryPageState();
}

class _ContactMemoryPageState extends ConsumerState<ContactMemoryPage> {
  List<MemoryItem> _items = const [];
  MemoryProgress? _progress;
  int _pending = 0;
  bool _loading = true;
  bool _allowed = true;
  String? _error;
  int _generation = 0;
  StreamSubscription<String>? _changes;

  @override
  void initState() {
    super.initState();
    _changes = ref.read(memoryKeeperProvider).changes.listen((owner) {
      if (owner == widget.ownerId) _load();
    });
    _load();
  }

  @override
  void didUpdateWidget(covariant ContactMemoryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ownerId != widget.ownerId) {
      _generation++;
      _items = const [];
      _load();
    }
  }

  @override
  void dispose() {
    _changes?.cancel();
    super.dispose();
  }

  bool _isCurrent(int generation) => mounted && generation == _generation;

  Future<void> _load() async {
    final generation = _generation;
    final owner = widget.ownerId;
    try {
      final store = ref.read(memoryStoreProvider);
      final keeper = ref.read(memoryKeeperProvider);
      final items = await store.list(owner);
      final progress = await store.progress(owner);
      final pending = (await keeper.pendingMessages(owner)).length;
      final allowed = await keeper.allowed(owner);
      if (!_isCurrent(generation)) return;
      setState(() {
        _items = items;
        _progress = progress;
        _pending = pending;
        _allowed = allowed;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (_isCurrent(generation)) {
        setState(() {
          _loading = false;
          _error = '读取记忆失败：$error';
        });
      }
    }
  }

  Future<void> _edit({MemoryItem? item, MemoryLayer? layer}) async {
    final saved = await Navigator.of(context).push<bool>(
      ParallaxSlidePageRoute(
        page: _MemoryEditor(
          ownerId: widget.ownerId,
          item: item,
          layer: item?.layer ?? layer ?? MemoryLayer.archive,
        ),
      ),
    );
    if (saved == true) await _load();
  }

  Future<void> _delete(MemoryItem item) async {
    final confirmed = await showMeoTalkDialog(
      context: context,
      title: '删除这条记忆？',
      content: const Text('删除后聊天时不再带上它。原始聊天不会删除；以后压缩或重建时，模型仍可能从聊天里重新记起相同的事。'),
      confirmText: '删除',
      isDanger: true,
    );
    if (confirmed != true || !mounted) return;
    await ref.read(memoryStoreProvider).deleteByUser(widget.ownerId, item.id);
    await _load();
  }

  Future<void> _toggleLock(MemoryItem item) async {
    await ref
        .read(memoryStoreProvider)
        .setLocked(widget.ownerId, item.id, !item.locked);
    await _load();
  }

  Future<void> _rebuild() async {
    final keeper = ref.read(memoryKeeperProvider);
    MemoryRebuildEstimate estimate;
    try {
      estimate = await keeper.estimateRebuild(widget.ownerId);
    } catch (error) {
      if (mounted) MoeToast.error(context, '无法估算：$error');
      return;
    }
    if (!mounted) return;
    final confirmed = await showMeoTalkDialog(
      context: context,
      title: '从聊天记录重建记忆？',
      content: Text(
        '会把 ${estimate.messages} 条聊天（约 ${(estimate.inputTokens / 1000).toStringAsFixed(1)}k tokens）'
        '分 ${estimate.batches} 批交给记忆模型重新整理，费用与聊天量成正比。\n'
        '开始前会删除所有未锁定的记忆；你锁定的记忆保留。可以随时暂停，之后接着跑。',
      ),
      confirmText: '开始重建',
      isDanger: true,
    );
    if (confirmed != true || !mounted) return;
    try {
      await keeper.startRebuild(widget.ownerId);
    } catch (error) {
      if (mounted) MoeToast.error(context, '$error');
    }
    await _load();
  }

  Future<void> _copyAll() async {
    String section(MemoryLayer layer) => _items
        .where((i) => i.layer == layer)
        .map((i) => '- **${i.title}**：${i.content}')
        .join('\n');
    await Clipboard.setData(
      ClipboardData(
        text:
            '# ${widget.displayName}的记忆\n\n## 常驻\n${section(MemoryLayer.core)}\n\n## 档案\n${section(MemoryLayer.archive)}\n',
      ),
    );
    if (mounted) MoeToast.success(context, '已复制全部记忆');
  }

  String _status(MemoryKeeperService keeper) {
    final progress = _progress;
    if (!_allowed) return '该角色未在插件列表里启用「记忆库」，不会整理或使用长期记忆。';
    if (keeper.isRunning(widget.ownerId)) return '正在整理，还剩 $_pending 条聊天。';
    if (progress?.paused == true) return '已暂停，还剩 $_pending 条聊天待整理。';
    if (progress?.lastError != null && _pending > 0) {
      return '上次整理失败（${progress!.lastError}），下次压缩或点「继续」时重试。';
    }
    if (_pending > 0) return '还有 $_pending 条已压缩的聊天待整理。';
    return '已是最新。每次压缩后会在后台自动整理。';
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final keeper = ref.watch(memoryKeeperProvider);
    final running = keeper.isRunning(widget.ownerId);
    final paused = _progress?.paused == true;
    final core = _items.where((i) => i.layer == MemoryLayer.core).toList();
    final archive = _items
        .where((i) => i.layer == MemoryLayer.archive)
        .toList();

    Widget tile(MemoryItem item) => MoeListTile(
      title: Text(item.title),
      subtitle: Text(
        item.content,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: () => _edit(item: item),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          MoeIconButton(
            icon: item.locked ? Icons.lock : Icons.lock_open_outlined,
            semanticLabel: item.locked ? '解锁${item.title}' : '锁定${item.title}',
            onTap: () => _toggleLock(item),
          ),
          MoeIconButton(
            icon: Icons.delete_outline,
            semanticLabel: '删除${item.title}',
            onTap: () => _delete(item),
          ),
        ],
      ),
    );

    return MoePageScaffold(
      backgroundColor: colors.surface,
      appBar: MoeAppBar(
        title: '${widget.displayName}的记忆',
        showBackButton: true,
        actions: [
          MoeIconButton(
            icon: Icons.copy_all_outlined,
            semanticLabel: '复制全部记忆',
            enabled: _items.isNotEmpty,
            onTap: _copyAll,
          ),
        ],
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: _loading
              ? const Center(child: MoeLoadingIndicator())
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(
                          _error!,
                          style: TextStyle(color: colors.text),
                        ),
                      ),
                    MoeSettingsGroup(
                      title: '整理状态',
                      margin: EdgeInsets.zero,
                      children: [
                        Padding(
                          padding: MoeSettingsLayout.contentPadding,
                          child: Text(_status(keeper)),
                        ),
                        MoeSettingsRow(
                          icon: Icons.history,
                          label: '从聊天记录重建',
                          subtitle: '把全部聊天重新整理一遍（会产生模型费用）',
                          enabled: _allowed && !running,
                          onTap: _rebuild,
                        ),
                        MoeSettingsRow(
                          icon: paused || !running
                              ? Icons.play_arrow_rounded
                              : Icons.pause_rounded,
                          label: paused || !running ? '继续整理' : '暂停整理',
                          enabled: _allowed && (running || _pending > 0),
                          showDivider: false,
                          onTap: () async {
                            if (running && !paused) {
                              await keeper.pause(widget.ownerId);
                            } else {
                              await keeper.resume(widget.ownerId);
                            }
                            await _load();
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      '记忆存在本机，暂不随云同步；需要备份时可用右上角「复制全部记忆」。'
                      '聊天时带上的记忆会发送给当前模型服务。锁定的记忆不会被自动整理修改。',
                    ),
                    const SizedBox(height: 20),
                    MoeSettingsGroup(
                      title: '常驻（每轮都带，约 2000 tokens 以内）',
                      margin: EdgeInsets.zero,
                      children: [
                        if (core.isEmpty)
                          const Padding(
                            padding: MoeSettingsLayout.contentPadding,
                            child: Text('暂无常驻记忆'),
                          ),
                        ...core.map(tile),
                      ],
                    ),
                    const SizedBox(height: 8),
                    MoeSecondaryButton(
                      label: '添加常驻记忆',
                      onPressed: () => _edit(layer: MemoryLayer.core),
                    ),
                    const SizedBox(height: 20),
                    MoeSettingsGroup(
                      title: '档案（按当前话题检索后带上）',
                      margin: EdgeInsets.zero,
                      children: [
                        if (archive.isEmpty)
                          const Padding(
                            padding: MoeSettingsLayout.contentPadding,
                            child: Text('暂无档案记忆'),
                          ),
                        ...archive.map(tile),
                      ],
                    ),
                    const SizedBox(height: 8),
                    MoeSecondaryButton(
                      label: '添加档案记忆',
                      onPressed: () => _edit(layer: MemoryLayer.archive),
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
        ),
      ),
    );
  }
}

/// 编辑或新增一条记忆；保存后自动锁定。
class _MemoryEditor extends ConsumerStatefulWidget {
  const _MemoryEditor({required this.ownerId, required this.layer, this.item});
  final String ownerId;
  final MemoryLayer layer;
  final MemoryItem? item;

  @override
  ConsumerState<_MemoryEditor> createState() => _MemoryEditorState();
}

class _MemoryEditorState extends ConsumerState<_MemoryEditor> {
  late final _title = TextEditingController(text: widget.item?.title ?? '');
  late final _content = TextEditingController(text: widget.item?.content ?? '');
  late MemoryLayer _layer = widget.layer;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    _content.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref
          .read(memoryStoreProvider)
          .saveByUser(
            ownerId: widget.ownerId,
            id: widget.item?.id,
            layer: _layer,
            title: _title.text,
            content: _content.text,
          );
      if (mounted) Navigator.of(context).pop(true);
    } on MemoryException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => MoePageScaffold(
    backgroundColor: context.moeColors.surface,
    appBar: MoeAppBar(
      title: widget.item == null ? '添加记忆' : '编辑记忆',
      showBackButton: true,
    ),
    body: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            MoeSettingsGroup(
              margin: EdgeInsets.zero,
              children: [
                MoeSettingsRow(
                  icon: Icons.push_pin_outlined,
                  label: '常驻',
                  subtitle: '开启后每轮都带；关闭则存进档案，按话题检索',
                  trailingType: MoeSettingsRowTrailing.switchControl,
                  switchValue: _layer == MemoryLayer.core,
                  onSwitchChanged: (value) => setState(
                    () =>
                        _layer = value ? MemoryLayer.core : MemoryLayer.archive,
                  ),
                  showDivider: false,
                ),
              ],
            ),
            const SizedBox(height: 12),
            MoeTextField(controller: _title, label: '标题', maxLength: 120),
            const SizedBox(height: 12),
            MoeTextField(
              controller: _content,
              label: '内容',
              minLines: 6,
              maxLines: 14,
              maxLength: 4000,
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: context.moeColors.text)),
            ],
            const SizedBox(height: 16),
            const Text('保存后这条记忆会被锁定，自动整理不会再修改或删除它。'),
            const SizedBox(height: 16),
            MoePrimaryButton(label: '保存', onPressed: _saving ? null : _save),
          ],
        ),
      ),
    ),
  );
}
