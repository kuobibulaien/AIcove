import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/services/prompt_tag_semantics_service.dart';
import '../../../../core/services/system_reminder_service.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/widgets/moe_app_bar.dart';
import '../../../../ui/shared/widgets/moe_toast.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../features/plugins/image/image_plugin.dart';
import '../../../../features/plugins/plugin_providers.dart';
import '../../../../features/plugins/time_awareness/time_awareness_plugin.dart';
import '../../../../features/plugins/tts/tts_plugin.dart';
import '../../../../features/plugins/domain/handlers/ai_tool.dart';
import '../../../../features/settings/app_settings.dart';

/// 插件提示词条目（UI 数据模型）
class _PluginPromptEntry {
  final String pluginId;
  final String pluginName;
  final IconData icon;
  final bool enabled;

  /// 当前提示词内容（从 config 读取）
  final String promptText;

  /// 提示词描述（告诉用户这段提示词的作用）
  final String description;

  /// 该插件注册的 AI 工具列表
  final List<AITool> tools;

  /// 保存回调
  final Future<void> Function(String newPrompt) onSave;

  const _PluginPromptEntry({
    required this.pluginId,
    required this.pluginName,
    required this.icon,
    required this.enabled,
    required this.promptText,
    required this.description,
    required this.tools,
    required this.onSave,
  });
}

class _TagSemanticsSummaryEntry {
  const _TagSemanticsSummaryEntry({
    required this.promptText,
    required this.tagNames,
    required this.description,
  });

  final String promptText;
  final List<String> tagNames;
  final String description;

  bool get enabled => tagNames.isNotEmpty && promptText.trim().isNotEmpty;
}

/// 工具提示词管理页面
///
/// 展示所有插件注入到 AI 对话中的系统提示词，支持编辑保存。
class ToolPromptsPage extends ConsumerStatefulWidget {
  const ToolPromptsPage({super.key});

  @override
  ConsumerState<ToolPromptsPage> createState() => _ToolPromptsPageState();
}

class _ToolPromptsPageState extends ConsumerState<ToolPromptsPage> {
  /// 全局 dirty 卡片集合，各卡片通过回调注册/注销
  final Set<String> _dirtyPluginIds = {};

  void _onDirtyChanged(String pluginId, bool dirty) {
    setState(() {
      if (dirty) {
        _dirtyPluginIds.add(pluginId);
      } else {
        _dirtyPluginIds.remove(pluginId);
      }
    });
  }

  bool get _hasUnsaved => _dirtyPluginIds.isNotEmpty;

  /// 弹窗询问用户是否放弃未保存修改
  Future<bool> _confirmDiscardOrSave() async {
    final colors = context.moeColors;
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.panel,
        title: Text('未保存的修改', style: TextStyle(color: colors.text)),
        content: Text(
          '你有未保存的提示词修改，离开后将丢失这些更改。',
          style: TextStyle(color: colors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('cancel'),
            child: Text('取消', style: TextStyle(color: colors.muted)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('discard'),
            child: Text('放弃修改', style: TextStyle(color: colors.dialogWarning)),
          ),
        ],
      ),
    );
    return result == 'discard';
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final entries = _buildEntries(ref);
    final tagSemanticsSummary = _buildTagSemanticsSummary(ref);

    return PopScope(
      canPop: !_hasUnsaved,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final navigator = Navigator.of(context);
        final discard = await _confirmDiscardOrSave();
        if (discard && mounted) {
          navigator.pop();
        }
      },
      child: Scaffold(
        backgroundColor: colors.surface,
        appBar: const MoeAppBar(title: '工具提示词管理', showBackButton: true),
        body: ListView(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
          children: [
            _TagSemanticsSummaryCard(entry: tagSemanticsSummary),
            if (entries.isNotEmpty) const SizedBox(height: 12),
            for (var index = 0; index < entries.length; index++) ...[
              _PluginPromptCard(
                entry: entries[index],
                onDirtyChanged: _onDirtyChanged,
              ),
              if (index != entries.length - 1) const SizedBox(height: 12),
            ],
          ],
        ),
      ),
    );
  }

  /// 从各插件 config provider 收集提示词条目
  List<_PluginPromptEntry> _buildEntries(WidgetRef ref) {
    final pluginManager = ref.watch(pluginManagerProvider);
    final entries = <_PluginPromptEntry>[];

    // === TTS ===
    final ttsConfig = ref.watch(ttsPluginConfigProvider);
    final ttsNotifier = ref.read(ttsPluginConfigProvider.notifier);
    final ttsPlugin = pluginManager.getPlugin('tts');
    entries.add(_PluginPromptEntry(
      pluginId: 'tts',
      pluginName: '语音合成 (TTS)',
      icon: Icons.record_voice_over_outlined,
      enabled: ttsConfig.enabled,
      promptText: ttsConfig.systemPromptTemplate,
      description: '指导 AI 何时、如何使用 <tts> 标签生成语音',
      tools: ttsPlugin?.getTools() ?? [],
      onSave: (text) => ttsNotifier.setSystemPromptTemplate(text),
    ));

    // === Image ===
    final imageConfig = ref.watch(imagePluginConfigProvider);
    final imageNotifier = ref.read(imagePluginConfigProvider.notifier);
    final imagePlugin = pluginManager.getPlugin('image');
    final imageEnabled =
        ref.watch(appSettingsProvider).valueOrNull?.imageGenerationEnabled ??
            false;
    entries.add(_PluginPromptEntry(
      pluginId: 'image',
      pluginName: '绘图工具',
      icon: Icons.brush_outlined,
      enabled: imageEnabled,
      promptText: imageConfig.manualToolDescriptionBlocks.promptDescription,
      description: 'draw_image.prompt 字段说明（固定块中的 prompt 描述）',
      tools: imagePlugin?.getTools() ?? [],
      onSave: (text) => imageNotifier.setDrawingSystemPrompt(text),
    ));

    // === Trigger ===
    final triggerConfig = ref.watch(triggerPluginConfigProvider);
    final triggerNotifier = ref.read(triggerPluginConfigProvider.notifier);
    final triggerPlugin = pluginManager.getPlugin('trigger');
    entries.add(_PluginPromptEntry(
      pluginId: 'trigger',
      pluginName: '主动关怀',
      icon: Icons.favorite_outline,
      enabled: triggerConfig.enabled,
      promptText: triggerConfig.logicSystemPrompt,
      description: '指导 AI 如何解析提醒/闹钟请求并输出触发器 JSON',
      tools: triggerPlugin?.getTools() ?? [],
      onSave: (text) => triggerNotifier.setLogicSystemPrompt(text),
    ));

    // === TimeAwareness ===
    final timeConfig = ref.watch(timeAwarenessPluginConfigProvider);
    final timeNotifier = ref.read(timeAwarenessPluginConfigProvider.notifier);
    final timePlugin = pluginManager.getPlugin('time_awareness');
    entries.add(_PluginPromptEntry(
      pluginId: 'time_awareness',
      pluginName: '时间感知',
      icon: Icons.schedule_outlined,
      enabled: timeConfig.enabled,
      promptText: timeConfig.currentTimePromptTemplate,
      description: '兼容保留项；当前实际时间感知已改走上方的 <system-reminder> 标签说明汇总',
      tools: timePlugin?.getTools() ?? [],
      onSave: (text) => timeNotifier.setCurrentTimePromptTemplate(text),
    ));

    // === Memory ===
    final memoryConfig = ref.watch(memoryPluginConfigProvider);
    final memoryNotifier = ref.read(memoryPluginConfigProvider.notifier);
    final memoryPlugin = pluginManager.getPlugin('memory');
    entries.add(_PluginPromptEntry(
      pluginId: 'memory',
      pluginName: '记忆库',
      icon: Icons.psychology_outlined,
      enabled: memoryConfig.enabled,
      promptText: memoryConfig.summarizePrompt,
      description: '记忆总结时使用的提示词（留空则使用内置默认值）',
      tools: memoryPlugin?.getTools() ?? [],
      onSave: (text) => memoryNotifier.setSummarizePrompt(text),
    ));

    // === Sticker ===
    final stickerConfig = ref.watch(stickerPluginConfigProvider);
    final stickerNotifier = ref.read(stickerPluginConfigProvider.notifier);
    final stickerPlugin = pluginManager.getPlugin('sticker');
    entries.add(_PluginPromptEntry(
      pluginId: 'sticker',
      pluginName: '表情包',
      icon: Icons.emoji_emotions_outlined,
      enabled: stickerConfig.enabled,
      promptText: stickerConfig.systemPromptTemplate,
      description: '指导 AI 何时发送表情包，{tags} 会被替换为可用标签列表',
      tools: stickerPlugin?.getTools() ?? [],
      onSave: (text) => stickerNotifier.setSystemPromptTemplate(text),
    ));

    return entries;
  }

  _TagSemanticsSummaryEntry _buildTagSemanticsSummary(WidgetRef ref) {
    final pluginManager = ref.watch(pluginManagerProvider);
    final promptTagSemanticsService =
        ref.watch(promptTagSemanticsServiceProvider);
    final systemReminderService = ref.watch(systemReminderServiceProvider);
    final timePlugin =
        pluginManager.getPlugin('time_awareness') as TimeAwarenessPlugin?;
    final ttsPlugin = pluginManager.getPlugin('tts') as TtsPlugin?;
    final imagePlugin = pluginManager.getPlugin('image') as ImagePlugin?;
    final systemReminderPrompt = () {
      if (timePlugin == null || !timePlugin.enabled) {
        return '';
      }
      final parts = <String>[
        systemReminderService.buildReminderSemanticsPrompt(),
        timePlugin.buildSystemReminderFieldGuide(),
      ];
      return parts
          .map((part) => part.trim())
          .where((part) => part.isNotEmpty)
          .join('\n');
    }();
    final snapshot = promptTagSemanticsService.buildSnapshot(
      <PromptTagSemanticsEntry>[
        if (systemReminderPrompt.isNotEmpty)
          PromptTagSemanticsEntry(
            id: 'system-reminder',
            tagName: '<system-reminder>',
            prompt: systemReminderPrompt,
          ),
        if ((ttsPlugin?.buildTagSemanticsPrompt()?.isNotEmpty ?? false))
          PromptTagSemanticsEntry(
            id: 'tts',
            tagName: '<tts>',
            prompt: ttsPlugin!.buildTagSemanticsPrompt()!,
          ),
        if ((imagePlugin?.buildTagSemanticsPrompt()?.isNotEmpty ?? false))
          PromptTagSemanticsEntry(
            id: 'image',
            tagName: '<image>',
            prompt: imagePlugin!.buildTagSemanticsPrompt()!,
          ),
      ],
    );
    return _TagSemanticsSummaryEntry(
      promptText: snapshot.mergedPrompt,
      tagNames: <String>[
        for (final entry in snapshot.activeEntries) entry.tagName,
      ],
      description:
          '汇总当前会实际注入到 system prompt 的标签说明。图片部分展示的是全局基础模板，角色专属追加规则会在真实会话里再拼上。',
    );
  }
}

class _TagSemanticsSummaryCard extends StatelessWidget {
  const _TagSemanticsSummaryCard({
    required this.entry,
  });

  final _TagSemanticsSummaryEntry entry;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final promptText = entry.promptText.trim();
    final enabledTagsText =
        entry.tagNames.isEmpty ? '当前没有启用的标签说明注入' : entry.tagNames.join('  ');

    return MoeG2ClipRRect(
      radius: 12,
      child: Container(
        decoration: MoeG2Decoration(
          radius: 12,
          color: colors.panel,
          border: Border.all(color: colors.border, width: 1),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.label_important_outline,
                      color: colors.primary, size: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              '标签说明汇总提示词',
                              style: TextStyle(
                                color: colors.text,
                                fontSize: 15,
                                fontWeight: MoeFontWeights.emphasis,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: MoeG2Decoration(
                                radius: 4,
                                color: entry.enabled
                                    ? colors.primary.withValues(alpha: 0.1)
                                    : colors.muted.withValues(alpha: 0.1),
                              ),
                              child: Text(
                                entry.enabled ? '已注入' : '未注入',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: entry.enabled
                                      ? colors.primary
                                      : colors.muted,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          entry.description,
                          style: TextStyle(
                              fontSize: 12, color: colors.textSecondary),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: MoeG2Decoration(
                  radius: 8,
                  color: colors.surface,
                ),
                child: Text(
                  enabledTagsText,
                  style: TextStyle(
                    fontSize: 12,
                    color: entry.enabled ? colors.text : colors.muted,
                    fontWeight: MoeFontWeights.emphasis,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                '当前汇总结果',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: MoeFontWeights.emphasis,
                  color: colors.textSecondary,
                ),
              ),
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: MoeG2Decoration(
                  radius: 8,
                  color: colors.surface,
                  border: Border.all(color: colors.border),
                ),
                child: SelectableText(
                  promptText.isEmpty ? '当前没有可注入的标签说明。' : promptText,
                  style: TextStyle(
                    fontSize: 13,
                    color: promptText.isEmpty ? colors.muted : colors.text,
                    height: 1.45,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 单个插件的提示词卡片
class _PluginPromptCard extends StatefulWidget {
  final _PluginPromptEntry entry;

  /// 当 dirty 状态变化时通知父页面
  final void Function(String pluginId, bool dirty) onDirtyChanged;

  const _PluginPromptCard({
    required this.entry,
    required this.onDirtyChanged,
  });

  @override
  State<_PluginPromptCard> createState() => _PluginPromptCardState();
}

class _PluginPromptCardState extends State<_PluginPromptCard> {
  late TextEditingController _controller;
  bool _expanded = false;
  bool _saving = false;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.entry.promptText);
  }

  @override
  void didUpdateWidget(covariant _PluginPromptCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 外部 config 变化且用户没有未保存编辑时，刷新内容
    if (!_dirty && widget.entry.promptText != _controller.text) {
      _controller.text = widget.entry.promptText;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _setDirty(bool value) {
    if (_dirty == value) return;
    setState(() => _dirty = value);
    widget.onDirtyChanged(widget.entry.pluginId, value);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await widget.entry.onSave(_controller.text);
      _setDirty(false);
      if (mounted) {
        MoeToast.show(context, '${widget.entry.pluginName} 提示词已保存');
      }
    } catch (e) {
      if (mounted) MoeToast.warning(context, '保存失败: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 收起卡片时，如果有未保存修改则弹窗确认
  Future<void> _handleCollapse() async {
    if (!_dirty) {
      setState(() => _expanded = false);
      return;
    }

    final colors = context.moeColors;
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.panel,
        title: Text('未保存的修改', style: TextStyle(color: colors.text)),
        content: Text(
          '「${widget.entry.pluginName}」的提示词已修改但未保存，你要怎么做？',
          style: TextStyle(color: colors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('cancel'),
            child: Text('继续编辑', style: TextStyle(color: colors.muted)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('discard'),
            child: Text('放弃修改', style: TextStyle(color: colors.dialogWarning)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop('save'),
            child: const Text('保存'),
          ),
        ],
      ),
    );

    if (!mounted) return;

    if (result == 'save') {
      await _save();
      if (mounted) setState(() => _expanded = false);
    } else if (result == 'discard') {
      _controller.text = widget.entry.promptText;
      _setDirty(false);
      setState(() => _expanded = false);
    }
    // 'cancel' or null: 保持展开
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final entry = widget.entry;

    return MoeG2ClipRRect(
      radius: 12,
      child: Container(
        decoration: MoeG2Decoration(
          radius: 12,
          color: colors.panel,
          border: Border.all(color: colors.border, width: 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ===== 头部：插件名 + 状态 + 展开箭头 =====
            InkWell(
              onTap: () {
                if (_expanded) {
                  _handleCollapse();
                } else {
                  setState(() => _expanded = true);
                }
              },
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    Icon(entry.icon, color: colors.primary, size: 22),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                entry.pluginName,
                                style: TextStyle(
                                  color: colors.text,
                                  fontSize: 15,
                                  fontWeight: MoeFontWeights.emphasis,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                decoration: MoeG2Decoration(
                                  radius: 4,
                                  color: entry.enabled
                                      ? colors.primary.withValues(alpha: 0.1)
                                      : colors.muted.withValues(alpha: 0.1),
                                ),
                                child: Text(
                                  entry.enabled ? '已启用' : '已禁用',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: entry.enabled
                                        ? colors.primary
                                        : colors.muted,
                                  ),
                                ),
                              ),
                              // dirty 指示器（头部也显示一个小圆点）
                              if (_dirty) ...[
                                const SizedBox(width: 6),
                                Container(
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                    color: colors.dialogWarning,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            entry.description,
                            style: TextStyle(
                                fontSize: 12, color: colors.textSecondary),
                          ),
                        ],
                      ),
                    ),
                    // 工具数量角标
                    if (entry.tools.isNotEmpty)
                      Container(
                        margin: const EdgeInsets.only(right: 6),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: MoeG2Decoration(
                          radius: 4,
                          color: colors.primary.withValues(alpha: 0.08),
                        ),
                        child: Text(
                          '${entry.tools.length} 工具',
                          style: TextStyle(fontSize: 10, color: colors.primary),
                        ),
                      ),
                    AnimatedRotation(
                      turns: _expanded ? 0.25 : 0,
                      duration: const Duration(milliseconds: 200),
                      child: Icon(Icons.chevron_right,
                          color: colors.muted, size: 20),
                    ),
                  ],
                ),
              ),
            ),

            // ===== 展开内容 =====
            if (_expanded) ...[
              Divider(height: 1, thickness: 1, color: colors.border),

              // 工具列表（如果有）
              if (entry.tools.isNotEmpty)
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '注册的 AI 工具',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: MoeFontWeights.emphasis,
                          color: colors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      for (final tool in entry.tools)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(Icons.build_outlined,
                                  size: 14, color: colors.primary),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text.rich(
                                  TextSpan(children: [
                                    TextSpan(
                                      text: tool.name,
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: MoeFontWeights.emphasis,
                                        color: colors.text,
                                      ),
                                    ),
                                    TextSpan(
                                      text: '  ${tool.description}',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: colors.textSecondary,
                                      ),
                                    ),
                                  ]),
                                ),
                              ),
                            ],
                          ),
                        ),
                      const SizedBox(height: 4),
                      Divider(height: 1, thickness: 1, color: colors.border),
                    ],
                  ),
                ),

              // 提示词编辑区
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
                child: Text(
                  '系统提示词',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: MoeFontWeights.emphasis,
                    color: colors.textSecondary,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: TextField(
                  controller: _controller,
                  maxLines: null,
                  minLines: 3,
                  style: TextStyle(fontSize: 13, color: colors.text),
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: colors.surface,
                    contentPadding: const EdgeInsets.all(10),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: colors.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: colors.border),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: colors.primary, width: 1.5),
                    ),
                    hintText: '输入系统提示词...',
                    hintStyle: TextStyle(color: colors.muted, fontSize: 13),
                  ),
                  onChanged: (_) {
                    final nowDirty =
                        _controller.text != widget.entry.promptText;
                    if (nowDirty != _dirty) _setDirty(nowDirty);
                  },
                ),
              ),

              // 保存按钮
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (_dirty)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Text(
                          '有未保存的修改',
                          style: TextStyle(
                              fontSize: 11, color: colors.dialogWarning),
                        ),
                      ),
                    SizedBox(
                      height: 32,
                      child: FilledButton.icon(
                        onPressed: _saving ? null : _save,
                        icon: _saving
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.save_outlined, size: 16),
                        label: const Text('保存', style: TextStyle(fontSize: 13)),
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
