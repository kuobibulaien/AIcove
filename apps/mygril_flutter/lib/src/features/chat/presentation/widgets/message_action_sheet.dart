/// 消息长按操作菜单
/// 
/// 功能：
/// - 复制：复制消息文本到剪贴板
/// - 编辑：仅用户消息，撤回到输入框重新编辑
/// - 重新生成：仅AI消息，删除当前回复并重新生成
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../../ui/shared/widgets/menus/moe_popup_menu.dart';

/// 消息操作类型
enum MessageAction {
  copy,       // 复制
  edit,       // 编辑（用户消息）
  regenerate, // 重新生成（AI消息）
  quote,      // 引用回复
  save,       // 保存（图片/音频）
}

/// 显示消息操作悬浮菜单（在消息上方显示气泡菜单）
/// 
/// [targetKey] 消息气泡的 GlobalKey，用于定位菜单位置
/// [isUserMessage] 是否是用户消息，决定显示哪些操作
/// [messageText] 消息文本内容，用于复制
/// [onAction] 操作回调
Future<void> showMessageActionMenu(
  BuildContext context, {
  required GlobalKey targetKey,
  required bool isUserMessage,
  required String messageText,
  required void Function(MessageAction action) onAction,
}) async {
  final items = <MoePopupMenuItem>[
    MoePopupMenuItem(
      icon: Icons.copy_rounded,
      label: '复制',
      onTap: () {
        Clipboard.setData(ClipboardData(text: messageText));
        onAction(MessageAction.copy);
      },
    ),
    MoePopupMenuItem(
      icon: Icons.format_quote_rounded,
      label: '引用',
      onTap: () => onAction(MessageAction.quote),
    ),
    if (isUserMessage)
      MoePopupMenuItem(
        icon: Icons.edit_rounded,
        label: '编辑',
        onTap: () => onAction(MessageAction.edit),
      )
    else
      MoePopupMenuItem(
        icon: Icons.refresh_rounded,
        label: '重新生成',
        onTap: () => onAction(MessageAction.regenerate),
      ),
  ];

  await MoePopupMenu.show(
    context,
    targetKey: targetKey,
    items: items,
  );
}

/// 媒体类型（决定菜单项）
enum MediaType { image, audio }

/// 显示媒体消息操作菜单（图片/音频的长按或右键菜单）
///
/// [targetKey] 目标元素的 GlobalKey
/// [mediaType] 媒体类型
/// [onAction] 操作回调
Future<void> showMediaActionMenu(
  BuildContext context, {
  required GlobalKey targetKey,
  required MediaType mediaType,
  required void Function(MessageAction action) onAction,
}) async {
  final items = <MoePopupMenuItem>[
    MoePopupMenuItem(
      icon: Icons.save_alt_rounded,
      label: '保存',
      onTap: () => onAction(MessageAction.save),
    ),
    MoePopupMenuItem(
      icon: Icons.format_quote_rounded,
      label: '引用',
      onTap: () => onAction(MessageAction.quote),
    ),
  ];

  await MoePopupMenu.show(
    context,
    targetKey: targetKey,
    items: items,
  );
}
