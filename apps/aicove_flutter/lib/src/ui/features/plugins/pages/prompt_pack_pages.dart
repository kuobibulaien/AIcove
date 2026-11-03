import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/plugins/prompts/prompt_pack.dart';
import '../../../../features/plugins/prompts/prompt_pack_store.dart';
import '../../../shared/animations/parallax_slide_page_route.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';
import '../widgets/preset_prompt_group.dart';
import 'prompt_section_editor_page.dart';

/// All prompt packs of one plugin (ADR0092): built-in model families and the
/// user's own packs, with their match rules.
class PromptPackListPage extends ConsumerWidget {
  const PromptPackListPage({super.key, required this.pluginId});

  final String pluginId;

  static const title = '提示词包';

  static String titleFor(String pluginId) =>
      pluginId == 'image' ? '生图偏好' : title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.moeColors;
    final state = ref.watch(promptPackProvider);
    return MoePageScaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: colors.surface,
      appBar: MoeAppBar(title: titleFor(pluginId), showBackButton: true),
      body: state.when(
        loading: () => const Center(child: MoeLoadingIndicator()),
        error: (e, _) => MoeEmptyState(
          icon: Icons.error_outline,
          title: '读取失败',
          description: '$e',
        ),
        data: (data) {
          final packs = data.library.packsFor(pluginId);
          return MoeSettingsContent(
            child: Builder(
              builder: (context) => ListView(
                padding: moeUnderBarPadding(
                  context,
                  MoeSettingsLayout.verticalListPadding,
                ),
                children: [
                  if (pluginId != 'image')
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                      child: Text(
                        '预设选「自动」时，按渠道格式和模型名从上往下找第一个匹配的包；'
                        '都不匹配用「通用」类的出厂包。自建包排在最前面。',
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.textSecondary,
                        ),
                      ),
                    ),
                  MoeSettingsGroup(
                    children: [
                      for (final pack in packs)
                        MoeSettingsRow(
                          label: pack.name,
                          subtitle: pluginId == 'image'
                              ? (pack.description.isNotEmpty
                                    ? pack.description
                                    : (pack.builtIn ? '内置方案' : '自建方案'))
                              : [
                                  pack.builtIn ? '出厂' : '自建',
                                  if (pack.fallback) '默认',
                                  if (isPromptPackModified(data.library, pack))
                                    '已修改',
                                  if (pack.description.isNotEmpty)
                                    pack.description
                                  else if (pack.match.isNotEmpty)
                                    _rulesText(pack.match),
                                  if (promptPackActivePresets(
                                    ref,
                                    data.library,
                                    pack,
                                  ).isNotEmpty)
                                    '${promptPackActivePresets(ref, data.library, pack).length} 个预设在用',
                                ].join(' · '),
                          onTap: () => Navigator.of(context).push(
                            ParallaxSlidePageRoute(
                              page: PromptPackDetailPage(packId: pack.id),
                            ),
                          ),
                        ),
                      MoeSettingsRow(
                        icon: Icons.add,
                        iconColor: colors.primary,
                        label: pluginId == 'image' ? '新建生图方案' : '新建提示词包',
                        labelColor: colors.primary,
                        trailingType: MoeSettingsRowTrailing.none,
                        showDivider: true,
                        onTap: () =>
                            createCustomPromptPack(context, ref, packs: packs),
                      ),
                      MoeSettingsRow(
                        key: ValueKey('list-import-pack-$pluginId'),
                        icon: Icons.file_upload_outlined,
                        iconColor: colors.primary,
                        label: '从文件导入',
                        labelColor: colors.primary,
                        trailingType: MoeSettingsRowTrailing.none,
                        showDivider: false,
                        onTap: () => importCustomPromptPack(
                          context,
                          ref,
                          expectedPluginId: pluginId,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Forks the fallback pack (or first pack) to create a new custom pack and
/// opens its detail page.
Future<void> createCustomPromptPack(
  BuildContext context,
  WidgetRef ref, {
  required List<PromptPack> packs,
}) async {
  final base = packs.where((p) => p.fallback).firstOrNull ?? packs.firstOrNull;
  if (base == null) return;
  try {
    final id = await ref
        .read(promptPackProvider.notifier)
        .fork(base.id, name: '自建提示词包');
    if (!context.mounted) return;
    await Navigator.of(
      context,
    ).push(ParallaxSlidePageRoute(page: PromptPackDetailPage(packId: id)));
  } catch (e) {
    if (context.mounted) MoeToast.error(context, '新建失败：$e');
  }
}

const int _maxImportBytes = 2 * 1024 * 1024;

/// Picks a pack JSON file (or uses [rawJsonOverride]), imports it as a custom
/// pack and opens its detail page. Cancelling the picker does nothing.
Future<void> importCustomPromptPack(
  BuildContext context,
  WidgetRef ref, {
  String? expectedPluginId,
  String? rawJsonOverride,
  String? fallbackNameOverride,
}) async {
  try {
    var rawJson = rawJsonOverride;
    var fallbackName = fallbackNameOverride;
    if (rawJson == null) {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;
      final file = result.files.single;
      if (file.size > _maxImportBytes) {
        throw const FormatException('文件超过 2 MB，导入不了');
      }
      final bytes = file.bytes ?? await file.xFile.readAsBytes();
      if (bytes.length > _maxImportBytes) {
        throw const FormatException('文件超过 2 MB，导入不了');
      }
      try {
        rawJson = utf8.decode(bytes);
      } on FormatException {
        throw const FormatException('这个文件打不开，可能已经损坏');
      }
      fallbackName ??= file.name.toLowerCase().endsWith('.json')
          ? file.name.substring(0, file.name.length - '.json'.length)
          : file.name;
    }
    final pack = await ref
        .read(promptPackProvider.notifier)
        .importCustomFromJson(
          rawJson,
          expectedPluginId: expectedPluginId,
          fallbackName: fallbackName,
        );
    if (!context.mounted) return;
    await Navigator.of(
      context,
    ).push(ParallaxSlidePageRoute(page: PromptPackDetailPage(packId: pack.id)));
  } catch (e) {
    if (!context.mounted) return;
    MoeToast.error(
      context,
      e is FormatException ? e.message : '这个文件打不开，可能已经损坏',
    );
  }
}

/// Saves [pack] as a pretty-printed JSON file chosen by the user.
Future<void> exportPromptPack(BuildContext context, PromptPack pack) async {
  final jsonText = const JsonEncoder.withIndent('  ').convert(pack.toJson());
  final bytes = Uint8List.fromList(utf8.encode(jsonText));
  try {
    final savePath = await FilePicker.platform.saveFile(
      dialogTitle: '导出提示词包',
      fileName: '${pack.name}.json',
      type: FileType.custom,
      allowedExtensions: const ['json'],
      bytes: bytes,
    );
    if (savePath == null) return;
    // Mobile pickers write [bytes] themselves; desktop only returns a path.
    if (!Platform.isAndroid && !Platform.isIOS) {
      await File(savePath).writeAsString(jsonText, flush: true);
    }
    if (context.mounted) MoeToast.success(context, '已导出「${pack.name}」');
  } catch (e) {
    if (context.mounted) MoeToast.error(context, '导出失败，请换个位置再试');
  }
}

String _rulesText(List<PromptMatchRule> rules) => rules
    .map(
      (r) => [
        if (r.formats.isNotEmpty) r.formats.join('/'),
        if (r.models.isNotEmpty) r.models.join(' 或 '),
      ].join(' + '),
    )
    .join('；');

String _postProcessorSubtitle(String postProcessor) => switch (postProcessor) {
  'novelai_manga' => '拆格定位与台词嵌字，并自动过滤单图冲突词',
  'moss_manga' => '将版式暗号编译为多格坐标后发给工作流',
  _ => '按画面描述原样发给绘图渠道',
};

/// One pack: its sections, and for a custom pack its name and rules.
class PromptPackDetailPage extends ConsumerStatefulWidget {
  const PromptPackDetailPage({super.key, required this.packId});

  final String packId;

  @override
  ConsumerState<PromptPackDetailPage> createState() =>
      _PromptPackDetailPageState();
}

class _PromptPackDetailPageState extends ConsumerState<PromptPackDetailPage>
    with MoeAutoSaveState<PromptPackDetailPage> {
  final _name = TextEditingController();
  final _formats = TextEditingController();
  final _models = TextEditingController();
  String _postProcessor = 'plain';
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    ref.read(promptPackProvider.future).then((state) {
      final pack = state.library.byId(widget.packId);
      if (!mounted || pack == null || pack.builtIn) return;
      _name.text = pack.name;
      final rule = pack.match.firstOrNull;
      _formats.text = rule?.formats.join(', ') ?? '';
      _models.text = rule?.models.join('\n') ?? '';
      _postProcessor = pack.postProcessor;
      autoSave.configure(
        save: _saveMeta,
        snapshot: () => moeAutoSaveSignature([
          _name.text,
          _formats.text,
          _models.text,
          _postProcessor,
        ]),
        fields: [_name, _formats, _models],
      );
      setState(() => _loaded = true);
    });
  }

  Future<void> _saveMeta() async {
    List<String> split(String text, Pattern by) => [
      for (final part in text.split(by))
        if (part.trim().isNotEmpty) part.trim(),
    ];
    final formats = split(_formats.text, RegExp(r'[,\n，]'));
    // One per line only: a regex like /s2{1,2}/ has commas in it.
    final models = split(_models.text, '\n');
    final name = _name.text.trim();
    await ref
        .read(promptPackProvider.notifier)
        .editCustomMeta(
          widget.packId,
          name: name.isEmpty ? null : name,
          match: formats.isEmpty && models.isEmpty
              ? const []
              : [PromptMatchRule(formats: formats, models: models)],
          postProcessor: _postProcessor,
        );
  }

  Future<void> _pickPostProcessor() async {
    const options = ['plain', 'novelai_manga', 'moss_manga'];
    final chosen = await showMoeBottomSheet<String>(
      context: context,
      title: '后处理方式',
      showCloseButton: true,
      builder: (context) => ListView(
        shrinkWrap: true,
        children: [
          for (final option in options)
            ListTile(
              title: Text(PromptPack.postProcessorLabel(option)),
              subtitle: Text(_postProcessorSubtitle(option)),
              trailing: option == _postProcessor
                  ? Icon(Icons.check, color: context.moeColors.primary)
                  : null,
              onTap: () => Navigator.pop(context, option),
            ),
        ],
      ),
    );
    if (chosen == null || chosen == _postProcessor || !mounted) return;
    setState(() => _postProcessor = chosen);
    unawaited(autoSave.flush());
  }

  Future<void> _delete(PromptPack pack) async {
    final bound = promptPackBoundPresets(ref, pack.id);
    if (bound.isNotEmpty) {
      await showMeoTalkAlert(
        context: context,
        title: '还有预设在用',
        message: '「${bound.join('、')}」绑定了这个包，请先在预设里换成别的包。',
      );
      return;
    }
    final ok = await showMeoTalkConfirm(
      context: context,
      title: '删除「${pack.name}」？',
      message: '删除后不可恢复。',
      confirmText: '删除',
    );
    if (ok != true || !mounted) return;
    autoSave.configure(save: () async {}, snapshot: () => null);
    await ref.read(promptPackProvider.notifier).deleteCustom(pack.id);
    if (mounted) Navigator.pop(context);
  }

  Future<void> _addSection(PromptPack pack) async {
    final scopes = PromptScopes.of(pack.pluginId);
    final scope = await showMoeBottomSheet<String>(
      context: context,
      title: '这一节发到哪里',
      showCloseButton: true,
      builder: (context) => ListView(
        shrinkWrap: true,
        children: [
          for (final entry in scopes.entries)
            ListTile(
              title: Text(entry.value),
              onTap: () => Navigator.pop(context, entry.key),
            ),
        ],
      ),
    );
    if (scope == null || !mounted) return;
    final id = newPromptSectionId();
    await ref
        .read(promptPackProvider.notifier)
        .addSection(
          pack.id,
          PromptSection(id: id, scope: scope, title: '新的一节', text: ''),
        );
    if (!mounted) return;
    await Navigator.of(context).push(
      ParallaxSlidePageRoute(
        page: PromptSectionEditorPage.pack(
          pluginId: pack.pluginId,
          packId: pack.id,
          sectionId: id,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _name.dispose();
    _formats.dispose();
    _models.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final library = ref.watch(promptPackProvider).valueOrNull?.library;
    final pack = library?.byId(widget.packId);
    final page = MoePageScaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: colors.surface,
      appBar: MoeAppBar(title: pack?.name ?? '提示词包', showBackButton: true),
      body: pack == null
          ? const Center(child: MoeLoadingIndicator())
          : MoeSettingsContent(
              child: Builder(
                builder: (context) => ListView(
                  padding: moeUnderBarPadding(
                    context,
                    MoeSettingsLayout.verticalListPadding,
                  ),
                  children: [
                    if (pack.description.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                        child: Text(
                          pack.description,
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.textSecondary,
                          ),
                        ),
                      ),
                    if (pack.builtIn)
                      MoeSettingsGroup(
                        title: '匹配规则',
                        titleFirst: true,
                        children: [
                          MoeSettingsRow(
                            label: pack.match.isEmpty
                                ? '不参与匹配'
                                : _rulesText(pack.match),
                            subtitle: pack.fallback
                                ? '没有别的包匹配时用它'
                                : '出厂规则不能改；想换规则请另存为自建包',
                            showDivider: pack.pluginId == 'image',
                            trailingType: MoeSettingsRowTrailing.none,
                          ),
                          if (pack.pluginId == 'image')
                            MoeSettingsRow(
                              label:
                                  '后处理：${PromptPack.postProcessorLabel(pack.postProcessor)}',
                              subtitle: _postProcessorSubtitle(
                                pack.postProcessor,
                              ),
                              showDivider: false,
                              trailingType: MoeSettingsRowTrailing.none,
                            ),
                        ],
                      )
                    else if (_loaded) ...[
                      MoeSettingsGroup(
                        title: '名称与匹配规则',
                        titleFirst: true,
                        padding: MoeSettingsLayout.contentPadding,
                        children: [
                          MoeTextField(controller: _name, label: '名称'),
                          const SizedBox(height: 12),
                          MoeTextField(
                            controller: _formats,
                            label: '渠道格式（逗号分隔，可空）',
                            hint: '如 fish_audio、minimax、novelai、comfyui、openai',
                          ),
                          const SizedBox(height: 12),
                          MoeTextField(
                            controller: _models,
                            label: '模型（每行一个，可空）',
                            hint: '关键字直接写；正则写成 /^s2/',
                            minLines: 2,
                            maxLines: 6,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '两项都留空：这个包只在预设明确选中时使用。',
                            style: TextStyle(fontSize: 12, color: colors.muted),
                          ),
                        ],
                      ),
                      if (pack.pluginId == 'image')
                        MoeSettingsGroup(
                          title: '后处理方式',
                          titleFirst: true,
                          children: [
                            MoeSettingsRow(
                              label: PromptPack.postProcessorLabel(
                                _postProcessor,
                              ),
                              subtitle: _postProcessorSubtitle(_postProcessor),
                              showDivider: false,
                              trailingType: MoeSettingsRowTrailing.chevron,
                              onTap: _pickPostProcessor,
                            ),
                          ],
                        ),
                    ],
                    for (final scope in PromptScopes.of(pack.pluginId).entries)
                      if (pack.sections.any((s) => s.scope == scope.key))
                        MoeSettingsGroup(
                          title: scope.value,
                          titleFirst: true,
                          children: [
                            for (final section in pack.sections)
                              if (section.scope == scope.key)
                                PromptSectionRow(
                                  section: section,
                                  tag: library!.isModified(pack.id, section.id)
                                      ? '已修改'
                                      : pack.builtIn &&
                                            library.isUserSection(
                                              pack.id,
                                              section.id,
                                            )
                                      ? '自己加的'
                                      : null,
                                  onToggle: (on) => ref
                                      .read(promptPackProvider.notifier)
                                      .editSection(
                                        pack.id,
                                        section.id,
                                        enabled: on,
                                      ),
                                  onTap: () => Navigator.of(context).push(
                                    ParallaxSlidePageRoute(
                                      page: PromptSectionEditorPage.pack(
                                        pluginId: pack.pluginId,
                                        packId: pack.id,
                                        sectionId: section.id,
                                      ),
                                    ),
                                  ),
                                ),
                          ],
                        ),
                    Padding(
                      padding: MoeSettingsLayout.contentPadding,
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          MoeSecondaryButton(
                            label: '加一节',
                            size: MoeSecondaryButtonSize.sm,
                            onPressed: () => _addSection(pack),
                          ),
                          MoeSecondaryButton(
                            label: '另存为新包',
                            size: MoeSecondaryButtonSize.sm,
                            onPressed: () async {
                              final id = await ref
                                  .read(promptPackProvider.notifier)
                                  .fork(pack.id);
                              if (!context.mounted) return;
                              await Navigator.of(context).pushReplacement(
                                ParallaxSlidePageRoute(
                                  page: PromptPackDetailPage(packId: id),
                                ),
                              );
                            },
                          ),
                          if (!pack.builtIn)
                            MoeSecondaryButton(
                              label: '导出为文件',
                              size: MoeSecondaryButtonSize.sm,
                              onPressed: () => exportPromptPack(context, pack),
                            ),
                          if (!pack.builtIn)
                            MoeSecondaryButton(
                              label: '删除这个包',
                              size: MoeSecondaryButtonSize.sm,
                              foregroundColor: Theme.of(
                                context,
                              ).colorScheme.error,
                              onPressed: () => _delete(pack),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
    return autoSavePage(page);
  }
}
