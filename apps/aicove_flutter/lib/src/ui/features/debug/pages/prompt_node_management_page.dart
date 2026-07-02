import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/prompts/prompt_custom_nodes.dart';
import '../../../../features/agent_context/data/agent_context_defaults_loader.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/theme/tokens.dart';

enum _PromptNodeFilter { all, graph, graphMissing, attention }

enum _RuntimePromptStatus { active, configurable, helperOnly, legacy }

class _RuntimePromptUsage {
  const _RuntimePromptUsage({
    required this.area,
    required this.summary,
    required this.status,
  });

  final String area;
  final String summary;
  final _RuntimePromptStatus status;
}

class _PromptDefaultNode {
  const _PromptDefaultNode({
    required this.id,
    required this.title,
    required this.category,
    required this.description,
    required this.dartName,
    required this.variables,
    required this.template,
  });

  final String id;
  final String title;
  final String category;
  final String description;
  final String dartName;
  final List<String> variables;
  final String template;

  factory _PromptDefaultNode.fromJson(Map<String, Object?> json) {
    final id = _readString(json['id']);
    return _PromptDefaultNode(
      id: id,
      title: _readString(json['title'], fallback: id),
      category: _readString(json['category'], fallback: 'uncategorized'),
      description: _readString(json['description']),
      dartName: _readString(json['dartName']),
      variables: _readStringList(json['variables']),
      template: _readString(json['template']),
    );
  }
}

class _PromptGraphLink {
  const _PromptGraphLink({
    required this.agentId,
    required this.agentName,
    required this.stageLabel,
    required this.slot,
  });

  final String agentId;
  final String agentName;
  final String stageLabel;
  final String slot;
}

class _PromptNodeSnapshot {
  const _PromptNodeSnapshot({
    required this.prompts,
    required this.graphLinksByPromptId,
    required this.customNodes,
  });

  final List<_PromptDefaultNode> prompts;
  final Map<String, List<_PromptGraphLink>> graphLinksByPromptId;
  final List<PromptCustomNode> customNodes;

  int get graphNodeCount => graphLinksByPromptId.length;

  int get attentionCount => prompts
      .where(
          (prompt) => _attentionStatuses.contains(_usageFor(prompt.id).status))
      .length;

  int get customNodeCount => customNodes.length;

  Set<String> get defaultPromptIds =>
      prompts.map((prompt) => prompt.id).toSet();
}

const _attentionStatuses = <_RuntimePromptStatus>{
  _RuntimePromptStatus.helperOnly,
  _RuntimePromptStatus.legacy,
};

const _runtimeUsages = <String, _RuntimePromptUsage>{
  'auto_reply.analyzer.default': _RuntimePromptUsage(
    area: '主动关怀分析',
    summary:
        '作为 AutoReplySettings 的默认 analyzerPrompt，ContextAnalyzer 会把它渲染后交给后台 Agent。',
    status: _RuntimePromptStatus.configurable,
  ),
  'auto_reply.agent.objective': _RuntimePromptUsage(
    area: '主动关怀回复生成',
    summary:
        '已进入 Agent Build 的 reply_generation 节点；当前 Dart 预生成路径未直接调用对应 helper。',
    status: _RuntimePromptStatus.helperOnly,
  ),
  'auto_reply.background.objective': _RuntimePromptUsage(
    area: '主动关怀后台生成',
    summary: 'WorkManager 后台即时生成主动回复时的系统提示词：注入角色人设、当前时间与后台纯文本输出约束。',
    status: _RuntimePromptStatus.active,
  ),
  'enhanced_dialogue.system.default': _RuntimePromptUsage(
    area: '增强对话',
    summary: '作为增强对话默认 system prompt，功能启用时参与生成。',
    status: _RuntimePromptStatus.configurable,
  ),
  'enhanced_dialogue.bootstrap_user.default': _RuntimePromptUsage(
    area: '增强对话',
    summary: '作为增强对话第一条用户指令默认值，功能启用时参与生成。',
    status: _RuntimePromptStatus.configurable,
  ),
  'enhanced_dialogue.original_persona_merge': _RuntimePromptUsage(
    area: '增强对话',
    summary: '用于把增强指令与当前会话原始人设合并。',
    status: _RuntimePromptStatus.active,
  ),
  'image.tool.description.default': _RuntimePromptUsage(
    area: '绘图工具',
    summary: '用于 draw_image 工具说明。',
    status: _RuntimePromptStatus.configurable,
  ),
  'image.tool.prompt_description.default': _RuntimePromptUsage(
    area: '绘图工具',
    summary: '用于 draw_image.prompt 参数说明。',
    status: _RuntimePromptStatus.configurable,
  ),
  'image.tool.negative_prompt_description.default': _RuntimePromptUsage(
    area: '绘图工具',
    summary: '用于 draw_image.negative_prompt 参数说明。',
    status: _RuntimePromptStatus.configurable,
  ),
  'image.tool.width_description.default': _RuntimePromptUsage(
    area: '绘图工具',
    summary: '用于 draw_image.width 参数说明。',
    status: _RuntimePromptStatus.configurable,
  ),
  'image.tool.height_description.default': _RuntimePromptUsage(
    area: '绘图工具',
    summary: '用于 draw_image.height 参数说明。',
    status: _RuntimePromptStatus.configurable,
  ),
  'image.inline.default': _RuntimePromptUsage(
    area: '绘图标签',
    summary: '作为 <image> 标签生成提示词模板。',
    status: _RuntimePromptStatus.configurable,
  ),
  'image.system.default': _RuntimePromptUsage(
    area: '绘图提示词',
    summary: '作为绘图系统提示词默认预设。',
    status: _RuntimePromptStatus.configurable,
  ),
  'tts.system.default': _RuntimePromptUsage(
    area: '语音标签',
    summary: '作为 <tts> 标签语义默认提示词。',
    status: _RuntimePromptStatus.configurable,
  ),
  'tts.minimax_guide': _RuntimePromptUsage(
    area: '语音标签',
    summary: 'MiniMax 语音场景的补充指引。',
    status: _RuntimePromptStatus.active,
  ),
  'tts.disabled_voice_frequency': _RuntimePromptUsage(
    area: '语音标签',
    summary: '语音不可用时约束模型不要频繁输出语音。',
    status: _RuntimePromptStatus.active,
  ),
  'sticker.system.default': _RuntimePromptUsage(
    area: '表情包',
    summary: '作为表情包插件默认 system prompt。',
    status: _RuntimePromptStatus.configurable,
  ),
  'trigger.logic.legacy_default': _RuntimePromptUsage(
    area: '提醒工具旧逻辑',
    summary: '遗留配置保留回看；当前主链路不再额外注入这段 system prompt。',
    status: _RuntimePromptStatus.legacy,
  ),
  'time_awareness.system.default': _RuntimePromptUsage(
    area: '时间感知',
    summary: '作为时间感知插件 system prompt。',
    status: _RuntimePromptStatus.configurable,
  ),
  'time_awareness.reminder.default': _RuntimePromptUsage(
    area: '时间感知',
    summary: '用于生成 <system-reminder> 的时间上下文文本。',
    status: _RuntimePromptStatus.configurable,
  ),
  'memory.summary.default': _RuntimePromptUsage(
    area: '记忆总结',
    summary: '作为记忆总结 BackgroundAgent 的默认 objectivePrompt。',
    status: _RuntimePromptStatus.configurable,
  ),
  'memory.summary.extra_instruction': _RuntimePromptUsage(
    area: '记忆总结',
    summary: '作为记忆总结 extraInstruction 的固定前置说明。',
    status: _RuntimePromptStatus.active,
  ),
  'memory.summary.role_persona.generic_instruction': _RuntimePromptUsage(
    area: '记忆总结',
    summary: '用于角色专属记忆总结的通用约束。',
    status: _RuntimePromptStatus.active,
  ),
  'memory.summary.role_persona.context_instruction': _RuntimePromptUsage(
    area: '记忆总结',
    summary: '用于拼接角色名称、称呼和人设摘要。',
    status: _RuntimePromptStatus.active,
  ),
  'memory.role_scoped.root': _RuntimePromptUsage(
    area: '记忆注入',
    summary: '用于把召回记忆组织为角色专属上下文。',
    status: _RuntimePromptStatus.active,
  ),
  'memory.profile_prompt.root': _RuntimePromptUsage(
    area: '用户画像',
    summary: '用于格式化 L1 用户画像记忆。',
    status: _RuntimePromptStatus.active,
  ),
  'system_reminder.semantics': _RuntimePromptUsage(
    area: '系统提醒',
    summary: '用于说明 <system-reminder> 标签语义。',
    status: _RuntimePromptStatus.active,
  ),
  'prompt_tag_semantics.lead_in': _RuntimePromptUsage(
    area: '标签说明汇总',
    summary: '用于合并多个标签说明时的前置说明。',
    status: _RuntimePromptStatus.active,
  ),
  'multimodal.vision.system': _RuntimePromptUsage(
    area: '多模态理解',
    summary: '用于图片理解辅助模型。',
    status: _RuntimePromptStatus.active,
  ),
  'multimodal.audio.system': _RuntimePromptUsage(
    area: '多模态理解',
    summary: '用于音频理解辅助模型。',
    status: _RuntimePromptStatus.active,
  ),
  'multimodal.video.system': _RuntimePromptUsage(
    area: '多模态理解',
    summary: '用于视频理解辅助模型。',
    status: _RuntimePromptStatus.active,
  ),
  'chat.draw_image.stable_review_instruction': _RuntimePromptUsage(
    area: '聊天绘图',
    summary: '用于绘图结果稳定性审核。',
    status: _RuntimePromptStatus.active,
  ),
  'diary.generate.default': _RuntimePromptUsage(
    area: '角色日记',
    summary: '用于生成角色视角日记。',
    status: _RuntimePromptStatus.active,
  ),
  'memory.merge.prompt': _RuntimePromptUsage(
    area: '记忆合并',
    summary: '用于将新事实合并进已有 L2 记忆。',
    status: _RuntimePromptStatus.active,
  ),
  'memory.reenrich.default': _RuntimePromptUsage(
    area: '记忆重丰富',
    summary: '用于重新丰富被压缩标记的记忆。',
    status: _RuntimePromptStatus.active,
  ),
};

class PromptNodeManagementPage extends StatefulWidget {
  const PromptNodeManagementPage({
    super.key,
    AssetBundle? assetBundle,
    AgentContextDefaultsLoader? defaultsLoader,
    PromptCustomNodeStore? customNodeStore,
  })  : _assetBundle = assetBundle,
        _defaultsLoader = defaultsLoader,
        _customNodeStore = customNodeStore;

  final AssetBundle? _assetBundle;
  final AgentContextDefaultsLoader? _defaultsLoader;
  final PromptCustomNodeStore? _customNodeStore;

  @override
  State<PromptNodeManagementPage> createState() =>
      _PromptNodeManagementPageState();
}

class _PromptNodeManagementPageState extends State<PromptNodeManagementPage> {
  late Future<_PromptNodeSnapshot> _snapshotFuture;
  _PromptNodeFilter _filter = _PromptNodeFilter.all;

  PromptCustomNodeStore get _customNodeStore =>
      widget._customNodeStore ?? PromptCustomNodeStore.instance;

  @override
  void initState() {
    super.initState();
    _snapshotFuture = _loadSnapshot();
  }

  void _reloadSnapshot() {
    setState(() {
      _snapshotFuture = _loadSnapshot();
    });
  }

  Future<_PromptNodeSnapshot> _loadSnapshot() async {
    final assetBundle = widget._assetBundle ?? rootBundle;
    final rawPromptDefaults =
        await assetBundle.loadString('assets/prompt_defaults.json');
    final promptDocument = _readObject(jsonDecode(rawPromptDefaults));
    final prompts = _readObjectList(promptDocument['prompts'])
        .map(_PromptDefaultNode.fromJson)
        .toList(growable: false)
      ..sort((a, b) {
        final category = a.category.compareTo(b.category);
        if (category != 0) return category;
        return a.id.compareTo(b.id);
      });

    final defaults = await (widget._defaultsLoader ??
            AgentContextDefaultsLoader(bundle: widget._assetBundle))
        .load();
    final graphLinks = <String, List<_PromptGraphLink>>{};
    for (final agent in defaults.agents) {
      for (final node in agent.agentGraph.nodes) {
        if (node.nodeType != 'prompt') continue;
        final links = graphLinks.putIfAbsent(
          node.nodeId,
          () => <_PromptGraphLink>[],
        );
        links.add(_PromptGraphLink(
          agentId: agent.id,
          agentName: agent.name,
          stageLabel: _readString(
            node.config['stageLabel'],
            fallback: _readString(node.config['stage']),
          ),
          slot: node.slot ?? '',
        ));
      }
    }
    final promptIds = prompts.map((prompt) => prompt.id).toSet();
    final customNodes = (await _customNodeStore.load())
        .where((node) => !promptIds.contains(node.id))
        .toList(growable: false);
    return _PromptNodeSnapshot(
      prompts: prompts,
      graphLinksByPromptId: graphLinks,
      customNodes: customNodes,
    );
  }

  Future<bool> _saveCustomNode(
    _PromptNodeSnapshot snapshot,
    PromptCustomNode node,
  ) async {
    try {
      await _customNodeStore.addNode(
        node,
        reservedIds: snapshot.defaultPromptIds,
      );
    } catch (e) {
      if (mounted) {
        MoeToast.warning(context, '保存失败: $e');
      }
      return false;
    }
    if (!mounted) return true;
    _reloadSnapshot();
    MoeToast.show(context, '自定义节点已保存');
    return true;
  }

  Future<void> _openCustomNodeEditor(_PromptNodeSnapshot snapshot) {
    return showMoeBottomSheet<void>(
      context: context,
      title: '新增自定义节点',
      maxHeight: MediaQuery.sizeOf(context).height * 0.9,
      builder: (context) => _CustomPromptNodeSheet(
        onSave: (node) => _saveCustomNode(snapshot, node),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    return Scaffold(
      backgroundColor: colors.surface,
      appBar: const MoeAppBar(title: '提示词节点', showBackButton: true),
      body: FutureBuilder<_PromptNodeSnapshot>(
        future: _snapshotFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: MoeLoadingIndicator());
          }
          if (snapshot.hasError || snapshot.data == null) {
            return MoeEmptyState(
              icon: Icons.error_outline,
              title: '读取失败',
              description: snapshot.error?.toString() ?? '无法读取提示词节点配置',
            );
          }
          final data = snapshot.data!;
          final prompts = _applyFilter(data);
          final customNodes = _filter == _PromptNodeFilter.all
              ? data.customNodes
              : const <PromptCustomNode>[];
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _SummaryPanel(snapshot: data),
              const SizedBox(height: 14),
              Align(
                alignment: Alignment.centerLeft,
                child: MoePrimaryButton(
                  label: '新增自定义节点',
                  icon: Icons.add_rounded,
                  size: MoePrimaryButtonSize.sm,
                  onPressed: () => _openCustomNodeEditor(data),
                ),
              ),
              const SizedBox(height: 14),
              MoeToggleBar<_PromptNodeFilter>(
                value: _filter,
                items: const [
                  MoeToggleItem(value: _PromptNodeFilter.all, label: '全部'),
                  MoeToggleItem(value: _PromptNodeFilter.graph, label: '图内'),
                  MoeToggleItem(
                    value: _PromptNodeFilter.graphMissing,
                    label: '图外',
                  ),
                  MoeToggleItem(
                    value: _PromptNodeFilter.attention,
                    label: '关注',
                  ),
                ],
                onChanged: (value) => setState(() => _filter = value),
              ),
              const SizedBox(height: 14),
              for (var index = 0; index < prompts.length; index++) ...[
                _PromptNodeCard(
                  prompt: prompts[index],
                  graphLinks: data.graphLinksByPromptId[prompts[index].id] ??
                      const <_PromptGraphLink>[],
                ),
                if (index != prompts.length - 1) const SizedBox(height: 10),
              ],
              if (customNodes.isNotEmpty) ...[
                const SizedBox(height: 18),
                _SectionTitle(
                  title: '自定义节点',
                  count: customNodes.length,
                ),
                const SizedBox(height: 10),
                for (var index = 0; index < customNodes.length; index++) ...[
                  _CustomPromptNodeCard(node: customNodes[index]),
                  if (index != customNodes.length - 1)
                    const SizedBox(height: 10),
                ],
              ],
              if (prompts.isEmpty && customNodes.isEmpty)
                const MoeEmptyState(
                  icon: Icons.search_off_outlined,
                  title: '没有匹配项',
                  description: '当前筛选条件下没有提示词节点',
                ),
            ],
          );
        },
      ),
    );
  }

  List<_PromptDefaultNode> _applyFilter(_PromptNodeSnapshot snapshot) {
    switch (_filter) {
      case _PromptNodeFilter.all:
        return snapshot.prompts;
      case _PromptNodeFilter.graph:
        return snapshot.prompts
            .where((prompt) =>
                snapshot.graphLinksByPromptId.containsKey(prompt.id))
            .toList(growable: false);
      case _PromptNodeFilter.graphMissing:
        return snapshot.prompts
            .where((prompt) =>
                !snapshot.graphLinksByPromptId.containsKey(prompt.id))
            .toList(growable: false);
      case _PromptNodeFilter.attention:
        return snapshot.prompts
            .where((prompt) =>
                _attentionStatuses.contains(_usageFor(prompt.id).status))
            .toList(growable: false);
    }
  }
}

class _SummaryPanel extends StatelessWidget {
  const _SummaryPanel({required this.snapshot});

  final _PromptNodeSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final graphMissing = snapshot.prompts.length - snapshot.graphNodeCount;
    return MoeG2ClipRRect(
      radius: 12,
      child: Container(
        decoration: MoeG2Decoration(
          radius: 12,
          color: colors.panel,
          border: Border.all(color: colors.border),
        ),
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '节点概览',
              style: TextStyle(
                color: colors.text,
                fontSize: 16,
                fontWeight: MoeFontWeights.emphasis,
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _MetricChip(
                    label: '内置提示词', value: '${snapshot.prompts.length}'),
                _MetricChip(
                    label: 'Agent Build', value: '${snapshot.graphNodeCount}'),
                _MetricChip(label: '图外运行', value: '$graphMissing'),
                _MetricChip(label: '关注项', value: '${snapshot.attentionCount}'),
                _MetricChip(
                    label: '自定义节点', value: '${snapshot.customNodeCount}'),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              '图外运行表示该提示词在 Dart 链路中使用，但尚未进入 Agent Build 图。',
              style: TextStyle(
                color: colors.textSecondary,
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({
    required this.title,
    required this.count,
  });

  final String title;
  final int count;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    return Row(
      children: [
        Text(
          title,
          style: TextStyle(
            color: colors.text,
            fontSize: 16,
            fontWeight: MoeFontWeights.emphasis,
          ),
        ),
        const SizedBox(width: 8),
        _StatusChip(label: '$count', color: colors.textSecondary),
      ],
    );
  }
}

class _MetricChip extends StatelessWidget {
  const _MetricChip({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: MoeG2Decoration(
        radius: 8,
        color: colors.surface,
        border: Border.all(color: colors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value,
            style: TextStyle(
              color: colors.primary,
              fontSize: 15,
              fontWeight: MoeFontWeights.emphasis,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(color: colors.textSecondary, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _PromptNodeCard extends StatelessWidget {
  const _PromptNodeCard({
    required this.prompt,
    required this.graphLinks,
  });

  final _PromptDefaultNode prompt;
  final List<_PromptGraphLink> graphLinks;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final usage = _usageFor(prompt.id);
    return MoeG2ClipRRect(
      radius: 12,
      child: Container(
        decoration: MoeG2Decoration(
          radius: 12,
          color: colors.panel,
          border: Border.all(color: colors.border),
        ),
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            iconColor: colors.textSecondary,
            collapsedIconColor: colors.muted,
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  prompt.title,
                  style: TextStyle(
                    color: colors.text,
                    fontSize: 15,
                    fontWeight: MoeFontWeights.emphasis,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  prompt.id,
                  style: TextStyle(color: colors.muted, fontSize: 12),
                ),
              ],
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  _StatusChip(
                    label: prompt.category,
                    color: colors.textSecondary,
                  ),
                  _RuntimeStatusChip(status: usage.status),
                  _StatusChip(
                    label: graphLinks.isEmpty ? '图外' : 'Agent Build',
                    color: graphLinks.isEmpty ? colors.muted : colors.primary,
                  ),
                  _StatusChip(label: '默认只读', color: colors.muted),
                ],
              ),
            ),
            children: [
              _DetailBlock(
                title: '运行用途',
                body: '${usage.area}：${usage.summary}',
              ),
              if (graphLinks.isNotEmpty)
                _DetailBlock(
                  title: 'Agent Build',
                  body: graphLinks
                      .map((link) => [
                            link.agentName,
                            link.stageLabel,
                            if (link.slot.isNotEmpty) link.slot,
                          ].where((part) => part.isNotEmpty).join(' / '))
                      .join('\n'),
                ),
              if (prompt.variables.isNotEmpty)
                _DetailBlock(
                  title: '变量',
                  body: prompt.variables.join(', '),
                ),
              if (prompt.description.isNotEmpty)
                _DetailBlock(
                  title: '说明',
                  body: prompt.description,
                ),
              if (prompt.dartName.isNotEmpty)
                _DetailBlock(
                  title: 'Dart 常量',
                  body: 'PromptBuiltinDefaults.${prompt.dartName}',
                ),
              if (prompt.template.trim().isNotEmpty)
                _DetailBlock(
                  title: '模板预览',
                  body: prompt.template.trim(),
                  selectable: true,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CustomPromptNodeCard extends StatelessWidget {
  const _CustomPromptNodeCard({required this.node});

  final PromptCustomNode node;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    return MoeG2ClipRRect(
      radius: 12,
      child: Container(
        decoration: MoeG2Decoration(
          radius: 12,
          color: colors.panel,
          border: Border.all(color: colors.border),
        ),
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            iconColor: colors.textSecondary,
            collapsedIconColor: colors.muted,
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  node.title,
                  style: TextStyle(
                    color: colors.text,
                    fontSize: 15,
                    fontWeight: MoeFontWeights.emphasis,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  node.id,
                  style: TextStyle(color: colors.muted, fontSize: 12),
                ),
              ],
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  _StatusChip(
                    label: node.category,
                    color: colors.textSecondary,
                  ),
                  _StatusChip(label: '自定义', color: colors.primary),
                ],
              ),
            ),
            children: [
              if (node.variables.isNotEmpty)
                _DetailBlock(
                  title: '变量',
                  body: node.variables.join(', '),
                ),
              if (node.description.isNotEmpty)
                _DetailBlock(
                  title: '说明',
                  body: node.description,
                ),
              _DetailBlock(
                title: '模板预览',
                body: node.template,
                selectable: true,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CustomPromptNodeSheet extends StatefulWidget {
  const _CustomPromptNodeSheet({required this.onSave});

  final Future<bool> Function(PromptCustomNode node) onSave;

  @override
  State<_CustomPromptNodeSheet> createState() => _CustomPromptNodeSheetState();
}

class _CustomPromptNodeSheetState extends State<_CustomPromptNodeSheet> {
  final TextEditingController _idController = TextEditingController();
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _categoryController =
      TextEditingController(text: 'custom');
  final TextEditingController _descriptionController = TextEditingController();
  final TextEditingController _variablesController = TextEditingController();
  final TextEditingController _templateController = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _idController.dispose();
    _titleController.dispose();
    _categoryController.dispose();
    _descriptionController.dispose();
    _variablesController.dispose();
    _templateController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final saved = await widget.onSave(
      PromptCustomNode(
        id: _idController.text,
        title: _titleController.text,
        category: _categoryController.text,
        description: _descriptionController.text,
        variables: _variablesController.text
            .split(',')
            .map((item) => item.trim())
            .where((item) => item.isNotEmpty)
            .toList(growable: false),
        template: _templateController.text,
      ),
    );
    if (saved && mounted) {
      Navigator.of(context).pop();
    }
    if (!saved && mounted) {
      setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        MoeTextField(
          label: '节点 ID',
          hint: 'custom.prompt.example',
          controller: _idController,
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: 12),
        MoeTextField(
          label: '标题',
          hint: '自定义提示词',
          controller: _titleController,
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: 12),
        MoeTextField(
          label: '分类',
          hint: 'custom',
          controller: _categoryController,
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: 12),
        MoeTextField(
          label: '说明',
          hint: '可选',
          controller: _descriptionController,
          maxLines: 2,
        ),
        const SizedBox(height: 12),
        MoeTextField(
          label: '变量',
          hint: 'name, context',
          controller: _variablesController,
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: 12),
        MoeTextField(
          label: '提示词模板',
          hint: '输入提示词模板',
          controller: _templateController,
          minLines: 8,
          maxLines: 14,
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: MoeSecondaryButton(
                label: '取消',
                icon: Icons.close_rounded,
                enabled: !_saving,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: MoePrimaryButton(
                label: '保存',
                icon: Icons.save_outlined,
                isLoading: _saving,
                onPressed: _saving ? null : _save,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _DetailBlock extends StatelessWidget {
  const _DetailBlock({
    required this.title,
    required this.body,
    this.selectable = false,
  });

  final String title;
  final String body;
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              color: colors.textSecondary,
              fontSize: 12,
              fontWeight: MoeFontWeights.emphasis,
            ),
          ),
          const SizedBox(height: 5),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: MoeG2Decoration(
              radius: 8,
              color: colors.surface,
              border: Border.all(color: colors.border),
            ),
            child: selectable
                ? SelectableText(
                    body,
                    style: TextStyle(
                      color: colors.text,
                      fontSize: 12,
                      height: 1.45,
                    ),
                  )
                : Text(
                    body,
                    style: TextStyle(
                      color: colors.text,
                      fontSize: 12,
                      height: 1.45,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _RuntimeStatusChip extends StatelessWidget {
  const _RuntimeStatusChip({required this.status});

  final _RuntimePromptStatus status;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    return _StatusChip(
      label: _runtimeStatusLabel(status),
      color: switch (status) {
        _RuntimePromptStatus.active => colors.primary,
        _RuntimePromptStatus.configurable => colors.primary,
        _RuntimePromptStatus.helperOnly => colors.dialogWarning,
        _RuntimePromptStatus.legacy => colors.muted,
      },
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.label,
    required this.color,
  });

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: MoeG2Decoration(
        radius: 5,
        color: color.withValues(alpha: 0.1),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: MoeFontWeights.emphasis,
        ),
      ),
    );
  }
}

_RuntimePromptUsage _usageFor(String promptId) {
  return _runtimeUsages[promptId] ??
      const _RuntimePromptUsage(
        area: '未登记',
        summary: '该提示词存在于 prompt_defaults，但手机端运行用途表尚未登记。',
        status: _RuntimePromptStatus.helperOnly,
      );
}

String _runtimeStatusLabel(_RuntimePromptStatus status) {
  switch (status) {
    case _RuntimePromptStatus.active:
      return '运行中';
    case _RuntimePromptStatus.configurable:
      return '可配置';
    case _RuntimePromptStatus.helperOnly:
      return '需关注';
    case _RuntimePromptStatus.legacy:
      return '遗留';
  }
}

Map<String, Object?> _readObject(Object? value) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) {
    return value.map<String, Object?>(
      (key, value) => MapEntry(key.toString(), value),
    );
  }
  return const <String, Object?>{};
}

List<Map<String, Object?>> _readObjectList(Object? value) {
  if (value is! List) return const <Map<String, Object?>>[];
  return value.whereType<Map>().map(_readObject).toList(growable: false);
}

List<String> _readStringList(Object? value) {
  if (value is! List) return const <String>[];
  return value
      .map((item) => item?.toString().trim() ?? '')
      .where((item) => item.isNotEmpty)
      .toList(growable: false);
}

String _readString(Object? value, {String fallback = ''}) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? fallback : text;
}
