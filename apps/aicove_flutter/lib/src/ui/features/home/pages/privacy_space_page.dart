import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_slidable/flutter_slidable.dart';

import '../../../../features/chat/application/privacy_space.dart';
import '../../../../features/chat/presentation/widgets/character_list_item.dart';
import '../../../../features/chat/providers2.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';

/// 输入密码弹窗；取消返回 null。
///
/// 不用 TextEditingController：弹窗退出动画期间输入框仍在树上，
/// 调用方提前 dispose 会触发 "used after being disposed"。
Future<String?> _askPassword(
  BuildContext context, {
  required String title,
  String? hint,
  String confirmText = '确定',
}) async {
  var password = '';
  final confirmed = await showMeoTalkDialog(
    context: context,
    title: title,
    confirmText: confirmText,
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Builder(
          builder: (dialogContext) => MoeTextField(
            key: const ValueKey('privacy-password-field'),
            hint: '密码',
            obscureText: true,
            autofocus: true,
            textInputAction: TextInputAction.done,
            onChanged: (value) => password = value,
            onSubmitted: (_) => Navigator.of(dialogContext).pop(true),
          ),
        ),
        if (hint != null) ...[
          const SizedBox(height: 8),
          Text(
            hint,
            style: TextStyle(fontSize: 13, color: context.moeColors.muted),
          ),
        ],
      ],
    ),
  );
  return confirmed == true ? password : null;
}

/// 设置（或重设）隐私空间密码，成功返回 true。
Future<bool> setupPrivacyPassword(BuildContext context, WidgetRef ref) async {
  final first = await _askPassword(
    context,
    title: '设置隐私空间密码',
    hint:
        '至少 $privacySpaceMinPasswordLength 位，会随设置同步到你的其它设备；'
        '忘记后无法找回。之后在联系人列表顶部下拉半屏即可进入。',
    confirmText: '下一步',
  );
  if (first == null || !context.mounted) return false;
  if (first.length < privacySpaceMinPasswordLength) {
    MoeToast.show(context, '密码至少 $privacySpaceMinPasswordLength 位');
    return false;
  }
  final second = await _askPassword(context, title: '再次输入密码');
  if (second == null || !context.mounted) return false;
  if (second != first) {
    MoeToast.show(context, '两次输入的密码不一致');
    return false;
  }
  await ref.read(privacySpacePasswordProvider).set(first);
  return true;
}

/// 把联系人放进隐私空间；还没有密码时先引导设置。
Future<void> hideConversationToPrivacySpace(
  BuildContext context,
  WidgetRef ref,
  String conversationId,
) async {
  final hasPassword = await ref.read(privacySpacePasswordProvider).isSet();
  if (!context.mounted) return;
  if (!hasPassword && !await setupPrivacyPassword(context, ref)) return;
  await ref
      .read(conversationsProvider.notifier)
      .updateConversationSettings(conversationId, isHidden: true);
  if (context.mounted) MoeToast.show(context, '已移入隐私空间');
}

/// 验证密码后打开隐私空间。
Future<void> openPrivacySpace(BuildContext context, WidgetRef ref) async {
  final password = ref.read(privacySpacePasswordProvider);
  final hasPassword = await password.isSet();
  if (!context.mounted) return;
  if (!hasPassword) {
    MoeToast.show(context, '滑动联系人选择「隐藏」即可放入隐私空间');
    return;
  }
  final input = await _askPassword(context, title: '进入隐私空间');
  if (input == null || !context.mounted) return;
  final ok = await password.verify(input);
  if (!context.mounted) return;
  if (!ok) {
    MoeToast.show(context, '密码错误');
    return;
  }
  MoeWorkspace.open(context, const PrivacySpacePage());
}

class PrivacySpacePage extends ConsumerWidget {
  const PrivacySpacePage({super.key});

  Future<void> _changePassword(BuildContext context, WidgetRef ref) async {
    final old = await _askPassword(context, title: '输入当前密码');
    if (old == null || !context.mounted) return;
    if (!await ref.read(privacySpacePasswordProvider).verify(old)) {
      if (context.mounted) MoeToast.show(context, '密码错误');
      return;
    }
    if (!context.mounted) return;
    if (await setupPrivacyPassword(context, ref) && context.mounted) {
      MoeToast.show(context, '密码已修改');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conversations =
        (ref.watch(conversationsProvider).valueOrNull ?? const [])
            .where((c) => c.isHidden)
            .toList()
          ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

    return MoePageScaffold(
      appBar: MoeAppBar(
        title: '隐私空间',
        showBackButton: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.password_outlined),
            tooltip: '修改密码',
            onPressed: () => _changePassword(context, ref),
          ),
        ],
      ),
      body: conversations.isEmpty
          ? const MoeEmptyState(
              icon: Icons.lock_outline,
              title: '隐私空间是空的',
              description: '在聊天列表中滑动联系人，选择「隐藏」即可放到这里',
            )
          : ListView.builder(
              itemCount: conversations.length,
              itemBuilder: (context, index) {
                final c = conversations[index];
                return Slidable(
                  key: ValueKey(c.id),
                  endActionPane: ActionPane(
                    motion: const ScrollMotion(),
                    extentRatio: 0.3,
                    children: [
                      SlidableAction(
                        onPressed: (_) => ref
                            .read(conversationsProvider.notifier)
                            .updateConversationSettings(c.id, isHidden: false),
                        backgroundColor: const Color(0xFF7A6FAE),
                        foregroundColor: Colors.white,
                        icon: Icons.visibility_outlined,
                        label: '取消隐藏',
                      ),
                    ],
                  ),
                  child: CharacterListItem(
                    conversation: c,
                    onTap: () {
                      ref.read(activeConversationIdProvider.notifier).state =
                          c.id;
                      MoeWorkspace.openLocation(
                        context,
                        '/chat/${c.id}',
                        extra: c,
                      );
                    },
                  ),
                );
              },
            ),
    );
  }
}
