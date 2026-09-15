import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/agent_context/domain/silly_tavern_preset.dart';
import '../../../../features/agent_context/domain/tavern_compatibility_port.dart';
import '../../../../features/agent_context/providers/preset_recipe_provider.dart';
import '../../../shared/animations/parallax_slide_page_route.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';

class TavernPluginDetailPage extends ConsumerWidget {
  const TavernPluginDetailPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(tavernPluginSettingsProvider);
    final presets = ref.watch(presetRecipeListProvider);
    final busy = ref.watch(presetRecipeImportControllerProvider).isLoading;
    final config = settings.valueOrNull;
    final list = presets.valueOrNull ?? const <PresetRecipeSummary>[];
    return MoePageScaffold(
      backgroundColor: context.moeColors.surface,
      appBar: const MoeAppBar(title: '酒馆兼容插件（测试）', showBackButton: true),
      body: MoeSettingsContent(
        child: ListView(
          padding: MoeSettingsLayout.verticalListPadding,
          children: [
            MoeSettingsGroup(
              padding: MoeSettingsLayout.contentPadding,
              children: [
                Text(
                  '插件预设',
                  style: TextStyle(fontSize: 18, color: context.moeColors.text),
                ),
                const SizedBox(height: 8),
                const Text(
                  '每套包含提示词预设、正则和世界书。角色可单独绑定；未绑定时使用标星的默认预设。修改会影响所有绑定角色，从下一次请求生效。',
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    MoePrimaryButton(
                      label: '导入预设',
                      onPressed: busy
                          ? null
                          : () => _run(context, () async {
                              final file = await _pickJson();
                              if (file == null || !context.mounted) return;
                              final controller = ref.read(
                                presetRecipeImportControllerProvider.notifier,
                              );
                              final preview = controller.previewSource(
                                file.source,
                                sourceFileName: file.name,
                              );
                              final confirmed = await showMeoTalkDialog(
                                context: context,
                                title: '导入「${preview.name}」',
                                confirmText: '导入',
                                content: Text(
                                  '${preview.prompts.length} 个提示词条目 · ${preview.regexScriptCount} 条正则\n'
                                  '导入后可以逐条开关。正则默认不授权执行。\n\n${preview.warnings.take(5).join('\n')}',
                                ),
                              );
                              if (confirmed != true || !context.mounted) {
                                return;
                              }
                              final preset = await controller.importSource(
                                file.source,
                                sourceFileName: file.name,
                              );
                              if (context.mounted) {
                                _openPreset(context, preset.id);
                              }
                            }),
                    ),
                    MoeSecondaryButton(
                      label: '创建基础组合',
                      onPressed: busy
                          ? null
                          : () => _run(context, () async {
                              final preset = await ref
                                  .read(
                                    presetRecipeImportControllerProvider
                                        .notifier,
                                  )
                                  .createBasicPreset();
                              if (context.mounted) {
                                _openPreset(context, preset.id);
                              }
                            }),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text('导入支持 JSON 文件。只想使用正则或世界书？先创建基础组合，再进入对应标签导入。'),
                if (config?.defaultPresetId != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: busy
                          ? null
                          : () => _run(
                              context,
                              () => ref
                                  .read(
                                    presetRecipeImportControllerProvider
                                        .notifier,
                                  )
                                  .change(
                                    null,
                                    (port) => port.savePluginSettings(
                                      const TavernPluginSettings(),
                                    ),
                                  ),
                            ),
                      child: const Text('取消默认预设（未绑定角色使用原模式）'),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: MoeSettingsLayout.sectionGap),
            if (settings.hasError || presets.hasError)
              MoeSettingsGroup(
                padding: MoeSettingsLayout.contentPadding,
                children: [
                  MoeEmptyState(
                    title: '读取失败',
                    description: '${settings.error ?? presets.error}',
                    action: Wrap(
                      children: [
                        TextButton(
                          onPressed: () {
                            ref.invalidate(tavernPluginSettingsProvider);
                            ref.invalidate(presetRecipeListProvider);
                          },
                          child: const Text('重试'),
                        ),
                        if (settings.hasError)
                          TextButton(
                            onPressed: busy
                                ? null
                                : () => _run(context, () async {
                                    final confirmed = await showMeoTalkDialog(
                                      context: context,
                                      title: '重置默认选择',
                                      confirmText: '确认重置',
                                      content: const Text(
                                        '清除默认预设选择；不删除预设、正则、世界书或角色绑定。重置后可重新选择默认预设。',
                                      ),
                                    );
                                    if (confirmed != true || !context.mounted) {
                                      return;
                                    }
                                    await ref
                                        .read(
                                          presetRecipeImportControllerProvider
                                              .notifier,
                                        )
                                        .change(
                                          null,
                                          (port) => port.savePluginSettings(
                                            const TavernPluginSettings(),
                                          ),
                                        );
                                  }),
                            child: const Text('重置默认选择'),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            if (settings.isLoading || presets.isLoading)
              const LinearProgressIndicator(),
            if (!presets.isLoading && list.isEmpty)
              const MoeSettingsGroup(
                padding: MoeSettingsLayout.contentPadding,
                children: [
                  MoeEmptyState(title: '还没有酒馆预设', description: '导入预设，或创建基础组合。'),
                ],
              ),
            for (final preset in list)
              Padding(
                padding: const EdgeInsets.only(
                  top: MoeSettingsLayout.sectionGap,
                ),
                child: MoeSettingsGroup(
                  children: [
                    MoeListTile(
                      title: Text(preset.name),
                      subtitle: Text(preset.description),
                      trailing: IconButton(
                        tooltip: config?.defaultPresetId == preset.id
                            ? '当前默认预设'
                            : '设为默认预设',
                        icon: Icon(
                          config?.defaultPresetId == preset.id
                              ? Icons.star
                              : Icons.star_border,
                          color: context.moeColors.primary,
                        ),
                        onPressed: busy || config == null
                            ? null
                            : () => _run(
                                context,
                                () => ref
                                    .read(
                                      presetRecipeImportControllerProvider
                                          .notifier,
                                    )
                                    .change(
                                      null,
                                      (port) => port.savePluginSettings(
                                        TavernPluginSettings(
                                          defaultPresetId: preset.id,
                                        ),
                                      ),
                                    ),
                              ),
                      ),
                      onTap: () => _openPreset(context, preset.id),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

void _openPreset(BuildContext context, String id) => Navigator.of(
  context,
).push(ParallaxSlidePageRoute(page: TavernPresetDetailPage(presetId: id)));

class TavernPresetDetailPage extends ConsumerWidget {
  final String presetId;
  const TavernPresetDetailPage({super.key, required this.presetId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(presetRecipeProvider(presetId));
    final busy = ref.watch(presetRecipeImportControllerProvider).isLoading;
    final controller = ref.read(presetRecipeImportControllerProvider.notifier);
    void change(Future<void> Function(TavernCompatibilityPort) action) =>
        _run(context, () => controller.change(presetId, action));
    return DefaultTabController(
      length: 3,
      child: MoePageScaffold(
        backgroundColor: context.moeColors.surface,
        appBar: MoeAppBar(
          title: value.valueOrNull?.name ?? '酒馆预设',
          showBackButton: true,
        ),
        body: MoeSettingsContent(
          child: value.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => MoeSettingsGroup(
              padding: MoeSettingsLayout.contentPadding,
              children: [
                MoeEmptyState(
                  title: '读取失败',
                  description: '$e',
                  action: TextButton(
                    onPressed: () =>
                        ref.invalidate(presetRecipeProvider(presetId)),
                    child: const Text('重试'),
                  ),
                ),
              ],
            ),
            data: (preset) {
              if (preset == null) {
                return const MoeSettingsGroup(
                  padding: MoeSettingsLayout.contentPadding,
                  children: [MoeEmptyState(title: '预设不存在或已损坏')],
                );
              }
              return Column(
                children: [
                  if (busy) const LinearProgressIndicator(),
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: MoeSettingsGroup(
                      padding: MoeSettingsLayout.contentPadding,
                      children: [
                        const Text('修改自动保存，从下一次请求生效；共享此预设的角色都会受影响。'),
                        const SizedBox(height: 8),
                        TabBar(
                          isScrollable: true,
                          labelColor: context.moeColors.primary,
                          tabs: [
                            Tab(
                              text: '预设 ${preset.selectedOrder.entries.length}',
                            ),
                            Tab(text: '正则 ${preset.regexScripts.length}'),
                            Tab(text: '世界书 ${preset.worldBooks.length}'),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: MoeSettingsLayout.sectionGap),
                  Expanded(
                    child: TabBarView(
                      children: [
                        _prompts(context, preset, busy, change),
                        _regex(context, ref, preset, busy, change),
                        _worldBooks(context, preset, busy, change),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _prompts(
    BuildContext context,
    SillyTavernPreset preset,
    bool busy,
    void Function(Future<void> Function(TavernCompatibilityPort)) change,
  ) {
    final order = preset.selectedOrder.entries;
    return ListView.separated(
      padding: MoeSettingsLayout.verticalListPadding,
      itemCount: order.length + 1,
      separatorBuilder: (_, _) =>
          const SizedBox(height: MoeSettingsLayout.sectionGap),
      itemBuilder: (context, index) {
        if (index == 0) {
          return MoeSettingsGroup(
            padding: EdgeInsets.zero,
            children: [_compatibilityNotice(preset)],
          );
        }
        final entry = order[index - 1];
        final prompt = preset.promptsById[entry.identifier];
        return MoeSettingsGroup(
          children: [
            MoeListTile(
              title: Text(prompt?.name ?? entry.identifier),
              subtitle: Text(
                prompt == null
                    ? '未找到正文，运行时跳过'
                    : '${prompt.role} · ${prompt.isAbsoluteInjection ? '深度 ${prompt.injectionDepth}' : '顺序 $index'}${prompt.marker ? ' · 动态内容' : ''}',
              ),
              trailing: MoeSwitch(
                key: ValueKey('prompt-${entry.identifier}'),
                value: entry.enabled,
                semanticLabel: '启用 ${prompt?.name ?? entry.identifier}',
                onChanged: busy || prompt == null
                    ? null
                    : (v) => change(
                        (port) => port.setPromptEnabled(
                          presetId,
                          entry.identifier,
                          v,
                        ),
                      ),
              ),
              onTap: () => _showText(
                context,
                prompt?.name ?? entry.identifier,
                prompt?.marker == true
                    ? '动态节点在发送时填入角色、世界书或聊天内容。关闭后不注入。'
                    : prompt?.content ?? '无内容',
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _regex(
    BuildContext context,
    WidgetRef ref,
    SillyTavernPreset preset,
    bool busy,
    void Function(Future<void> Function(TavernCompatibilityPort)) change,
  ) => ListView.separated(
    padding: MoeSettingsLayout.verticalListPadding,
    itemCount: preset.regexScripts.length + 2,
    separatorBuilder: (_, _) =>
        const SizedBox(height: MoeSettingsLayout.sectionGap),
    itemBuilder: (context, index) {
      if (index == 0) {
        return MoeSettingsGroup(
          padding: MoeSettingsLayout.contentPadding,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: MoeSecondaryButton(
                label: '导入正则',
                onPressed: busy
                    ? null
                    : () => _run(context, () async {
                        final file = await _pickJson();
                        if (file == null || !context.mounted) return;
                        await ref
                            .read(presetRecipeImportControllerProvider.notifier)
                            .change(
                              presetId,
                              (port) => port.importRegex(presetId, file.source),
                            );
                        if (context.mounted) {
                          MoeToast.success(context, '已导入正则，请检查条目与运行授权');
                        }
                      }),
              ),
            ),
            const SizedBox(height: 8),
            const Text('支持独立脚本、脚本数组及预设内正则。只改请求／显示副本，不修改聊天原文；不执行 JavaScript。'),
          ],
        );
      }
      if (index == 1) {
        return MoeSettingsGroup(
          children: [
            MoeListTile(
              title: const Text('授权此预设的正则运行'),
              subtitle: const Text('授权后，只有下方启用的规则才会执行'),
              trailing: MoeSwitch(
                key: const ValueKey('regex-authorization'),
                value: preset.regexAuthorized,
                onChanged: busy
                    ? null
                    : (v) => _run(
                        context,
                        () => ref
                            .read(presetRecipeImportControllerProvider.notifier)
                            .setRegexAuthorization(presetId, v),
                      ),
              ),
            ),
          ],
        );
      }
      final script = preset.regexScripts[index - 2];
      final phases = [
        if (script.promptOnly) '发送上下文',
        if (script.markdownOnly) '仅显示',
        if (!script.promptOnly && !script.markdownOnly) '原始处理（仅副本）',
      ];
      final placements = script.placements
          .map(
            (p) => switch (p) {
              1 => '用户消息',
              2 => 'AI 回复',
              5 => '世界书',
              6 => '推理',
              _ => '未支持位置 $p',
            },
          )
          .join('、');
      return MoeSettingsGroup(
        children: [
          MoeListTile(
            title: Text(script.name),
            subtitle: Text(
              '${phases.join('／')} · $placements'
              '${script.substituteRegex != 0 ? '\n正则模式宏替换暂不支持，该规则不执行' : ''}',
            ),
            trailing: MoeSwitch(
              key: ValueKey('regex-${script.id}'),
              value: !script.disabled,
              semanticLabel: '启用 ${script.name}',
              onChanged: busy
                  ? null
                  : (v) => change(
                      (port) => port.setRegexEnabled(presetId, script.id, v),
                    ),
            ),
            onTap: () => _showText(
              context,
              script.name,
              '查找：\n${script.findRegex}\n\n替换：\n${script.replaceString}',
            ),
          ),
        ],
      );
    },
  );

  Widget _worldBooks(
    BuildContext context,
    SillyTavernPreset preset,
    bool busy,
    void Function(Future<void> Function(TavernCompatibilityPort)) change,
  ) {
    final rows = <Widget>[
      MoeSettingsGroup(
        padding: MoeSettingsLayout.contentPadding,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: MoeSecondaryButton(
              label: '导入世界书',
              onPressed: busy
                  ? null
                  : () => _run(context, () async {
                      final file = await _pickJson();
                      if (file == null || !context.mounted) return;
                      change(
                        (port) => port.importWorldBook(
                          presetId,
                          file.source,
                          file.name,
                        ),
                      );
                    }),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            '扫描最近聊天，按关键词或常驻状态触发。支持角色定义前／后及聊天深度注入。每本默认 2048 token，合计最多可用上下文的 25%；估算预算，超出条目不注入。',
          ),
        ],
      ),
      if (preset.worldBooks.isEmpty)
        const MoeSettingsGroup(
          padding: MoeSettingsLayout.contentPadding,
          children: [MoeEmptyState(title: '尚未导入世界书')],
        ),
    ];
    for (final book in preset.worldBooks) {
      rows.add(
        MoeSettingsGroup(
          children: [
            MoeListTile(
              title: Text(book.name),
              subtitle: Text(
                '${book.entries.length} 个条目 · 每本预算 ${book.tokenBudget} token',
              ),
              trailing: MoeSwitch(
                key: ValueKey('book-${book.id}'),
                value: book.enabled,
                semanticLabel: '启用世界书 ${book.name}',
                onChanged: busy
                    ? null
                    : (v) => change(
                        (port) =>
                            port.setWorldBookEnabled(presetId, book.id, v),
                      ),
              ),
            ),
            for (final warning in book.warnings)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: Text(
                  warning,
                  style: TextStyle(color: context.moeColors.toastWarning),
                ),
              ),
          ],
        ),
      );
      for (final entry in book.entries) {
        rows.add(
          MoeSettingsGroup(
            children: [
              MoeListTile(
                title: Text(entry.name),
                subtitle: Text(
                  '${entry.constant ? '常驻' : '关键词：${entry.keys.join('、')}'}\n'
                  '${entry.positionLabel} · 顺序 ${entry.order} · 扫描 ${entry.scanDepth} 条'
                  '${!book.enabled ? '\n整本已关闭' : ''}'
                  '${entry.unsupported.isNotEmpty ? '\n不执行：${entry.unsupported.join('、')} 尚不支持' : ''}',
                ),
                trailing: MoeSwitch(
                  key: ValueKey('world-${book.id}-${entry.id}'),
                  value: entry.enabled,
                  semanticLabel: '启用 ${entry.name}',
                  onChanged: busy
                      ? null
                      : (v) => change(
                          (port) => port.setWorldEntryEnabled(
                            presetId,
                            book.id,
                            entry.id,
                            v,
                          ),
                        ),
                ),
                onTap: () => _showText(context, entry.name, entry.content),
              ),
            ],
          ),
        );
      }
    }
    return ListView.separated(
      padding: MoeSettingsLayout.verticalListPadding,
      itemCount: rows.length,
      separatorBuilder: (_, _) =>
          const SizedBox(height: MoeSettingsLayout.sectionGap),
      itemBuilder: (_, index) => rows[index],
    );
  }
}

Widget _compatibilityNotice(SillyTavernPreset preset) => ExpansionTile(
  tilePadding: const EdgeInsets.symmetric(horizontal: 12),
  childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
  title: const Text('兼容说明与提示'),
  subtitle: const Text('按导入顺序执行；点击条目查看内容'),
  children: [
    Text(
      [
        '测试版：作者注、示例对话、Outlet、世界书递归／向量／分组／定时触发后续支持。',
        '世界书常见 {{char}}／{{user}} 宏可用；正则不执行脚本。',
        ...preset.warnings,
      ].join('\n\n'),
    ),
  ],
);

Future<({String name, String source})?> _pickJson() async {
  final result = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: const ['json'],
    withData: true,
  );
  if (result == null || result.files.isEmpty) return null;
  final file = result.files.single;
  if (file.size > 2 * 1024 * 1024) {
    throw const FormatException('文件超过 2 MB，已拒绝导入');
  }
  final bytes = file.bytes ?? await file.xFile.readAsBytes();
  if (bytes.length > 2 * 1024 * 1024) {
    throw const FormatException('文件超过 2 MB，已拒绝导入');
  }
  return (name: file.name, source: utf8.decode(bytes));
}

Future<void> _run(BuildContext context, Future<void> Function() action) async {
  try {
    await action();
  } catch (error) {
    if (context.mounted) MoeToast.error(context, '$error');
  }
}

void _showText(BuildContext context, String title, String text) =>
    showMeoTalkDialog(
      context: context,
      title: title,
      confirmText: '知道了',
      content: SizedBox(
        height: MediaQuery.sizeOf(context).height * .45,
        child: SingleChildScrollView(child: SelectableText(text)),
      ),
    );
