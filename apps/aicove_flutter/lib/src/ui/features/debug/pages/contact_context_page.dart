import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/chat/chat_layer_providers.dart';
import '../../../../features/chat/conversation_providers.dart';
import '../../../../features/chat/domain/chat_context_preview.dart';
import '../../../../features/chat/domain/conversation.dart';
import '../../../../ui/shared/animations/parallax_slide_page_route.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/theme/tokens.dart';

String _contactName(Conversation conversation) =>
    conversation.displayName.trim().isEmpty
    ? conversation.title
    : conversation.displayName;

String _formatTokens(int tokens) => tokens >= 1000
    ? '${(tokens / 1000).toStringAsFixed(tokens >= 10000 ? 0 : 1)}k'
    : '$tokens';

/// 联系人上下文：选一个联系人，查看下一次请求发给模型的完整内容。
class ContactContextListPage extends ConsumerStatefulWidget {
  const ContactContextListPage({super.key});

  static const title = '联系人上下文';

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
class ContactContextPage extends ConsumerStatefulWidget {
  const ContactContextPage({super.key, required this.conversation});

  final Conversation conversation;

  @override
  ConsumerState<ContactContextPage> createState() => _ContactContextPageState();
}

class _ContactContextPageState extends ConsumerState<ContactContextPage> {
  late Future<ChatContextPreview> _preview = _load();
  _ContextTab _tab = _ContextTab.messages;

  Future<ChatContextPreview> _load() =>
      ref.read(chatContextPreviewPortProvider).preview(widget.conversation);

  void _reload() {
    setState(() {
      _preview = _load();
    });
  }

  Future<void> _copyAll(ChatContextPreview preview) async {
    final text = const JsonEncoder.withIndent('  ').convert({
      'model': preview.modelId,
      'messages': preview.messages,
      if (preview.tools.isNotEmpty) 'tools': preview.tools,
    });
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) MoeToast.success(context, '已复制完整请求 JSON');
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    return FutureBuilder<ChatContextPreview>(
      future: _preview,
      builder: (context, snapshot) {
        final preview = snapshot.connectionState == ConnectionState.done
            ? snapshot.data
            : null;
        return MoePageScaffold(
          extendBodyBehindAppBar: true,
          backgroundColor: colors.surface,
          appBar: MoeAppBar(
            title: _contactName(widget.conversation),
            showBackButton: true,
            actions: [
              MoeIconButton(
                icon: Icons.refresh_rounded,
                semanticLabel: '重新生成预览',
                onTap: _reload,
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
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: MoeLoadingIndicator());
              }
              if (preview == null) {
                return MoeEmptyState(
                  icon: Icons.error_outline,
                  title: '上下文装配失败',
                  description: '${snapshot.error ?? '未知错误'}',
                );
              }
              return ListView(
                padding: moeUnderBarPadding(context, const EdgeInsets.all(16)),
                children: [
                  _OverviewCard(preview: preview),
                  const SizedBox(height: 12),
                  MoeToggleBar<_ContextTab>(
                    value: _tab,
                    items: [
                      MoeToggleItem(
                        value: _ContextTab.messages,
                        label: '消息 ${preview.messages.length}',
                      ),
                      const MoeToggleItem(
                        value: _ContextTab.sources,
                        label: '系统组成',
                      ),
                      MoeToggleItem(
                        value: _ContextTab.tools,
                        label: '工具 ${preview.tools.length}',
                      ),
                    ],
                    onChanged: (value) => setState(() => _tab = value),
                  ),
                  const SizedBox(height: 12),
                  ...switch (_tab) {
                    _ContextTab.messages => _messageBlocks(preview),
                    _ContextTab.sources => _sourceBlocks(context, preview),
                    _ContextTab.tools => _toolBlocks(preview),
                  },
                ],
              );
            },
          ),
        );
      },
    );
  }

  List<Widget> _messageBlocks(ChatContextPreview preview) {
    if (preview.messages.isEmpty) {
      return const [MoeEmptyState(title: '没有要发送的消息')];
    }
    return [
      for (var i = 0; i < preview.messages.length; i++)
        _ExpandableBlock(
          key: ValueKey('message-$i'),
          tag: _roleLabel(preview.messages[i]),
          tagColor: _roleColor(context, preview.messages[i]['role']),
          meta: '#${i + 1} · ${_formatTokens(preview.messageTokens[i])} tokens',
          text: _messageText(preview.messages[i]),
        ),
    ];
  }

  List<Widget> _sourceBlocks(BuildContext context, ChatContextPreview preview) {
    final colors = context.moeColors;
    return [
      if (preview.sources.isEmpty)
        const MoeEmptyState(title: '这次没有系统提示词')
      else
        for (var i = 0; i < preview.sources.length; i++)
          _ExpandableBlock(
            key: ValueKey('source-$i'),
            tag: preview.sources[i].label,
            tagColor: colors.primary,
            meta: '${preview.sources[i].content.length} 字',
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

  List<Widget> _toolBlocks(ChatContextPreview preview) {
    if (preview.tools.isEmpty) {
      return const [
        MoeEmptyState(title: '这次没有发送工具', description: '模型不支持工具调用，或相关插件未开启'),
      ];
    }
    return [
      for (var i = 0; i < preview.tools.length; i++)
        Builder(
          builder: (context) {
            final function = preview.tools[i]['function'];
            final fn = function is Map ? function : preview.tools[i];
            return _ExpandableBlock(
              key: ValueKey('tool-$i'),
              tag: '${fn['name'] ?? '未命名工具'}',
              tagColor: context.moeColors.accent,
              meta: '',
              text: [
                '${fn['description'] ?? ''}'.trim(),
                if (fn['parameters'] != null)
                  const JsonEncoder.withIndent(
                    '  ',
                  ).convert(fn['parameters']),
              ].where((part) => part.isNotEmpty).join('\n\n'),
            );
          },
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

class _OverviewCard extends StatelessWidget {
  const _OverviewCard({required this.preview});

  final ChatContextPreview preview;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final ratio = preview.inputLimit <= 0
        ? 0.0
        : (preview.inputTokens / preview.inputLimit).clamp(0.0, 1.0);
    final secondary = TextStyle(fontSize: 13, color: colors.textSecondary);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: MoeG2Decoration(
        radius: 14,
        color: colors.surfaceAlt,
        border: Border.all(color: colors.borderLight),
      ),
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
            preview.presetName == null
                ? '未绑定预设'
                : '预设：${preview.presetName}',
            style: secondary,
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: ratio,
              minHeight: 6,
              backgroundColor: colors.border,
              color: ratio >= 1 ? colors.dialogWarning : colors.primary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '约 ${_formatTokens(preview.inputTokens)} tokens'
            '${preview.inputLimit > 0 ? ' / 压缩阈值 ${_formatTokens(preview.inputLimit)}' : ''}',
            style: secondary,
          ),
          for (final note in preview.notes) ...[
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.info_outline,
                  size: 16,
                  color: colors.dialogWarning,
                ),
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

/// 折叠块：默认展示前几行，点开看全文并可选择、复制。
class _ExpandableBlock extends StatefulWidget {
  const _ExpandableBlock({
    super.key,
    required this.tag,
    required this.tagColor,
    required this.meta,
    required this.text,
  });

  final String tag;
  final Color tagColor;
  final String meta;
  final String text;

  @override
  State<_ExpandableBlock> createState() => _ExpandableBlockState();
}

class _ExpandableBlockState extends State<_ExpandableBlock> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final bodyStyle = TextStyle(fontSize: 13, height: 1.5, color: colors.text);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _expanded = !_expanded),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 6, 12),
          decoration: MoeG2Decoration(
            radius: 12,
            color: colors.surface,
            border: Border.all(color: colors.borderLight),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
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
                  MoeIconButton(
                    icon: Icons.copy_rounded,
                    size: 16,
                    padding: const EdgeInsets.all(6),
                    color: colors.muted,
                    semanticLabel: '复制',
                    onTap: () async {
                      await Clipboard.setData(ClipboardData(text: widget.text));
                      if (context.mounted) MoeToast.brief(context, '已复制');
                    },
                  ),
                  Icon(
                    _expanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 20,
                    color: colors.muted,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: _expanded
                    ? SelectableText(widget.text, style: bodyStyle)
                    : Text(
                        widget.text,
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                        style: bodyStyle,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
