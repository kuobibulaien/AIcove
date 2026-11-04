import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/export_format.dart';

/// v1 中真正实现的内容。不能用 manifest 宣称不存在的记忆/供应商备份。
const supportedTransferScopes = {
  SyncScope.characterCards,
  SyncScope.characterSettings,
  SyncScope.chatHistory,
};

void validateTransferScopes(Iterable<String> scopes) {
  if (scopes.isEmpty) throw const FormatException('请至少选择一项导入导出内容');
  final unsupported = scopes.where((s) => !supportedTransferScopes.contains(s));
  if (unsupported.isNotEmpty) {
    throw FormatException(
        '暂不支持备份或恢复：${unsupported.map(SyncScope.getDisplayName).join('、')}。请取消这些选项；现有数据不会被修改。');
  }
}

const _cardKeys = {
  'avatar_file',
  'character_image_file',
  'voice_file',
  'persona_prompt',
  'self_address',
  'address_user',
};
const _settingsKeys = {
  'chat_background_image_file',
  'chat_background_mask_opacity',
  'chat_background_framing',
  'default_provider',
  'is_pinned',
  'is_hidden',
  'is_favorite',
  'is_muted',
  'notification_sound',
  'session_provider', 'enabled_plugins', 'recipe_id', 'thinking_levels',
  'chat_background_blur_sigma',
};
const _chatHistoryKeys = {'context_start_message_id', 'context_summaries'};

/// Selecting a supported scope must not silently discard unsupported content.
void validateTransferConversation(
  Map<String, dynamic> source,
  Set<String> scopes,
) {
  void invalid() => throw const FormatException('备份中的角色设置或聊天摘要格式无效');
  if (scopes.contains(SyncScope.characterSettings)) {
    for (final key in ['session_provider', 'recipe_id', 'enabled_plugins', 'thinking_levels']) {
      if (source[key] != null && source[key] is! String) { invalid(); }
    }
    final blur = source['chat_background_blur_sigma'];
    if (blur != null && (blur is! num || !blur.isFinite)) { invalid(); }
    for (final key in ['enabled_plugins', 'thinking_levels']) {
      if (source[key] == null) continue;
      dynamic decoded;
      try { decoded = jsonDecode(source[key] as String); } catch (_) { invalid(); }
      if (key == 'enabled_plugins' &&
          (decoded is! List || decoded.any((v) => v is! String))) { invalid(); }
      if (key == 'thinking_levels' &&
          (decoded is! Map || decoded.values.any((v) => v is! String))) { invalid(); }
    }
  }
  if (scopes.contains(SyncScope.chatHistory)) {
    if (source['context_start_message_id'] != null && source['context_start_message_id'] is! String) invalid();
    final summaries = source['context_summaries'];
    if (summaries != null) {
      if (summaries is! List) { invalid(); return; }
      for (final item in summaries) {
        if (item is! Map) { invalid(); continue; }
        for (final key in ['id', 'owner_id', 'kind', 'boundary_id', 'summary', 'source_ids', 'source_digest']) {
          if (item[key] is! String) invalid();
        }
        if (item['topic_boundary'] != null && item['topic_boundary'] is! String) invalid();
        if (item['created_at'] is! int) invalid();
        dynamic ids;
        try { ids = jsonDecode(item['source_ids'] as String); } catch (_) { invalid(); }
        if (ids is! List || ids.any((v) => v is! String)) invalid();
      }
    }
  }
}

/// 身份信息用于选择目标，其余字段必须按白名单分域，而不是信任旧包的标签。
Map<String, dynamic> filterTransferConversation(
  Map<String, dynamic> source,
  Set<String> scopes,
) =>
    {
      for (final key in [
        'id',
        'title',
        'display_name',
        'created_at',
        'updated_at',
        if (scopes.contains(SyncScope.characterCards)) ..._cardKeys,
        if (scopes.contains(SyncScope.characterSettings)) ..._settingsKeys,
        if (scopes.contains(SyncScope.chatHistory)) ..._chatHistoryKeys
      ])
        if (source.containsKey(key)) key: source[key],
    };

/// ZIP 使用可移植相对路径；无论当前系统是什么，均拒绝 Windows 绝对路径。
String safeArchivePath(Directory root, String relative) {
  final portable = relative.replaceAll('\\', '/');
  final segments = portable.split('/');
  if (portable.isEmpty ||
      portable.contains('\u0000') ||
      portable.startsWith('/') ||
      RegExp(r'^[a-zA-Z]:').hasMatch(portable) ||
      segments.any((s) =>
          s == '..' ||
          s == '.' ||
          s.contains(':') ||
          s.endsWith('.') ||
          s.endsWith(' ') ||
          RegExp(r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\.|$)',
                  caseSensitive: false)
              .hasMatch(s))) {
    throw const FormatException('备份含不安全的文件路径');
  }
  final base = p.normalize(root.absolute.path);
  final result = p.normalize(p.join(base, portable));
  if (!p.isWithin(base, result)) {
    throw const FormatException('备份文件路径越界');
  }
  return result;
}

/// 进度仅是观察者，不能把已提交的数据或有效导出包变成“失败”。
void notifyTransferProgress<T>(void Function(T)? listener, T progress) {
  try {
    listener?.call(progress);
  } catch (_) {
    // UI 已离开或观察者自身异常不影响数据操作；业务异常不在此捕获。
  }
}
