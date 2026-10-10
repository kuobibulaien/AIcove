import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/agent_context/domain/preset_tag_mapping.dart';
import '../../../../features/agent_context/domain/silly_tavern_preset.dart';
import '../../../../features/agent_context/domain/tavern_compatibility_port.dart';
import '../../../../features/agent_context/providers/preset_recipe_provider.dart';
import '../../../../features/content_tags/domain/tag_presentation.dart';
import '../../../../features/conversation_state/domain/mvu_content.dart';
import '../../../shared/animations/parallax_slide_page_route.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';
import '../widgets/tavern_common.dart';
import '../widgets/tavern_prompt_list.dart';
import 'tavern_world_book_page.dart';

enum _Section { prompts, regex, worldBooks, tags }

/// 一套酒馆预设：提示词、正则、世界书与标签显示，修改自动保存。
class TavernPresetDetailPage extends ConsumerStatefulWidget {
  const TavernPresetDetailPage({super.key, required this.presetId});

  final String presetId;

  @override
  ConsumerState<TavernPresetDetailPage> createState() =>
      _TavernPresetDetailPageState();
}

class _TavernPresetDetailPageState
    extends ConsumerState<TavernPresetDetailPage> {
  _Section _section = _Section.prompts;

  String get _id => widget.presetId;

  void _change(Future<void> Function(TavernCompatibilityPort port) action) =>
      runTavernAction(
        context,
        () => ref
            .read(presetRecipeImportControllerProvider.notifier)
            .change(_id, action),
      );

  @override
  Widget build(BuildContext context) {
    final value = ref.watch(presetRecipeProvider(_id));
    final colors = context.moeColors;
    return MoePageScaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: colors.surface,
      appBar: MoeAppBar(
        title: value.valueOrNull?.name ?? '酒馆预设',
        showBackButton: true,
      ),
      body: MoeSettingsContent(
        child: value.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => _Missing(
            title: '读取失败',
            description: '$error',
            onRetry: () => ref.invalidate(presetRecipeProvider(_id)),
          ),
          data: (preset) => preset == null
              ? const _Missing(title: '预设不存在或已损坏', description: '返回插件页重新导入即可')
              : Builder(
                  builder: (context) => ListView(
                    key: PageStorageKey('tavern-${_section.name}'),
                    padding: moeUnderBarPadding(
                      context,
                      MoeSettingsLayout.verticalListPadding,
                    ),
                    children: [
                      MoeToggleBar<_Section>(
                        value: _section,
                        items: const [
                          MoeToggleItem(value: _Section.prompts, label: '提示词'),
                          MoeToggleItem(value: _Section.regex, label: '正则'),
                          MoeToggleItem(
                            value: _Section.worldBooks,
                            label: '世界书',
                          ),
                          MoeToggleItem(value: _Section.tags, label: '标签'),
                        ],
                        onChanged: (section) =>
                            setState(() => _section = section),
                      ),
                      const SizedBox(height: MoeSettingsLayout.sectionGap),
                      ...switch (_section) {
                        _Section.prompts => _prompts(preset),
                        _Section.regex => _regex(preset),
                        _Section.worldBooks => _worldBooks(preset),
                        _Section.tags => _tags(preset),
                      },
                    ],
                  ),
                ),
        ),
      ),
    );
  }

  // ==================== 提示词 ====================

  List<Widget> _prompts(SillyTavernPreset preset) {
    return [
      const TavernNote('按发送顺序排列。关掉的条目不会发给模型；修改会影响所有用这套预设的角色，从下一条消息起生效。'),
      TavernPromptList(preset: preset),
      MoeSettingsGroup(
        title: '关于这套预设',
        children: [
          MoeSettingsRow(
            label: '{{user}} 替换为我的名称',
            trailingType: MoeSettingsRowTrailing.custom,
            trailing: MoeSwitch(
              key: const ValueKey('user-name-macro'),
              value: preset.userNameMacroEnabled,
              semanticLabel: '{{user}} 替换为我的名称',
              onChanged: (v) =>
                  _change((port) => port.setUserNameMacroEnabled(_id, v)),
            ),
          ),
          MoeSettingsRow(
            label: '预设信息',
            subtitle: preset.warnings.isEmpty
                ? '来源文件与参数生效情况'
                : '有 ${preset.warnings.length} 条导入提示',
            onTap: () => showMoeBottomSheet<void>(
              context: context,
              title: '预设信息',
              showCloseButton: true,
              maxHeight: MediaQuery.sizeOf(context).height * .75,
              builder: (_) => SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                child: TavernPresetInfo(preset: preset),
              ),
            ),
          ),
          MoeSettingsRow(
            key: ValueKey('delete-tavern-preset-$_id'),
            label: '删除预设',
            labelColor: Theme.of(context).colorScheme.error,
            trailingType: MoeSettingsRowTrailing.none,
            onTap: () async {
              final isDefault =
                  ref
                      .read(tavernPluginSettingsProvider)
                      .valueOrNull
                      ?.defaultPresetId ==
                  _id;
              final deleted = await confirmDeleteTavernPreset(
                context,
                ref,
                presetId: _id,
                name: preset.name,
                isDefault: isDefault,
              );
              if (deleted && mounted) Navigator.of(context).maybePop();
            },
          ),
        ],
      ),
    ];
  }

  // ==================== 正则 ====================

  List<Widget> _regex(SillyTavernPreset preset) {
    final mapping = inferPresetTagMapping(preset);
    final busy = ref.watch(presetRecipeImportControllerProvider).isLoading;
    final colors = context.moeColors;
    return [
      MoeSettingsGroup(
        children: [
          MoeSettingsRow(
            label: '允许运行正则',
            subtitle: preset.regexAuthorized ? '下面开着的规则会生效' : '关着时下面的规则都不运行',
            trailingType: MoeSettingsRowTrailing.custom,
            trailing: MoeSwitch(
              key: const ValueKey('regex-authorization'),
              value: preset.regexAuthorized,
              semanticLabel: '允许运行正则',
              onChanged: (v) => runTavernAction(
                context,
                () => ref
                    .read(presetRecipeImportControllerProvider.notifier)
                    .setRegexAuthorization(_id, v),
              ),
            ),
          ),
        ],
      ),
      MoeSettingsGroup(
        title: '规则 ${preset.regexScripts.length} 条',
        children: [
          for (final script in preset.regexScripts)
            _regexRow(
              script,
              superseded: mapping.supersededScriptIds.contains(script.id),
              hidden: mapping.hiddenScriptIds.contains(script.id),
            ),
          MoeSettingsRow(
            label: '导入正则',
            subtitle: '单条规则、规则数组或整份预设都可以',
            labelColor: colors.primary,
            enabled: !busy,
            trailingType: MoeSettingsRowTrailing.none,
            onTap: () => runTavernAction(context, () async {
              final file = await pickTavernJson();
              if (file == null) return;
              await ref
                  .read(presetRecipeImportControllerProvider.notifier)
                  .change(_id, (port) => port.importRegex(_id, file.source));
            }, success: '已导入正则'),
          ),
        ],
      ),
      const TavernNote('正则只改发给模型或显示出来的那一份，聊天原文不会变，也不会执行脚本。'),
    ];
  }

  Widget _regexRow(
    SillyTavernRegexScript script, {
    required bool superseded,
    required bool hidden,
  }) {
    final where = script.placements.map(_placementLabel).join('、');
    final phase = script.promptOnly
        ? '只改发给模型的内容'
        : script.markdownOnly
        ? '只改显示'
        : '发送和显示都改';
    return MoeSettingsRow(
      label: script.name,
      labelMaxLines: 2,
      subtitleWidget: tavernSubtitle(
        context,
        '${where.isEmpty ? '未指定位置' : where} · $phase',
        warnings: [
          if (script.substituteRegex != 0) '用到正则宏替换，暂不支持，不会运行',
          if (hidden) '换出的网页显示不了，显示时直接隐藏' else if (superseded) '已交给「标签」显示，不再运行',
        ],
      ),
      trailingType: MoeSettingsRowTrailing.custom,
      trailing: MoeSwitch(
        key: ValueKey('regex-${script.id}'),
        value: !script.disabled,
        semanticLabel: '启用 ${script.name}',
        onChanged: (v) =>
            _change((port) => port.setRegexEnabled(_id, script.id, v)),
      ),
      onTap: () => showTavernText(
        context,
        title: script.name,
        text: '查找\n${script.findRegex}\n\n替换为\n${script.replaceString}',
      ),
    );
  }

  // ==================== 世界书 ====================

  List<Widget> _worldBooks(SillyTavernPreset preset) {
    final busy = ref.watch(presetRecipeImportControllerProvider).isLoading;
    final colors = context.moeColors;
    final initVarCount = mvuInitVarEntries(preset.worldBooks).length;
    return [
      MoeSettingsGroup(
        children: [
          MoeSettingsRow(
            label: 'MVU 变量',
            labelMaxLines: 1,
            subtitle: !preset.mvuEnabled
                ? '关着时不解析变量，MVU 专用条目也不发给模型'
                : initVarCount > 0
                ? '已找到 $initVarCount 个 [InitVar] 初始变量条目，聊天时自动维护变量'
                : '已启用的世界书里没有 [InitVar] 条目；开场白带初始变量时同样生效',
            trailingType: MoeSettingsRowTrailing.custom,
            trailing: MoeSwitch(
              key: const ValueKey('mvu-enabled'),
              value: preset.mvuEnabled,
              semanticLabel: 'MVU 变量',
              onChanged: (v) => _change((port) => port.setMvuEnabled(_id, v)),
            ),
          ),
        ],
      ),
      MoeSettingsGroup(
        title: '世界书 ${preset.worldBooks.length} 本',
        children: [
          for (final book in preset.worldBooks)
            MoeSettingsRow(
              label: book.name,
              labelMaxLines: 2,
              subtitleWidget: tavernSubtitle(
                context,
                '${book.entries.where((e) => e.enabled).length}/${book.entries.length} 个条目开启',
                warnings: [
                  if (book.warnings.isNotEmpty)
                    '${book.warnings.length} 条导入提示，进去查看',
                ],
              ),
              trailingType: MoeSettingsRowTrailing.custom,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  MoeSwitch(
                    key: ValueKey('book-${book.id}'),
                    value: book.enabled,
                    semanticLabel: '启用世界书 ${book.name}',
                    onChanged: (v) => _change(
                      (port) => port.setWorldBookEnabled(_id, book.id, v),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(Icons.chevron_right, size: 20, color: colors.muted),
                ],
              ),
              onTap: () => Navigator.of(context).push(
                ParallaxSlidePageRoute(
                  page: TavernWorldBookPage(presetId: _id, bookId: book.id),
                ),
              ),
            ),
          MoeSettingsRow(
            label: '导入世界书',
            subtitle: '酒馆世界书 JSON，或带世界书的角色卡 JSON',
            labelColor: colors.primary,
            enabled: !busy,
            trailingType: MoeSettingsRowTrailing.none,
            onTap: () => runTavernAction(context, () async {
              final file = await pickTavernJson();
              if (file == null) return;
              await ref
                  .read(presetRecipeImportControllerProvider.notifier)
                  .change(
                    _id,
                    (port) => port.importWorldBook(_id, file.source, file.name),
                  );
            }, success: '已导入世界书'),
          ),
        ],
      ),
      const TavernNote(
        '最近的聊天里出现关键词时，把对应条目加进上下文；常驻条目每次都加。每本默认最多 2048 token，全部世界书合计不超过可用上下文的四分之一。',
      ),
    ];
  }

  // ==================== 标签 ====================

  List<Widget> _tags(SillyTavernPreset preset) {
    final mapping = inferPresetTagMapping(preset);
    final colors = context.moeColors;
    final mapped = {for (final rule in mapping.rules) rule.name};
    // 聊天中发现（ADR0048）：绑定本预设的会话，以及使用默认预设的会话。
    final observed = ref.watch(observedUnknownTagsProvider);
    final isDefault =
        ref.watch(tavernPluginSettingsProvider).valueOrNull?.defaultPresetId ==
        _id;
    final discovered = {
      ...?observed[observedTagsKey(_id)],
      if (isDefault) ...?observed[observedTagsKey(null)],
    }.difference(mapped).toList()..sort();
    final pending = mapping.candidates.where((n) => !mapped.contains(n));
    final taken =
        mapping.supersededScriptIds.length - mapping.hiddenScriptIds.length;
    return [
      TavernNote(
        '模型回复里的标签怎么显示：正文照常显示，折叠收进可展开的小块，选项放进回复旁的选项气泡。按预设正则自动识别，也可以手动改，从下一条回复起生效。'
        '${taken == 0 ? '' : '\n\n有 $taken 条输出网页样式的显示正则已由这里接管，不再运行。'}'
        '${mapping.hiddenScriptIds.isEmpty ? '' : '\n\n有 ${mapping.hiddenScriptIds.length} 条正则只是把占位符换成网页，网页显示不了，显示时直接隐藏。'}',
      ),
      MoeSettingsGroup(
        title: '标签 ${mapping.rules.length} 个',
        children: [
          if (mapping.rules.isEmpty)
            const MoeSettingsRow(
              label: '还没识别到标签',
              subtitle: '回复里的标签会按原样显示',
              trailingType: MoeSettingsRowTrailing.none,
            ),
          for (final rule in mapping.rules)
            MoeSettingsRow(
              key: ValueKey('tag-${rule.name}'),
              label: '<${rule.name}>',
              subtitle: [
                _tagSourceLabel(rule.source),
                if (rule.display == TagPresentation.fold) '标题「${rule.title}」',
              ].join(' · '),
              trailingType: MoeSettingsRowTrailing.text,
              detailText: _presentationLabel(rule.display),
              onTap: () => _pickPresentation(rule),
            ),
          for (final name in pending)
            MoeSettingsRow(
              key: ValueKey('tag-pending-$name'),
              label: '<$name>',
              subtitle: '提示词要求用它包裹输出，看不出怎么显示 · 待确认',
              trailingType: MoeSettingsRowTrailing.text,
              detailText: '原样',
              onTap: () => _pickNewPresentation(name),
            ),
          for (final name in discovered)
            MoeSettingsRow(
              key: ValueKey('tag-seen-$name'),
              label: '<$name>',
              subtitle: '聊天中发现 · 还没归类',
              trailingType: MoeSettingsRowTrailing.text,
              detailText: '原样',
              onTap: () => _pickNewPresentation(name),
            ),
          MoeSettingsRow(
            label: '添加标签',
            subtitle: '预设没识别出来的标签可以手动加',
            labelColor: colors.primary,
            trailingType: MoeSettingsRowTrailing.none,
            onTap: () async {
              final name = await _askTagName(context);
              if (name != null) _setPresentation(name, TagPresentation.fold);
            },
          ),
        ],
      ),
    ];
  }

  void _setPresentation(String name, TagPresentation? value) =>
      _change((port) => port.setTagPresentation(_id, name, value));

  void _pickNewPresentation(String name) => showMoeActionSheet(
    context: context,
    title: '<$name> 怎么显示',
    actions: [
      for (final value in TagPresentation.values)
        MoeSheetAction(
          label: _presentationLabel(value),
          onTap: () => _setPresentation(name, value),
        ),
    ],
  );

  void _pickPresentation(PresetTagRule rule) => showMoeActionSheet(
    context: context,
    title: '<${rule.name}> 怎么显示',
    actions: [
      for (final value in TagPresentation.values)
        MoeSheetAction(
          label: value == rule.display
              ? '${_presentationLabel(value)}（当前）'
              : _presentationLabel(value),
          onTap: () {
            if (value != rule.display) _setPresentation(rule.name, value);
          },
        ),
      if (rule.source == PresetTagSource.user)
        MoeSheetAction(
          label: '恢复自动识别',
          onTap: () => _setPresentation(rule.name, null),
        ),
    ],
  );
}

class _Missing extends StatelessWidget {
  const _Missing({required this.title, this.description, this.onRetry});

  final String title;
  final String? description;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Builder(
    builder: (context) => ListView(
      padding: moeUnderBarPadding(
        context,
        MoeSettingsLayout.verticalListPadding,
      ),
      children: [
        MoeSettingsGroup(
          padding: MoeSettingsLayout.contentPadding,
          children: [
            MoeEmptyState(
              title: title,
              description: description,
              action: onRetry == null
                  ? null
                  : TextButton(onPressed: onRetry, child: const Text('重试')),
            ),
          ],
        ),
      ],
    ),
  );
}

String _placementLabel(int placement) => switch (placement) {
  1 => '用户消息',
  2 => 'AI 回复',
  5 => '世界书',
  6 => '思考内容',
  _ => '暂不支持的位置 $placement',
};

String _tagSourceLabel(PresetTagSource source) => switch (source) {
  PresetTagSource.regex => '从预设正则识别',
  PresetTagSource.prompt => '提示词要求的输出格式',
  PresetTagSource.builtin => '常用标签',
  PresetTagSource.user => '手动设置',
};

String _presentationLabel(TagPresentation value) => switch (value) {
  TagPresentation.body => '正文',
  TagPresentation.fold => '折叠',
  TagPresentation.options => '选项',
};

final RegExp _tagNameInput = RegExp(r'^<?/?([^\s<>/]+)>?$');

Future<String?> _askTagName(BuildContext context) async {
  final controller = TextEditingController();
  try {
    final confirmed = await showMeoTalkDialog(
      context: context,
      title: '添加标签',
      cancelText: '取消',
      confirmText: '添加',
      content: MoeTextField(controller: controller, hint: '例如 ztl 或 <状态栏>'),
    );
    if (confirmed != true) return null;
    return _tagNameInput
        .firstMatch(controller.text.trim())
        ?.group(1)
        ?.toLowerCase();
  } finally {
    controller.dispose();
  }
}
