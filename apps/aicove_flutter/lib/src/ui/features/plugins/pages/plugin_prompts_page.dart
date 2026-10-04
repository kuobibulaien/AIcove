import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/plugins/prompts/plugin_prompts.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/theme/tokens.dart';

/// 工具提示词：编辑所有角色共用的插件标签说明，自动保存。
class PluginPromptsPage extends ConsumerStatefulWidget {
  const PluginPromptsPage({super.key});

  static const title = '工具提示词';

  @override
  ConsumerState<PluginPromptsPage> createState() => _PluginPromptsPageState();
}

class _PluginPromptsPageState extends ConsumerState<PluginPromptsPage>
    with MoeAutoSaveState<PluginPromptsPage> {
  final _fields = {
    for (final slot in PluginPromptSlot.values) slot: TextEditingController(),
  };
  Object? _loadError;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    ref.read(pluginPromptsProvider.future).then(
      (prompts) {
        if (!mounted) return;
        for (final slot in PluginPromptSlot.values) {
          _fields[slot]!.text = prompts.of(slot);
        }
        autoSave.configure(
          save: _save,
          snapshot: () => moeAutoSaveSignature([
            for (final field in _fields.values) field.text,
          ]),
          fields: _fields.values,
        );
        setState(() => _loaded = true);
      },
      onError: (Object error) {
        if (mounted) setState(() => _loadError = error);
      },
    );
  }

  Future<void> _save() async {
    final notifier = ref.read(pluginPromptsProvider.notifier);
    final current = await ref.read(pluginPromptsProvider.future);
    for (final slot in PluginPromptSlot.values) {
      final text = _fields[slot]!.text;
      if (text != current.of(slot)) await notifier.setText(slot, text);
    }
  }

  @override
  void dispose() {
    for (final field in _fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    return MoePageScaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: colors.surface,
      appBar: const MoeAppBar(
        title: PluginPromptsPage.title,
        showBackButton: true,
      ),
      body: _loadError != null
          ? MoeEmptyState(
              icon: Icons.error_outline,
              title: '读取失败',
              description: '$_loadError',
            )
          : !_loaded
          ? const Center(child: MoeLoadingIndicator())
          : autoSavePage(
              Builder(
                builder: (context) => ListView(
                  padding: moeUnderBarPadding(
                    context,
                    const EdgeInsets.fromLTRB(16, 12, 16, 24),
                  ),
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 0, 4, 16),
                      child: Text(
                        '这些说明所有角色共用。角色自己的要求请在角色设置里填写。',
                        style: TextStyle(
                          fontSize: 13,
                          color: colors.textSecondary,
                        ),
                      ),
                    ),
                    for (final slot in PluginPromptSlot.values)
                      _SlotEditor(slot: slot, controller: _fields[slot]!),
                  ],
                ),
              ),
            ),
    );
  }
}

class _SlotEditor extends StatelessWidget {
  const _SlotEditor({required this.slot, required this.controller});

  final PluginPromptSlot slot;
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${slot.plugin} · ${slot.title}',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: MoeFontWeights.emphasis,
                    color: colors.text,
                  ),
                ),
              ),
              ListenableBuilder(
                listenable: controller,
                builder: (context, _) =>
                    controller.text.trim() == slot.defaultText.trim()
                    ? Text(
                        '默认',
                        style: TextStyle(fontSize: 12, color: colors.muted),
                      )
                    : MoeSecondaryButton(
                        label: '恢复默认',
                        size: MoeSecondaryButtonSize.sm,
                        onPressed: () => controller.text = slot.defaultText,
                      ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            slot.hint,
            style: TextStyle(
              fontSize: 12,
              height: 1.4,
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          MoeTextField(
            controller: controller,
            minLines: 3,
            maxLines: 12,
            keyboardType: TextInputType.multiline,
          ),
        ],
      ),
    );
  }
}
