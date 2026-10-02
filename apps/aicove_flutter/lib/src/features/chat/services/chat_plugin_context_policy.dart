import '../../content_tags/domain/content_tag_registry.dart';
import '../../content_tags/domain/content_tag_scanner.dart';
import '../../plugins/image/image_plugin.dart';
import '../../plugins/plugin_content_tags.dart';

/// Request-scoped filtering. Never writes filtered content back to raw history.
///
/// 标签与工具的归属来自内容扩展注册表（ADR0044）：归属方本轮未生效时，
/// 其标签连同正文、其工具调用与结果成对移除。
class ChatPluginContextPolicy {
  ChatPluginContextPolicy(ContentTagRegistry registry)
      : _registry = registry,
        _scanner = ContentTagScanner(registry);

  /// 第一方插件：[activeProviderIds] 为本轮有效插件 id（全局开启且角色允许）。
  factory ChatPluginContextPolicy.firstParty({
    required Set<String> activeProviderIds,
  }) =>
      ChatPluginContextPolicy(ContentTagRegistry(
        firstPartyContentTagProviders,
        activeProviderIds: activeProviderIds,
      ));

  final ContentTagRegistry _registry;
  final ContentTagScanner _scanner;

  /// 已下线的旧记忆工具（ADR0038）：历史里残留的调用与结果成对从请求中去掉。
  static const retiredTools = {'memory_search', 'memory_read', 'context_read'};

  bool allowsTool(String name) =>
      !retiredTools.contains(name) && _registry.allowsTool(name);

  /// 关闭绘图时不读取或描述 assistant 生成的图片块（ADR0017）。
  bool get includesGeneratedImages =>
      _registry.isOwnerActive(ImagePlugin.contentTags.providerId);

  /// Removes the entire disabled tag, including attributes and nested content.
  /// An unfinished opening tag hides the remaining text rather than leaking it.
  String filterText(String text) => _scanner.filterForRequest(text);

  dynamic _filterValue(dynamic value) {
    if (value is String) return filterText(value);
    if (value is List) return value.map(_filterValue).toList();
    if (value is Map) {
      return <String, dynamic>{
        for (final entry in value.entries)
          entry.key.toString(): _filterValue(entry.value),
      };
    }
    return value;
  }

  List<Map<String, dynamic>> filterMessages(
      List<Map<String, dynamic>> messages) {
    final removedCallIds = <String>{};
    for (final message in messages) {
      for (final call in (message['tool_calls'] as List? ?? const [])) {
        if (call is Map &&
            call['function'] is Map &&
            !allowsTool((call['function']['name'] ?? '').toString())) {
          removedCallIds.add((call['id'] ?? '').toString());
        }
      }
    }
    final result = <Map<String, dynamic>>[];
    for (final original in messages) {
      if ((original['role'] == 'tool' || original['role'] == 'function') &&
          (!allowsTool((original['name'] ?? '').toString()) ||
              removedCallIds.contains(original['tool_call_id']))) {
        continue;
      }
      final message = _filterValue(original) as Map<String, dynamic>;
      final calls = message['tool_calls'] as List?;
      if (calls != null) {
        final kept = calls
            .where((call) =>
                call is Map &&
                call['function'] is Map &&
                allowsTool((call['function']['name'] ?? '').toString()))
            .toList();
        if (kept.isEmpty) {
          message.remove('tool_calls');
        } else {
          message['tool_calls'] = kept;
        }
      }
      final function = message['function_call'];
      if (function is Map && !allowsTool((function['name'] ?? '').toString())) {
        message.remove('function_call');
      }
      final content = message['content'];
      if (content is List) {
        message['content'] = content
            .where((part) =>
                part is! Map ||
                part['type'] != 'text' ||
                (part['text'] ?? '').toString().trim().isNotEmpty)
            .toList();
      }
      final filtered = message['content'];
      final empty = filtered == null ||
          (filtered is String && filtered.trim().isEmpty) ||
          (filtered is List && filtered.isEmpty);
      if (empty &&
          !message.containsKey('tool_calls') &&
          !message.containsKey('function_call') &&
          message['role'] != 'tool' &&
          message['role'] != 'function') {
        continue;
      }
      result.add(message);
    }
    return result;
  }
}
