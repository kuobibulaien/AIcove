/// 编辑酒馆预设里的一条普通提示词：名称、消息角色和正文，改动自动保存回预设。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/agent_context/domain/silly_tavern_preset.dart';
import '../../../../features/agent_context/domain/tavern_compatibility_port.dart';
import '../../../../features/agent_context/providers/preset_recipe_provider.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';

class TavernPromptEditorPage extends ConsumerStatefulWidget {
  /// 修改已有条目。
  const TavernPromptEditorPage({
    super.key,
    required this.presetId,
    required SillyTavernPrompt this.prompt,
  });

  /// 新建条目：第一次保存时才写入预设，什么都不填直接返回不会留下空条目。
  const TavernPromptEditorPage.create({super.key, required this.presetId})
    : prompt = null;

  final String presetId;
  final SillyTavernPrompt? prompt;

  @override
  ConsumerState<TavernPromptEditorPage> createState() =>
      _TavernPromptEditorPageState();
}

class _TavernPromptEditorPageState extends ConsumerState<TavernPromptEditorPage>
    with MoeAutoSaveState<TavernPromptEditorPage> {
  final _name = TextEditingController();
  final _content = TextEditingController();
  late final String _identifier;
  String _role = 'system';

  @override
  void initState() {
    super.initState();
    final prompt = widget.prompt;
    _identifier =
        prompt?.identifier ??
        '$kUserPromptIdPrefix${DateTime.now().microsecondsSinceEpoch}';
    if (prompt != null) {
      _name.text = prompt.name;
      _content.text = prompt.content;
      _role = prompt.role;
    }
    _configureAutoSave();
  }

  void _configureAutoSave() => autoSave.configure(
    save: _save,
    snapshot: () => moeAutoSaveSignature([_name.text, _role, _content.text]),
    fields: [_name, _content],
  );

  bool get _deletable =>
      widget.prompt?.identifier.startsWith(kUserPromptIdPrefix) ?? false;

  Future<void> _delete() async {
    final ok = await showMeoTalkConfirm(
      context: context,
      title: '删除这条提示词？',
      message: '删除后不会再发给模型，无法恢复。',
      confirmText: '删除',
      isDanger: true,
    );
    if (ok != true || !mounted) return;
    // 先停掉自动保存，免得返回时补存又把条目写回去。
    autoSave.configure(save: () async {}, snapshot: () => null);
    try {
      await ref
          .read(presetRecipeImportControllerProvider.notifier)
          .change(
            widget.presetId,
            (port) => port.deletePrompt(widget.presetId, _identifier),
          );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      _configureAutoSave();
      if (mounted) MoeToast.error(context, '删除失败：$e');
    }
  }

  Future<void> _save() {
    final name = _name.text.trim();
    return ref
        .read(presetRecipeImportControllerProvider.notifier)
        .change(
          widget.presetId,
          (port) => port.savePrompt(
            widget.presetId,
            identifier: _identifier,
            name: name.isEmpty ? '未命名提示词' : name,
            role: _role,
            content: _content.text,
          ),
        );
  }

  @override
  void dispose() {
    _name.dispose();
    _content.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    return autoSavePage(
      MoePageScaffold(
        extendBodyBehindAppBar: true,
        backgroundColor: colors.surface,
        appBar: MoeAppBar(
          title: widget.prompt == null ? '添加提示词' : '编辑提示词',
          showBackButton: true,
        ),
        body: Builder(
          builder: (context) => ListView(
            padding: moeUnderBarPadding(
              context,
              const EdgeInsets.fromLTRB(16, 12, 16, 24),
            ),
            children: [
              Text(
                '改动自动保存到这套预设。新条目排在聊天记录之前，默认开启。',
                style: TextStyle(fontSize: 12, color: colors.textSecondary),
              ),
              const SizedBox(height: 12),
              MoeTextField(controller: _name, label: '名称', hint: '未命名提示词'),
              const SizedBox(height: 12),
              Text(
                '以谁的身份发送',
                style: TextStyle(fontSize: 13, color: colors.muted),
              ),
              const SizedBox(height: 6),
              MoeSegmentedControl<String>(
                value: _role,
                segments: const [
                  MoeSegment(value: 'system', label: '系统'),
                  MoeSegment(value: 'user', label: '用户'),
                  MoeSegment(value: 'assistant', label: 'AI'),
                ],
                onChanged: (v) => setState(() => _role = v),
              ),
              const SizedBox(height: 12),
              MoeTextField(
                controller: _content,
                label: '正文',
                minLines: 10,
                maxLines: 24,
                keyboardType: TextInputType.multiline,
              ),
              if (_deletable) ...[
                const SizedBox(height: 20),
                Align(
                  alignment: Alignment.centerLeft,
                  child: MoeSecondaryButton(
                    label: '删除这条提示词',
                    size: MoeSecondaryButtonSize.sm,
                    foregroundColor: Theme.of(context).colorScheme.error,
                    onPressed: _delete,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
