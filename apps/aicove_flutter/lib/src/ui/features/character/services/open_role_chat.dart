import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/chat/domain/conversation.dart';
import '../../../../features/chat/providers2.dart';
import '../../../shared/widgets/index.dart';

/// Materialize an unstarted preset before opening its existing chat destination.
Future<void> openRoleChat(
  BuildContext context,
  WidgetRef ref,
  Conversation role,
) async {
  try {
    final notifier = ref.read(conversationsProvider.notifier);
    final roles = await ref.read(conversationsProvider.future);
    if (!context.mounted) return;
    final current = roles.where((item) => item.id == role.id).firstOrNull;
    if (current == null) {
      await notifier.setAll([...roles, role]);
    }
    if (!context.mounted) return;
    ref.read(activeConversationIdProvider.notifier).state = role.id;
    MoeWorkspace.openLocation(
      context,
      '/chat/${role.id}',
      extra: current ?? role,
    );
  } catch (_) {
    if (context.mounted) MoeToast.error(context, '暂时无法打开聊天，请重试');
  }
}
