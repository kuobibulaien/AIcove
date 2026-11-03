import 'dart:async';

import 'package:aicove_flutter/src/ui/shared/animations/parallax_slide_page_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/memory/application/memory_keeper_service.dart';
import '../../../../features/memory/data/background_memory_agent_adapter.dart';
import '../../../../features/memory/domain/memory_item.dart';
import '../../../../features/memory/providers/memory_providers.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/theme/tokens.dart';

/// 角色的长期记忆（ADR0038）：核心印象与往事日记两栏，全文展示，可编辑、锁定、删除、从聊天记录重建。
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
      content: const Text('删除后聊天时不再带上它，原始聊天记录不会删除。'),
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
        '将按 ${estimate.batches} 个聊天轮次重新整理 ${estimate.messages} 条消息，生成核心印象与往事日记。\n'
        '未锁定的记忆会被替换，已锁定的记忆保留。',
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
            '# ${widget.displayName}的记忆\n\n## 核心印象\n${section(MemoryLayer.core)}\n\n## 往事日记\n${section(MemoryLayer.archive)}\n',
      ),
    );
    if (mounted) MoeToast.success(context, '已复制全部记忆');
  }

  String _status(MemoryKeeperService keeper) {
    final progress = _progress;
    if (!_allowed) return '该角色未在插件列表里启用「记忆库」，不会整理或使用长期记忆。';
    if (keeper.isRunning(widget.ownerId)) return '正在按聊天轮次整理，还剩 $_pending 条消息。';
    if (progress?.paused == true) return '已暂停，还剩 $_pending 条消息待整理。';
    if (progress?.lastError != null && _pending > 0) {
      return '上次整理失败（${progress!.lastError}），点「继续整理」可重试。';
    }
    if (_pending > 0) return '还有 $_pending 条超过 24 小时的聊天待整理为日记。';
    return '已是最新。聊完满一天后，会在后台按轮次自动整理成日记。';
  }

  Widget _memoryCard(
    BuildContext context,
    MemoryItem item, {
    required bool showDivider,
  }) {
    final colors = context.moeColors;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => _edit(item: item),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Text(
                        item.title,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: MoeFontWeights.emphasis,
                          color: colors.text,
                          height: 1.35,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    MoeIconButton(
                      icon: item.locked ? Icons.lock : Icons.lock_open_outlined,
                      semanticLabel: item.locked
                          ? '解锁${item.title}'
                          : '锁定${item.title}',
                      onTap: () => _toggleLock(item),
                    ),
                    MoeIconButton(
                      icon: Icons.delete_outline,
                      semanticLabel: '删除${item.title}',
                      onTap: () => _delete(item),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  item.content,
                  style: TextStyle(
                    fontSize: 14,
                    color: colors.textSecondary,
                    height: 1.55,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (showDivider)
          Divider(height: 0.5, thickness: 0.5, color: colors.divider),
      ],
    );
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
                          subtitle: '按聊天轮次重新整理全部聊天记录',
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
                    const SizedBox(height: 20),
                    MoeSettingsGroup(
                      title: '核心印象（${core.length}）',
                      margin: EdgeInsets.zero,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                          child: Text(
                            '每次聊天都会带上，比如你的称呼、偏好与你们的相处方式。',
                            style: TextStyle(
                              fontSize: 12,
                              color: colors.muted,
                              height: 1.4,
                            ),
                          ),
                        ),
                        Divider(
                          height: 0.5,
                          thickness: 0.5,
                          color: colors.divider,
                        ),
                        if (core.isEmpty)
                          const Padding(
                            padding: MoeSettingsLayout.contentPadding,
                            child: Text('暂无核心印象'),
                          ),
                        for (var i = 0; i < core.length; i++)
                          _memoryCard(
                            context,
                            core[i],
                            showDivider: i < core.length - 1,
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    MoeSecondaryButton(
                      label: '添加核心印象',
                      onPressed: () => _edit(layer: MemoryLayer.core),
                    ),
                    const SizedBox(height: 20),
                    MoeSettingsGroup(
                      title: '往事日记（${archive.length}）',
                      margin: EdgeInsets.zero,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                          child: Text(
                            '按每次聊天记录下的日常与回忆，聊到相关话题时会自动想起。',
                            style: TextStyle(
                              fontSize: 12,
                              color: colors.muted,
                              height: 1.4,
                            ),
                          ),
                        ),
                        Divider(
                          height: 0.5,
                          thickness: 0.5,
                          color: colors.divider,
                        ),
                        if (archive.isEmpty)
                          const Padding(
                            padding: MoeSettingsLayout.contentPadding,
                            child: Text('暂无往事日记'),
                          ),
                        for (var i = 0; i < archive.length; i++)
                          _memoryCard(
                            context,
                            archive[i],
                            showDivider: i < archive.length - 1,
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    MoeSecondaryButton(
                      label: '添加往事日记',
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
  Widget build(BuildContext context) {
    final today = formatMemoryRoundDate(DateTime.now());
    return MoePageScaffold(
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
                    label: '放进核心印象',
                    subtitle: '每次聊天都会带上；关闭则存为往事日记，按话题自动想起',
                    trailingType: MoeSettingsRowTrailing.switchControl,
                    switchValue: _layer == MemoryLayer.core,
                    onSwitchChanged: (value) => setState(
                      () => _layer = value
                          ? MemoryLayer.core
                          : MemoryLayer.archive,
                    ),
                    showDivider: false,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              MoeTextField(
                controller: _title,
                label: '标题',
                hint: _layer == MemoryLayer.archive
                    ? '例如：$today 一起去看海'
                    : '例如：称呼与日常喜好',
                maxLength: 120,
              ),
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
              MoePrimaryButton(label: '保存', onPressed: _saving ? null : _save),
            ],
          ),
        ),
      ),
    );
  }
}
