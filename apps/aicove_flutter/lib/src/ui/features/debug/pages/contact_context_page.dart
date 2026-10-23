import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/utils/token_estimator.dart';
import '../../../../features/chat/chat_layer_providers.dart';
import '../../../../features/chat/conversation_providers.dart';
import '../../../../features/chat/domain/chat_context_preview.dart';
import '../../../../features/chat/domain/conversation.dart';
import '../../../../ui/shared/animations/parallax_slide_page_route.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/theme/tokens.dart';

String _contactName(Conversation conversation) =>
    conversation.displayName.trim().isEmpty
    ? conversation.title
    : conversation.displayName;

String _formatTokens(int tokens) => tokens >= 1000
    ? '${(tokens / 1000).toStringAsFixed(tokens >= 10000 ? 0 : 1)}k'
    : '$tokens';

/// 角色完整上下文：选一个角色，查看下一次请求发给模型的完整内容。
class ContactContextListPage extends ConsumerStatefulWidget {
  const ContactContextListPage({super.key});

  static const title = '角色完整上下文';

  @override
  ConsumerState<ContactContextListPage> createState() =>
      _ContactContextListPageState();
}

class _ContactContextListPageState
    extends ConsumerState<ContactContextListPage> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final conversations = ref.watch(conversationsProvider);
    return MoePageScaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: colors.surface,
      appBar: const MoeAppBar(
        title: ContactContextListPage.title,
        showBackButton: true,
      ),
      body: conversations.when(
        loading: () => const Center(child: MoeLoadingIndicator()),
        error: (error, _) => MoeEmptyState(
          icon: Icons.error_outline,
          title: '联系人读取失败',
          description: '$error',
        ),
        data: (all) {
          final query = _query.trim().toLowerCase();
          final contacts = query.isEmpty
              ? all
              : all
                    .where((c) => _contactName(c).toLowerCase().contains(query))
                    .toList();
          return Builder(
            builder: (context) => ListView(
              padding: moeUnderBarPadding(
                context,
                const EdgeInsets.symmetric(vertical: 8),
              ),
              children: [
                MoeSearchField(
                  hintText: '搜索联系人',
                  onChanged: (value) => setState(() => _query = value),
                ),
                if (contacts.isEmpty)
                  MoeEmptyState(
                    icon: Icons.person_search_outlined,
                    title: all.isEmpty ? '还没有联系人' : '没有匹配的联系人',
                  )
                else
                  MoeSettingsGroup(
                    margin: const EdgeInsets.symmetric(horizontal: 16),
                    children: [
                      for (var i = 0; i < contacts.length; i++)
                        MoeSettingsRow(
                          iconWidget: MoeAvatar(
                            name: _contactName(contacts[i]),
                            avatarUrl: contacts[i].avatarUrl,
                            characterImage: contacts[i].characterImage,
                            size: 32,
                          ),
                          iconContainerWidth: 32,
                          label: _contactName(contacts[i]),
                          trailingType: MoeSettingsRowTrailing.chevron,
                          showDivider: i != contacts.length - 1,
                          onTap: () => Navigator.of(context).push(
                            ParallaxSlidePageRoute(
                              page: ContactContextPage(
                                conversation: contacts[i],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

enum _ContextTab { messages, sources, tools }

/// 单个联系人的上下文详情：概览＋消息／系统组成／工具三栏。
///
/// 消息和工具可在本页自由编辑、删除、追加，用量随之重算；修改只作用于本页
/// 预览与复制，不改角色设置，也不影响真实发送。
class ContactContextPage extends ConsumerStatefulWidget {
  const ContactContextPage({super.key, required this.conversation});

  final Conversation conversation;

  @override
  ConsumerState<ContactContextPage> createState() => _ContactContextPageState();
}

class _ContactContextPageState extends ConsumerState<ContactContextPage> {
  ChatContextPreview? _preview;
  Object? _error;
  bool _loading = true;
  _ContextTab _tab = _ContextTab.messages;

  /// 可编辑副本；每条带稳定 id，删除后其余块的展开与编辑状态不串位。
  List<Map<String, dynamic>> _messages = [];
  List<Map<String, dynamic>> _tools = [];
  List<int> _messageIds = [];
  List<int> _toolIds = [];
  final Set<int> _jsonMode = {};
  final Map<int, String> _errors = {};
  int _nextId = 0;
  int? _justAdded;
  bool _edited = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final preview = await ref
          .read(chatContextPreviewPortProvider)
          .preview(widget.conversation);
      if (!mounted) return;
      setState(() {
        _preview = preview;
        _loading = false;
        _resetEdits(preview);
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _preview = null;
        _error = error;
        _loading = false;
      });
    }
  }

  void _resetEdits(ChatContextPreview preview) {
    _messages = [for (final m in preview.messages) _deepCopy(m)];
    _tools = [for (final t in preview.tools) _deepCopy(t)];
    _messageIds = [for (var i = 0; i < _messages.length; i++) _nextId++];
    _toolIds = [for (var i = 0; i < _tools.length; i++) _nextId++];
    _jsonMode.clear();
    _errors.clear();
    _justAdded = null;
    _edited = false;
  }

  static Map<String, dynamic> _deepCopy(Map<String, dynamic> value) =>
      Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map);

  static String _prettyJson(Object? value) =>
      const JsonEncoder.withIndent('  ').convert(value);

  /// 纯文本消息才能按正文编辑；多模态和带工具调用的只能按 JSON 编辑。
  static bool _plainText(Map<String, dynamic> message) {
    final content = message['content'];
    final toolCalls = message['tool_calls'];
    return (content == null || content is String) &&
        !(toolCalls is List && toolCalls.isNotEmpty);
  }

  bool _editsJson(int index) =>
      _jsonMode.contains(_messageIds[index]) || !_plainText(_messages[index]);

  void _editMessage(int index, String text) {
    final id = _messageIds[index];
    setState(() {
      _edited = true;
      if (!_editsJson(index)) {
        _messages[index] = {..._messages[index], 'content': text};
        return;
      }
      final parsed = _tryParseObject(text);
      if (parsed == null) {
        _errors[id] = 'JSON 无效，用量按上一次有效内容计算';
      } else {
        _errors.remove(id);
        _messages[index] = parsed;
      }
    });
  }

  void _editTool(int index, String text) {
    final id = _toolIds[index];
    final parsed = _tryParseObject(text);
    setState(() {
      _edited = true;
      if (parsed == null) {
        _errors[id] = 'JSON 无效，用量按上一次有效内容计算';
      } else {
        _errors.remove(id);
        _tools[index] = parsed;
      }
    });
  }

  static Map<String, dynamic>? _tryParseObject(String text) {
    try {
      final value = jsonDecode(text);
      return value is Map ? Map<String, dynamic>.from(value) : null;
    } on FormatException {
      return null;
    }
  }

  void _toggleJson(int index) {
    final id = _messageIds[index];
    setState(() {
      if (!_jsonMode.remove(id)) _jsonMode.add(id);
      _errors.remove(id);
    });
  }

  void _removeMessage(int index) {
    setState(() {
      _edited = true;
      final id = _messageIds.removeAt(index);
      _messages.removeAt(index);
      _jsonMode.remove(id);
      _errors.remove(id);
    });
  }

  void _removeTool(int index) {
    setState(() {
      _edited = true;
      _errors.remove(_toolIds.removeAt(index));
      _tools.removeAt(index);
    });
  }

  void _addMessage() {
    setState(() {
      _edited = true;
      _messages.add({'role': 'user', 'content': ''});
      _messageIds.add(_justAdded = _nextId++);
    });
  }

  void _addTool() {
    setState(() {
      _edited = true;
      _tools.add({
        'type': 'function',
        'function': {
          'name': 'new_tool',
          'description': '',
          'parameters': {'type': 'object', 'properties': {}},
        },
      });
      _toolIds.add(_justAdded = _nextId++);
    });
  }

  Future<void> _copyAll(ChatContextPreview preview) async {
    final text = _prettyJson({
      'model': preview.modelId,
      'messages': _messages,
      if (_tools.isNotEmpty) 'tools': _tools,
    });
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      MoeToast.success(context, _edited ? '已复制修改后的请求 JSON' : '已复制完整请求 JSON');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final preview = _loading ? null : _preview;
    return MoePageScaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: colors.surface,
      appBar: MoeAppBar(
        title: _contactName(widget.conversation),
        showBackButton: true,
        actions: [
          if (_edited && preview != null)
            MoeIconButton(
              icon: Icons.undo_rounded,
              semanticLabel: '撤销全部修改',
              onTap: () => setState(() => _resetEdits(preview)),
            ),
          MoeIconButton(
            icon: Icons.refresh_rounded,
            semanticLabel: '重新生成预览',
            onTap: _load,
          ),
          MoeIconButton(
            icon: Icons.copy_all_outlined,
            semanticLabel: '复制完整请求',
            enabled: preview != null,
            onTap: () {
              if (preview != null) _copyAll(preview);
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Builder(
        builder: (context) {
          if (_loading) {
            return const Center(child: MoeLoadingIndicator());
          }
          if (preview == null) {
            return MoeEmptyState(
              icon: Icons.error_outline,
              title: '上下文装配失败',
              description: '${_error ?? '未知错误'}',
            );
          }
          final usage = ChatContextUsage.measure(_messages, _tools);
          return ListView(
            padding: moeUnderBarPadding(context, const EdgeInsets.all(16)),
            children: [
              _OverviewCard(preview: preview, usage: usage, edited: _edited),
              const SizedBox(height: 12),
              MoeSegmentedControl<_ContextTab>(
                value: _tab,
                segments: [
                  MoeSegment(
                    value: _ContextTab.messages,
                    label: '消息 ${_messages.length}',
                  ),
                  const MoeSegment(value: _ContextTab.sources, label: '系统组成'),
                  MoeSegment(
                    value: _ContextTab.tools,
                    label: '工具 ${_tools.length}',
                  ),
                ],
                onChanged: (value) => setState(() => _tab = value),
              ),
              const SizedBox(height: 12),
              ...switch (_tab) {
                _ContextTab.messages => _messageBlocks(usage),
                _ContextTab.sources => _sourceBlocks(context, preview),
                _ContextTab.tools => _toolBlocks(),
              },
            ],
          );
        },
      ),
    );
  }

  List<Widget> _messageBlocks(ChatContextUsage usage) {
    return [
      if (_messages.isEmpty) const MoeEmptyState(title: '没有要发送的消息'),
      for (var i = 0; i < _messages.length; i++)
        Builder(
          builder: (context) {
            final message = _messages[i];
            final id = _messageIds[i];
            final json = _editsJson(i);
            return _ExpandableBlock(
              key: ValueKey('message-$id'),
              tag: _roleLabel(message),
              tagColor: _roleColor(context, message['role']),
              meta:
                  '#${i + 1} · ${_formatTokens(usage.messageTokens[i])} tokens',
              text: _messageText(message),
              initiallyExpanded: id == _justAdded,
              editMode: json ? 'json' : 'text',
              editText: json
                  ? _prettyJson(message)
                  : '${message['content'] ?? ''}',
              errorText: _errors[id],
              onChanged: (text) => _editMessage(i, text),
              onDelete: () => _removeMessage(i),
              onToggleJson: _plainText(message) || _jsonMode.contains(id)
                  ? () => _toggleJson(i)
                  : null,
            );
          },
        ),
      Align(
        alignment: Alignment.centerLeft,
        child: MoeSecondaryButton(
          label: '添加消息',
          icon: Icons.add_rounded,
          size: MoeSecondaryButtonSize.sm,
          onPressed: _addMessage,
        ),
      ),
    ];
  }

  List<Widget> _sourceBlocks(BuildContext context, ChatContextPreview preview) {
    final colors = context.moeColors;
    return [
      if (_edited)
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
          child: Text(
            '这里是装配时的原始来源；修改后的内容以「消息」栏为准。',
            style: TextStyle(fontSize: 13, color: colors.textSecondary),
          ),
        ),
      if (preview.sources.isEmpty)
        const MoeEmptyState(title: '这次没有系统提示词')
      else
        for (var i = 0; i < preview.sources.length; i++)
          _ExpandableBlock(
            key: ValueKey('source-$i'),
            tag: preview.sources[i].label,
            tagColor: colors.primary,
            meta:
                '${preview.sources[i].content.length} 字 · '
                '${_formatTokens(estimateTokenCount(preview.sources[i].content))} tokens',
            text: preview.sources[i].content,
          ),
      if (preview.plugins.isNotEmpty) ...[
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
          child: Text(
            '插件提示词',
            style: TextStyle(fontSize: 13, color: colors.textSecondary),
          ),
        ),
        MoeSettingsGroup(
          children: [
            for (var i = 0; i < preview.plugins.length; i++)
              MoeSettingsRow(
                icon: preview.plugins[i].injected
                    ? Icons.check_circle_outline
                    : Icons.remove_circle_outline,
                iconColor: preview.plugins[i].injected
                    ? colors.primary
                    : colors.muted,
                label: preview.plugins[i].name,
                subtitle: preview.plugins[i].injected
                    ? '已注入'
                    : (preview.plugins[i].reason ?? '未注入'),
                trailingType: MoeSettingsRowTrailing.none,
                showDivider: i != preview.plugins.length - 1,
              ),
          ],
        ),
      ],
    ];
  }

  List<Widget> _toolBlocks() {
    return [
      if (_tools.isEmpty)
        const MoeEmptyState(
          title: '这次没有发送工具',
          description: '模型不支持工具调用，或相关插件未开启',
        ),
      for (var i = 0; i < _tools.length; i++)
        Builder(
          builder: (context) {
            final function = _tools[i]['function'];
            final fn = function is Map ? function : _tools[i];
            final id = _toolIds[i];
            return _ExpandableBlock(
              key: ValueKey('tool-$id'),
              tag: '${fn['name'] ?? '未命名工具'}',
              tagColor: context.moeColors.accent,
              meta:
                  '${_formatTokens(estimateTokenCount(jsonEncode(_tools[i])))} tokens',
              text: [
                '${fn['description'] ?? ''}'.trim(),
                if (fn['parameters'] != null) _prettyJson(fn['parameters']),
              ].where((part) => part.isNotEmpty).join('\n\n'),
              initiallyExpanded: id == _justAdded,
              editMode: 'json',
              editText: _prettyJson(_tools[i]),
              errorText: _errors[id],
              onChanged: (text) => _editTool(i, text),
              onDelete: () => _removeTool(i),
            );
          },
        ),
      Align(
        alignment: Alignment.centerLeft,
        child: MoeSecondaryButton(
          label: '添加工具',
          icon: Icons.add_rounded,
          size: MoeSecondaryButtonSize.sm,
          onPressed: _addTool,
        ),
      ),
    ];
  }

  String _roleLabel(Map<String, dynamic> message) {
    return switch (message['role']) {
      'system' => '系统',
      'user' => '用户',
      'assistant' => _contactName(widget.conversation),
      'tool' => '工具结果 ${message['name'] ?? ''}'.trim(),
      final role => '$role',
    };
  }

  Color _roleColor(BuildContext context, Object? role) {
    final colors = context.moeColors;
    return switch (role) {
      'system' => colors.primary,
      'assistant' => colors.accent,
      'tool' => colors.muted,
      _ => colors.textSecondary,
    };
  }

  static String _messageText(Map<String, dynamic> message) {
    final parts = <String>[];
    final content = message['content'];
    if (content is String) {
      parts.add(content);
    } else if (content is List) {
      for (final part in content) {
        if (part is! Map) continue;
        if (part['type'] == 'text') {
          parts.add('${part['text'] ?? ''}');
        } else {
          parts.add('[${part['type'] ?? '附件'}]');
        }
      }
    }
    final toolCalls = message['tool_calls'];
    if (toolCalls is List) {
      for (final call in toolCalls) {
        final function = call is Map ? call['function'] : null;
        if (function is Map) {
          parts.add('→ 调用 ${function['name']}(${function['arguments'] ?? ''})');
        }
      }
    }
    final text = parts.where((part) => part.trim().isNotEmpty).join('\n\n');
    return text.isEmpty ? '（空）' : text;
  }
}

const _usageLabels = {
  ChatContextUsageKind.system: '系统提示词',
  ChatContextUsageKind.history: '对话历史',
  ChatContextUsageKind.toolCalls: '工具调用与结果',
  ChatContextUsageKind.toolDefinitions: '工具定义',
};

Color _usageColor(MoeColors colors, ChatContextUsageKind kind) =>
    switch (kind) {
      ChatContextUsageKind.system => colors.primary,
      // 主题里没有蓝色，图例要和粉色主色区分开。
      ChatContextUsageKind.history => const Color(0xFF5B8DEF),
      ChatContextUsageKind.toolCalls => colors.toastWarning,
      ChatContextUsageKind.toolDefinitions => colors.toastSuccess,
    };

/// Same hairline as [MoeSettingsGroup], so the cards match other content
/// surfaces under every material.
BorderSide _hairline(MoeColors colors) =>
    BorderSide(color: colors.border.withValues(alpha: 0.06), width: 0.6);

class _OverviewCard extends StatelessWidget {
  const _OverviewCard({
    required this.preview,
    required this.usage,
    required this.edited,
  });

  final ChatContextPreview preview;
  final ChatContextUsage usage;
  final bool edited;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final limit = preview.inputLimit;
    final secondary = TextStyle(fontSize: 13, color: colors.textSecondary);
    final kinds = [
      for (final kind in ChatContextUsageKind.values)
        if (usage.byKind[kind]! > 0) kind,
    ];
    final notes = [
      if (edited) '已手动修改：用量按修改后的内容估算，只影响本页预览与复制，不改角色设置，也不影响真实发送',
      ...preview.notes,
    ];
    return MoeContentSurface(
      radius: 14,
      border: _hairline(colors),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            preview.modelId,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: colors.text,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            preview.presetName == null ? '未绑定预设' : '预设：${preview.presetName}',
            style: secondary,
          ),
          const SizedBox(height: 12),
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '约 ${_formatTokens(usage.total)} tokens',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: limit > 0 && usage.total >= limit
                        ? colors.dialogWarning
                        : colors.text,
                  ),
                ),
                if (limit > 0)
                  TextSpan(
                    text:
                        ' / 压缩阈值 ${_formatTokens(limit)}'
                        '（${(usage.total * 100 / limit).toStringAsFixed(usage.total * 100 < limit ? 1 : 0)}%）',
                    style: secondary,
                  ),
              ],
            ),
            style: const TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: SizedBox(
              height: 8,
              child: kinds.isEmpty
                  ? ColoredBox(
                      color: colors.border,
                      child: const SizedBox.expand(),
                    )
                  : Row(
                      children: [
                        for (final kind in kinds)
                          Expanded(
                            // 至少占一格，避免很小的分类完全看不见。
                            flex: math.max(
                              1,
                              usage.byKind[kind]! * 1000 ~/ usage.total,
                            ),
                            child: ColoredBox(
                              color: _usageColor(colors, kind),
                              child: const SizedBox.expand(),
                            ),
                          ),
                      ],
                    ),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 14,
            runSpacing: 4,
            children: [
              for (final kind in kinds)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: _usageColor(colors, kind),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      '${_usageLabels[kind]} ${_formatTokens(usage.byKind[kind]!)}'
                      ' · ${(usage.byKind[kind]! * 100 / usage.total).round()}%',
                      style: secondary,
                    ),
                  ],
                ),
            ],
          ),
          for (final note in notes) ...[
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, size: 16, color: colors.dialogWarning),
                const SizedBox(width: 6),
                Expanded(child: Text(note, style: secondary)),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// 折叠块：默认展示前几行，点开看全文；给了 [onChanged] 时全文可直接编辑。
class _ExpandableBlock extends StatefulWidget {
  const _ExpandableBlock({
    super.key,
    required this.tag,
    required this.tagColor,
    required this.meta,
    required this.text,
    this.initiallyExpanded = false,
    this.editMode = '',
    this.editText,
    this.errorText,
    this.onChanged,
    this.onDelete,
    this.onToggleJson,
  });

  final String tag;
  final Color tagColor;
  final String meta;

  /// 折叠时的摘要，也是只读块的全文。
  final String text;
  final bool initiallyExpanded;

  /// 编辑方式（正文／JSON）变化时，编辑框内容按 [editText] 重置。
  final String editMode;
  final String? editText;
  final String? errorText;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onDelete;
  final VoidCallback? onToggleJson;

  @override
  State<_ExpandableBlock> createState() => _ExpandableBlockState();
}

class _ExpandableBlockState extends State<_ExpandableBlock> {
  late bool _expanded = widget.initiallyExpanded;
  late final _controller = TextEditingController(text: widget.editText);

  @override
  void didUpdateWidget(covariant _ExpandableBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.editMode != oldWidget.editMode) {
      _controller.text = widget.editText ?? '';
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final bodyStyle = TextStyle(fontSize: 13, height: 1.5, color: colors.text);
    final editable = widget.onChanged != null;
    Widget iconButton(IconData icon, String label, VoidCallback onTap) =>
        MoeIconButton(
          icon: icon,
          size: 16,
          padding: const EdgeInsets.all(6),
          color: colors.muted,
          semanticLabel: label,
          onTap: onTap,
        );
    void toggle() => setState(() => _expanded = !_expanded);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: MoeContentSurface(
        radius: 12,
        border: widget.errorText == null
            ? _hairline(colors)
            : BorderSide(color: colors.dialogWarning),
        padding: const EdgeInsets.fromLTRB(12, 10, 6, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: toggle,
              child: Row(
                children: [
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: widget.tag,
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: widget.tagColor,
                            ),
                          ),
                          if (widget.meta.isNotEmpty)
                            TextSpan(
                              text: '  ${widget.meta}',
                              style: TextStyle(
                                fontSize: 12,
                                color: colors.muted,
                              ),
                            ),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                  if (_expanded && widget.onToggleJson != null)
                    iconButton(
                      Icons.data_object_rounded,
                      widget.editMode == 'json' ? '按正文编辑' : '按 JSON 编辑',
                      widget.onToggleJson!,
                    ),
                  if (_expanded && widget.onDelete != null)
                    iconButton(
                      Icons.delete_outline_rounded,
                      '删除',
                      widget.onDelete!,
                    ),
                  iconButton(Icons.copy_rounded, '复制', () async {
                    await Clipboard.setData(
                      ClipboardData(
                        text: editable ? _controller.text : widget.text,
                      ),
                    );
                    if (context.mounted) MoeToast.brief(context, '已复制');
                  }),
                  Icon(
                    _expanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 20,
                    color: colors.muted,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: !_expanded
                  ? GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: toggle,
                      child: Text(
                        widget.text,
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                        style: bodyStyle,
                      ),
                    )
                  : editable
                  ? TextField(
                      controller: _controller,
                      autofocus: widget.initiallyExpanded,
                      maxLines: null,
                      style: widget.editMode == 'json'
                          ? bodyStyle.copyWith(fontFamily: 'monospace')
                          : bodyStyle,
                      decoration: const MoeInputDecoration(
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                        hintText: '（空）',
                      ),
                      onChanged: widget.onChanged,
                    )
                  : SelectableText(widget.text, style: bodyStyle),
            ),
            if (_expanded && widget.errorText != null) ...[
              const SizedBox(height: 6),
              Text(
                widget.errorText!,
                style: TextStyle(fontSize: 12, color: colors.dialogWarning),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
