import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/plugins/prompts/prompt_pack.dart';
import '../../../../features/plugins/prompts/prompt_pack_store.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';

/// What editing a preset's own section returns to the preset editor.
class PromptSectionEdit {
  const PromptSectionEdit.saved(PromptSection this.section) : deleted = false;
  const PromptSectionEdit.deleted() : section = null, deleted = true;

  final PromptSection? section;
  final bool deleted;
}

/// Edits one prompt section (ADR0092). A pack section saves to the shared
/// pack as you type; a preset's own section is handed back on leaving.
class PromptSectionEditorPage extends ConsumerStatefulWidget {
  const PromptSectionEditorPage.pack({
    super.key,
    required this.pluginId,
    required String this.packId,
    required String this.sectionId,
  }) : section = null,
       isNew = false;

  const PromptSectionEditorPage.own({
    super.key,
    required this.pluginId,
    required PromptSection this.section,
    this.isNew = false,
  }) : packId = null,
       sectionId = null;

  final String pluginId;
  final String? packId;
  final String? sectionId;
  final PromptSection? section;
  final bool isNew;

  bool get isOwn => packId == null;

  @override
  ConsumerState<PromptSectionEditorPage> createState() =>
      _PromptSectionEditorPageState();
}

class _PromptSectionEditorPageState
    extends ConsumerState<PromptSectionEditorPage>
    with MoeAutoSaveState<PromptSectionEditorPage> {
  final _title = TextEditingController();
  final _text = TextEditingController();
  PromptSection? _section;
  Object? _error;

  @override
  void initState() {
    super.initState();
    if (widget.isOwn) {
      _load(widget.section!);
    } else {
      ref.read(promptPackProvider.future).then((state) {
        if (!mounted) return;
        final section = state.library
            .require(widget.packId!)
            .section(widget.sectionId!);
        if (section == null) {
          setState(() => _error = '这一节已不存在');
          return;
        }
        _load(section);
        autoSave.configure(
          save: _savePackSection,
          snapshot: () => moeAutoSaveSignature([_title.text, _text.text]),
          fields: [_title, _text],
        );
      }, onError: (Object e) => mounted ? setState(() => _error = e) : null);
    }
  }

  void _load(PromptSection section) {
    _title.text = section.title;
    _text.text = section.text;
    setState(() => _section = section);
  }

  bool get _titleEditable =>
      widget.isOwn ||
      ref
          .read(promptPackProvider)
          .valueOrNull
          ?.library
          .isUserSection(widget.packId!, widget.sectionId!) ==
      true ||
      ref
          .read(promptPackProvider)
          .valueOrNull
          ?.library
          .builtin(widget.packId!) ==
      null;

  Future<void> _savePackSection() =>
      ref.read(promptPackProvider.notifier).editSection(
        widget.packId!,
        widget.sectionId!,
        text: _text.text,
        title: _titleEditable ? _title.text.trim() : null,
      );

  PromptSection get _ownDraft => _section!.copyWith(
    title: _title.text.trim(),
    text: _text.text,
  );

  Future<void> _restore() async {
    await autoSave.flush();
    await ref
        .read(promptPackProvider.notifier)
        .restoreSection(widget.packId!, widget.sectionId!);
    final library = (await ref.read(promptPackProvider.future)).library;
    final section = library.require(widget.packId!).section(widget.sectionId!);
    if (section != null && mounted) {
      autoSave.configure(
        save: _savePackSection,
        snapshot: () => moeAutoSaveSignature([_title.text, _text.text]),
        fields: [_title, _text],
      );
      _load(section);
    }
  }

  Future<void> _delete() async {
    final ok = await showMeoTalkConfirm(
      context: context,
      title: '删除这一节？',
      message: '删除后不会再发给模型。',
      confirmText: '删除',
    );
    if (ok != true || !mounted) return;
    if (widget.isOwn) {
      Navigator.pop(context, const PromptSectionEdit.deleted());
      return;
    }
    try {
      await ref
          .read(promptPackProvider.notifier)
          .removeSection(widget.packId!, widget.sectionId!);
      autoSave.configure(save: () async {}, snapshot: () => null);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) MoeToast.error(context, '删除失败：$e');
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final library = ref.watch(promptPackProvider).valueOrNull?.library;
    final modified =
        !widget.isOwn &&
        (library?.isModified(widget.packId!, widget.sectionId!) ?? false);
    final deletable =
        widget.isOwn ||
        (library != null &&
            (library.builtin(widget.packId!) == null ||
                library.isUserSection(widget.packId!, widget.sectionId!)));
    final variables = PromptVariables.byPlugin[widget.pluginId] ?? const {};
    final body = _error != null
        ? MoeEmptyState(
            icon: Icons.error_outline,
            title: '读取失败',
            description: '$_error',
          )
        : _section == null
        ? const Center(child: MoeLoadingIndicator())
        : Builder(
            builder: (context) => ListView(
              padding: moeUnderBarPadding(
                context,
                const EdgeInsets.fromLTRB(16, 12, 16, 24),
              ),
              children: [
                Text(
                  widget.isOwn
                      ? '只属于这个预设，随预设保存。'
                      : '属于共享的提示词包，改动立即保存，用这个包的预设都会生效。',
                  style: TextStyle(fontSize: 12, color: colors.textSecondary),
                ),
                const SizedBox(height: 12),
                if (_titleEditable) ...[
                  MoeTextField(controller: _title, label: '标题'),
                  const SizedBox(height: 12),
                ],
                MoeTextField(
                  controller: _text,
                  label: '正文',
                  minLines: 10,
                  maxLines: 24,
                  keyboardType: TextInputType.multiline,
                ),
                if (variables.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    '可用变量：${variables.entries.map((e) => '{${e.key}} ${e.value}').join('；')}。其它花括号原样保留。',
                    style: TextStyle(fontSize: 12, color: colors.muted),
                  ),
                ],
                const SizedBox(height: 20),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (modified)
                      MoeSecondaryButton(
                        label: '恢复默认',
                        size: MoeSecondaryButtonSize.sm,
                        onPressed: _restore,
                      ),
                    if (deletable && !widget.isNew)
                      MoeSecondaryButton(
                        label: '删除这一节',
                        size: MoeSecondaryButtonSize.sm,
                        foregroundColor: Theme.of(context).colorScheme.error,
                        onPressed: _delete,
                      ),
                  ],
                ),
              ],
            ),
          );
    final scaffold = MoePageScaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: colors.surface,
      appBar: MoeAppBar(
        title: widget.isNew ? '新建一节' : '编辑提示词',
        showBackButton: true,
      ),
      body: body,
    );
    if (!widget.isOwn) return autoSavePage(scaffold);
    // A preset's own section goes back to the preset editor, which saves it.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || _section == null) {
          if (!didPop) Navigator.pop(context);
          return;
        }
        Navigator.pop(context, PromptSectionEdit.saved(_ownDraft));
      },
      child: scaffold,
    );
  }
}
