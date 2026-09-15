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
  'default_provider',
  'is_pinned',
  'is_favorite',
  'is_muted',
  'notification_sound',
};

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
        if (scopes.contains(SyncScope.characterSettings)) ..._settingsKeys
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
