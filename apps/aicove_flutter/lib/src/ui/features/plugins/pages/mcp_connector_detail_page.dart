import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/plugins/mcp/mcp_connector.dart';
import '../../../../features/plugins/mcp/mcp_connector_providers.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/theme/tokens.dart';

/// 单个 MCP 连接器：地址、鉴权、连接测试与工具开关。
class McpConnectorDetailPage extends ConsumerStatefulWidget {
  const McpConnectorDetailPage({super.key, required this.connectorId});

  final String connectorId;

  @override
  ConsumerState<McpConnectorDetailPage> createState() =>
      _McpConnectorDetailPageState();
}

class _McpConnectorDetailPageState
    extends ConsumerState<McpConnectorDetailPage> {
  bool _connecting = false;

  McpConnectorsConfigNotifier get _notifier =>
      ref.read(mcpConnectorsConfigProvider.notifier);

  Future<void> _save(McpConnector Function(McpConnector c) change) async {
    final current = ref
        .read(mcpConnectorsConfigProvider)
        .byId(widget.connectorId);
    if (current == null) return;
    await _notifier.saveConnector(change(current));
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final connector = ref
        .watch(mcpConnectorsConfigProvider)
        .byId(widget.connectorId);

    return MoePageScaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: colors.surface,
      appBar: MoeAppBar(
        title: connector?.displayName ?? 'MCP 连接器',
        showBackButton: true,
      ),
      body: MoeSettingsContent(
        child: connector == null
            ? const SizedBox.shrink()
            : Builder(
                builder: (context) => ListView(
                  padding: moeUnderBarPadding(
                    context,
                    MoeSettingsLayout.verticalListPadding,
                  ),
                  children: [
                    MoeSettingsGroup(
                      children: [
                        MoeSettingsRow(
                          key: const ValueKey('mcp-connector-enabled'),
                          label: '启用',
                          trailingType: MoeSettingsRowTrailing.switchControl,
                          switchValue: connector.enabled,
                          onSwitchChanged: (value) =>
                              _guard(_save((c) => c.copyWith(enabled: value))),
                        ),
                        MoeSettingsRow(
                          label: '名称',
                          trailingType: MoeSettingsRowTrailing.text,
                          detailText: connector.displayName,
                          showDivider: false,
                          onTap: () => _editText(
                            title: '名称',
                            initialValue: connector.name,
                            hint: connector.serverName.isEmpty
                                ? '例如：天气、笔记'
                                : connector.serverName,
                            apply: (c, value) => c.copyWith(name: value.trim()),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: MoeSettingsLayout.sectionGap),
                    MoeSettingsGroup(
                      title: '连接',
                      children: [
                        MoeSettingsRow(
                          key: const ValueKey('mcp-connector-url'),
                          label: '服务地址',
                          trailingType: MoeSettingsRowTrailing.text,
                          detailText: connector.url.trim().isEmpty
                              ? '未填写'
                              : connector.url.trim(),
                          onTap: () => _editText(
                            title: '服务地址',
                            initialValue: connector.url,
                            hint: 'https://example.com/mcp',
                            keyboardType: TextInputType.url,
                            apply: (c, value) {
                              final trimmed = value.trim();
                              final next = c.copyWith(url: trimmed);
                              if (trimmed.isNotEmpty && !next.hasValidUrl) {
                                throw const FormatException('请输入 http(s) 地址');
                              }
                              return next;
                            },
                          ),
                        ),
                        MoeSettingsRow(
                          key: const ValueKey('mcp-connector-token'),
                          label: '访问令牌（可选）',
                          trailingType: MoeSettingsRowTrailing.text,
                          detailText: connector.bearerToken.trim().isEmpty
                              ? '未填写'
                              : _mask(connector.bearerToken),
                          onTap: () => _editText(
                            title: '访问令牌',
                            initialValue: connector.bearerToken,
                            hint: '粘贴服务提供的令牌',
                            obscureText: true,
                            apply: (c, value) =>
                                c.copyWith(bearerToken: value.trim()),
                          ),
                        ),
                        MoeSettingsRow(
                          key: const ValueKey('mcp-connector-headers'),
                          label: '自定义请求头（可选）',
                          subtitle: '每行一个，格式为 名称: 值',
                          trailingType: MoeSettingsRowTrailing.text,
                          detailText: connector.headers.isEmpty
                              ? '无'
                              : '${connector.headers.length} 个',
                          showDivider: false,
                          onTap: () => _editText(
                            title: '自定义请求头',
                            initialValue: [
                              for (final e in connector.headers.entries)
                                '${e.key}: ${e.value}',
                            ].join('\n'),
                            hint: 'X-Api-Key: xxxx',
                            maxLines: 6,
                            apply: (c, value) =>
                                c.copyWith(headers: parseHeaderLines(value)),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: MoeSettingsLayout.sectionGap),
                    MoeSettingsGroup(
                      children: [
                        MoeSettingsRow(
                          key: const ValueKey('mcp-connector-connect'),
                          label: _connecting
                              ? '正在连接…'
                              : connector.tools.isEmpty
                              ? '测试连接'
                              : '刷新工具列表',
                          subtitle: connector.toolsFetchedAt == null
                              ? '连接服务并读取它提供的工具'
                              : '上次更新：${_formatTime(connector.toolsFetchedAt!)}',
                          enabled: connector.hasValidUrl && !_connecting,
                          showDivider: false,
                          onTap: () => _connect(connector),
                        ),
                      ],
                    ),
                    if (connector.tools.isNotEmpty) ...[
                      const SizedBox(height: MoeSettingsLayout.sectionGap),
                      MoeSettingsGroup(
                        title:
                            '工具（${connector.activeTools.length}/${connector.tools.length} 已开启）',
                        children: [
                          for (var i = 0; i < connector.tools.length; i++)
                            _toolRow(
                              connector,
                              connector.tools[i],
                              showDivider: i < connector.tools.length - 1,
                            ),
                        ],
                      ),
                    ],
                    const SizedBox(height: MoeSettingsLayout.sectionGap),
                    MoeSettingsGroup(
                      children: [
                        MoeSettingsRow(
                          key: const ValueKey('mcp-connector-delete'),
                          label: '删除连接器',
                          labelColor: Theme.of(context).colorScheme.error,
                          trailingType: MoeSettingsRowTrailing.none,
                          showDivider: false,
                          onTap: () => _delete(connector),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _toolRow(
    McpConnector connector,
    McpToolInfo tool, {
    required bool showDivider,
  }) {
    final enabled = !connector.disabledTools.contains(tool.name);
    final description = tool.description.trim();
    return MoeSettingsRow(
      key: ValueKey('mcp-tool-${tool.name}'),
      label: tool.displayName,
      subtitle: description.isEmpty ? null : description,
      trailingType: MoeSettingsRowTrailing.switchControl,
      switchValue: enabled,
      showDivider: showDivider,
      onSwitchChanged: (value) => _guard(
        _save((c) {
          final disabled = Set<String>.from(c.disabledTools);
          value ? disabled.remove(tool.name) : disabled.add(tool.name);
          return c.copyWith(disabledTools: disabled);
        }),
      ),
    );
  }

  Future<void> _connect(McpConnector connector) async {
    setState(() => _connecting = true);
    try {
      final updated = await _notifier.refreshTools(connector.id);
      if (!mounted) return;
      MoeToast.success(context, '连接成功，读到 ${updated.tools.length} 个工具');
    } catch (e) {
      if (mounted) MoeToast.error(context, '$e');
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  Future<void> _delete(McpConnector connector) async {
    final confirm = await showMeoTalkDialog(
      context: context,
      title: '删除连接器',
      content: Text(
        '确定删除「${connector.displayName}」吗？地址、令牌和工具设置会一起删除，'
        '开启了它的角色将不再能调用这些工具。',
      ),
      confirmText: '删除',
      cancelText: '取消',
      isDanger: true,
    );
    if (confirm != true || !mounted) return;
    try {
      await _notifier.removeConnector(connector.id);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) MoeToast.error(context, '$e');
    }
  }

  Future<void> _guard(Future<void> task) async {
    try {
      await task;
    } catch (e) {
      if (mounted) MoeToast.error(context, '$e');
    }
  }

  Future<void> _editText({
    required String title,
    required String initialValue,
    required McpConnector Function(McpConnector c, String value) apply,
    String? hint,
    TextInputType? keyboardType,
    int maxLines = 1,
    bool obscureText = false,
  }) {
    return showMoeAutoSaveTextEditor(
      context: context,
      title: title,
      initialValue: initialValue,
      hint: hint,
      keyboardType: keyboardType,
      maxLines: maxLines,
      obscureText: obscureText,
      onSave: (value) => _save((c) => apply(c, value)),
    );
  }

  static String _mask(String value) {
    final trimmed = value.trim();
    if (trimmed.length <= 8) return '已填写';
    return '${trimmed.substring(0, 4)}…${trimmed.substring(trimmed.length - 4)}';
  }

  static String _formatTime(DateTime time) {
    final local = time.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${local.month}月${local.day}日 ${two(local.hour)}:${two(local.minute)}';
  }
}

/// 解析「名称: 值」逐行请求头；格式不对的行报错，不静默丢弃。
Map<String, String> parseHeaderLines(String text) {
  final headers = <String, String>{};
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    final colon = line.indexOf(':');
    final name = colon > 0 ? line.substring(0, colon).trim() : '';
    if (name.isEmpty || name.contains(' ')) {
      throw FormatException('无法识别的请求头：$line');
    }
    headers[name] = line.substring(colon + 1).trim();
  }
  return headers;
}
