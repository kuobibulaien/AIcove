import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/plugins/image/drawing_preset_provider.dart';
import '../../../../features/plugins/plugin_providers.dart';
import '../../../../features/plugins/prompts/prompt_pack.dart';
import '../../../../features/plugins/prompts/prompt_pack_store.dart';
import '../../../../features/settings/app_settings.dart';
import '../../../shared/animations/parallax_slide_page_route.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';
import '../pages/prompt_preview_page.dart';
import '../pages/prompt_section_editor_page.dart';

/// Names of the presets explicitly bound to [packId] (voice and drawing).
/// Presets on 「自动」 that match the pack are not counted.
List<String> promptPackBoundPresets(WidgetRef ref, String packId) => [
  for (final p in ref.watch(ttsPluginConfigProvider).voicePresets)
    if (p.synthesis?.prompts.packId == packId) p.name,
  for (final p
      in ref.watch(drawingPresetCatalogProvider).valueOrNull?.presets ??
          const [])
    if (p.prompts.packId == packId) p.name,
];

/// The 「提示词」 part of a voice or drawing preset editor (ADR0092): which
/// pack it uses, every section that reaches the model, the preset's own
/// sections, and a preview of the final text.
///
/// Drawing sections are shown one call flow at a time (快速／调用), starting
/// with the flow in use, so the editor lists only what this flow sends.
/// Pack sections are shared and saved at once; the preset's own sections go
/// through [onChanged] and are saved with the preset.
class PresetPromptGroup extends ConsumerStatefulWidget {
  const PresetPromptGroup({
    super.key,
    required this.pluginId,
    required this.binding,
    required this.onChanged,
    required this.format,
    required this.model,
    required this.variables,
    this.presetName = '',
  });

  final String pluginId;
  final PresetPromptBinding binding;
  final ValueChanged<PresetPromptBinding> onChanged;

  /// The preset's channel format and model, for 「自动」; null until chosen.
  final String? format;
  final String? model;
  final Map<String, Object?> variables;
  final String presetName;

  /// Scopes each call flow sends, for plugins whose sections depend on it.
  static const flowScopes = <String, Map<CallFlowMode, List<String>>>{
    'image': {
      CallFlowMode.fast: [PromptScopes.imageInline],
      CallFlowMode.call: [
        PromptScopes.imageToolDescription,
        PromptScopes.imageToolPrompt,
        PromptScopes.imageToolParams,
      ],
    },
  };

  @override
  ConsumerState<PresetPromptGroup> createState() => _PresetPromptGroupState();
}

class _PresetPromptGroupState extends ConsumerState<PresetPromptGroup> {
  /// Null follows the app's call flow setting.
  CallFlowMode? _flow;

  PresetPromptBinding get _binding => widget.binding;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final state = ref.watch(promptPackProvider);
    return state.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: MoeLoadingIndicator()),
      ),
      error: (e, _) => MoeEmptyState(
        icon: Icons.error_outline,
        title: '提示词包读取失败',
        description: '$e',
      ),
      data: (data) {
        final library = data.library;
        final ResolvedPromptPack resolved;
        try {
          resolved = library.resolve(
            widget.pluginId,
            _binding,
            format: widget.format ?? '',
            model: widget.model ?? '',
          );
        } on PromptPackMissingException catch (e) {
          return MoeSettingsGroup(
            title: '提示词',
            titleFirst: true,
            children: [
              MoeSettingsRow(
                icon: Icons.error_outline,
                iconColor: Theme.of(context).colorScheme.error,
                label: '绑定的提示词包已不存在',
                subtitle: '$e',
                onTap: () => _pickPack(context, library),
              ),
            ],
          );
        }
        final pack = resolved.pack;
        final autoPack = library.autoMatch(
          widget.pluginId,
          widget.format ?? '',
          widget.model ?? '',
        );
        final bound = promptPackBoundPresets(ref, pack.id);
        final scopes = PromptScopes.of(widget.pluginId);
        final flows = PresetPromptGroup.flowScopes[widget.pluginId];
        final flow =
            _flow ??
            ref.watch(appSettingsProvider).valueOrNull?.callFlowSettings.mode ??
            CallFlowMode.fast;
        final shown = flows == null ? scopes.keys.toList() : flows[flow]!;
        final rows = <Widget>[
          for (final scope in shown) ...[
            for (final section in pack.sections)
              if (section.scope == scope)
                PromptSectionRow(
                  section: section,
                  tag: library.isModified(pack.id, section.id)
                      ? '已修改'
                      : pack.builtIn &&
                            library.isUserSection(pack.id, section.id)
                      ? '自己加的'
                      : null,
                  scopeLabel: flows == null ? scopes[scope] : null,
                  onToggle: (on) => ref
                      .read(promptPackProvider.notifier)
                      .editSection(pack.id, section.id, enabled: on),
                  onTap: () => _editPackSection(context, pack, section),
                ),
            for (final section in _binding.ownSections)
              if (section.scope == scope)
                PromptSectionRow(
                  section: section,
                  tag: '本预设专属',
                  scopeLabel: flows == null ? scopes[scope] : null,
                  onToggle: (on) => widget.onChanged(
                    _binding.upsertSection(section.copyWith(enabled: on)),
                  ),
                  onTap: () => _editOwnSection(context, section),
                ),
          ],
        ];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            MoeSettingsGroup(
              title: '提示词',
              titleFirst: true,
              children: [
                MoeSettingsRow(
                  icon: Icons.layers_outlined,
                  label: '提示词包',
                  subtitle: resolved.automatic
                      ? '自动匹配 · ${pack.name}'
                      : pack.name,
                  onTap: () => _pickPack(context, library),
                ),
                if (!resolved.automatic && autoPack.id != pack.id)
                  MoeSettingsRow(
                    icon: Icons.tips_and_updates_outlined,
                    iconColor: colors.primary,
                    label: '当前模型推荐「${autoPack.name}」',
                    subtitle: '这个预设固定用「${pack.name}」，点这里改回自动匹配',
                    onTap: () => widget.onChanged(_binding.withPack(null)),
                  ),
                MoeSettingsRow(
                  icon: Icons.visibility_outlined,
                  label: '预览最终提示词',
                  subtitle: '按这个预设的参数，显示发给模型的全文',
                  onTap: () => Navigator.of(context).push(
                    ParallaxSlidePageRoute(
                      page: PromptPreviewPage(
                        pluginId: widget.pluginId,
                        resolved: resolved,
                        variables: widget.variables,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            if (flows != null)
              Padding(
                padding: const EdgeInsets.only(top: 12, bottom: 12),
                child: MoeSegmentedControl<CallFlowMode>(
                  value: flow,
                  segments: [
                    for (final mode in flows.keys)
                      MoeSegment(value: mode, label: '${mode.label}模式'),
                  ],
                  onChanged: (mode) => setState(() => _flow = mode),
                ),
              ),
            MoeSettingsGroup(
              children: rows.isEmpty
                  ? [
                      const MoeSettingsRow(
                        label: '这个模式没有说明',
                        trailingType: MoeSettingsRowTrailing.none,
                      ),
                    ]
                  : rows,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 12),
              child: Text(
                '包里的节是共享的'
                '${bound.length > 1 ? '（${bound.length} 个预设在用）' : ''}，'
                '改动会同步到所有用它的预设；只想改这个预设，就加一节专属说明或另存为新包。',
                style: TextStyle(fontSize: 12, color: colors.textSecondary),
              ),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                IntrinsicWidth(
                  child: MoeSecondaryButton(
                    label: '加一节（本预设专属）',
                    size: MoeSecondaryButtonSize.sm,
                    onPressed: () => _addOwnSection(
                      context,
                      flows == null ? scopes.keys.toList() : shown,
                    ),
                  ),
                ),
                IntrinsicWidth(
                  child: MoeSecondaryButton(
                    label: '另存为新包',
                    size: MoeSecondaryButtonSize.sm,
                    onPressed: () => _fork(context, pack),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
          ],
        );
      },
    );
  }

  Future<void> _pickPack(
    BuildContext context,
    PromptPackLibrary library,
  ) async {
    const auto = '__auto__';
    final packs = library.packsFor(widget.pluginId);
    final selected = await showMoeBottomSheet<String>(
      context: context,
      title: '选择提示词包',
      showCloseButton: true,
      builder: (context) => ListView(
        shrinkWrap: true,
        children: [
          ListTile(
            title: const Text('自动（按模型匹配）'),
            subtitle: Text(
              '当前模型：${library.autoMatch(widget.pluginId, widget.format ?? '', widget.model ?? '').name}',
            ),
            trailing: _binding.packId == null ? const Icon(Icons.check) : null,
            onTap: () => Navigator.pop(context, auto),
          ),
          for (final pack in packs)
            ListTile(
              title: Text(pack.name),
              subtitle: pack.description.isEmpty
                  ? null
                  : Text(pack.description),
              trailing: _binding.packId == pack.id
                  ? const Icon(Icons.check)
                  : null,
              onTap: () => Navigator.pop(context, pack.id),
            ),
        ],
      ),
    );
    if (selected == null) return;
    widget.onChanged(_binding.withPack(selected == auto ? null : selected));
  }

  Future<void> _editPackSection(
    BuildContext context,
    PromptPack pack,
    PromptSection section,
  ) => Navigator.of(context).push(
    ParallaxSlidePageRoute(
      page: PromptSectionEditorPage.pack(
        pluginId: widget.pluginId,
        packId: pack.id,
        sectionId: section.id,
      ),
    ),
  );

  Future<void> _editOwnSection(
    BuildContext context,
    PromptSection section,
  ) async {
    final result = await Navigator.of(context).push<PromptSectionEdit>(
      ParallaxSlidePageRoute(
        page: PromptSectionEditorPage.own(
          pluginId: widget.pluginId,
          section: section,
        ),
      ),
    );
    if (result == null) return;
    widget.onChanged(
      result.deleted
          ? _binding.removeSection(section.id)
          : _binding.upsertSection(result.section!),
    );
  }

  /// [scopes] are the places on screen; with one, it is used directly.
  Future<void> _addOwnSection(BuildContext context, List<String> scopes) async {
    final labels = PromptScopes.of(widget.pluginId);
    final scope = scopes.length == 1
        ? scopes.single
        : await showMoeBottomSheet<String>(
            context: context,
            title: '这一节发到哪里',
            showCloseButton: true,
            builder: (context) => ListView(
              shrinkWrap: true,
              children: [
                for (final scope in scopes)
                  ListTile(
                    title: Text(labels[scope] ?? scope),
                    onTap: () => Navigator.pop(context, scope),
                  ),
              ],
            ),
          );
    if (scope == null || !context.mounted) return;
    final result = await Navigator.of(context).push<PromptSectionEdit>(
      ParallaxSlidePageRoute(
        page: PromptSectionEditorPage.own(
          pluginId: widget.pluginId,
          section: PromptSection(
            id: newPromptSectionId(),
            scope: scope,
            title: '本预设的要求',
            text: '',
          ),
          isNew: true,
        ),
      ),
    );
    if (result?.section == null || result!.section!.text.trim().isEmpty) {
      return;
    }
    widget.onChanged(_binding.upsertSection(result.section!));
  }

  Future<void> _fork(BuildContext context, PromptPack pack) async {
    try {
      final id = await ref
          .read(promptPackProvider.notifier)
          .fork(
            pack.id,
            name: widget.presetName.trim().isEmpty
                ? null
                : '${widget.presetName.trim()} · ${pack.name}',
          );
      widget.onChanged(_binding.withPack(id));
      if (context.mounted) MoeToast.success(context, '已另存为新包，并绑到这个预设');
    } catch (e) {
      if (context.mounted) MoeToast.error(context, '另存失败：$e');
    }
  }
}

/// One prompt section: title, a two-line preview and its on/off switch.
class PromptSectionRow extends StatelessWidget {
  const PromptSectionRow({
    required this.section,
    required this.onToggle,
    required this.onTap,
    this.tag,
    this.scopeLabel,
  });

  final PromptSection section;
  final String? tag;

  /// Where the section goes, when the list mixes several places.
  final String? scopeLabel;
  final ValueChanged<bool> onToggle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    // Markdown heading marks are noise in a two-line preview.
    final preview = section.text
        .replaceAll(RegExp(r'^#+\s*', multiLine: true), '')
        .trim()
        .replaceAll(RegExp(r'\s+'), ' ');
    return MoeSettingsRow(
      label: section.title.isEmpty ? '（未命名）' : section.title,
      labelColor: section.enabled ? null : colors.muted,
      subtitleWidget: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (tag != null || scopeLabel != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                [?scopeLabel, ?tag].join(' · '),
                style: TextStyle(fontSize: 11, color: colors.primary),
              ),
            ),
          Text(
            preview.isEmpty ? '（空）' : preview,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: colors.textSecondary),
          ),
        ],
      ),
      trailingType: MoeSettingsRowTrailing.custom,
      trailing: MoeSwitch(
        value: section.enabled,
        size: MoeSwitchSize.sm,
        onChanged: onToggle,
      ),
      onTap: onTap,
    );
  }
}
