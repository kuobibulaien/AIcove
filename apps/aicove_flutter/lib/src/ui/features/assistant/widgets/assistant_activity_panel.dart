import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/assistant/application/assistant_approvals.dart';
import '../../../../features/assistant/application/assistant_cards.dart';
import '../../../../features/assistant/assistant_providers.dart';
import '../../../../features/chat/conversation_providers.dart';
import '../../../../features/settings/app_settings.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';
import '../../character/pages/contact_edit_page.dart';
import '../../character/services/contact_edit_snapshot_store.dart';
import '../../debug/pages/contact_context_page.dart';
import '../../plugins/pages/tavern_preset_detail_page.dart';
import '../../settings/pages/chat_plugin_settings_page.dart';
import '../../settings/pages/default_model_settings_page.dart';
import '../../settings/pages/model_list_page.dart';
import '../../settings/pages/profile_page.dart';
import '../../settings/pages/provider_detail_page.dart';
import '../../settings/pages/ui_settings_page.dart';

/// Above the composer in the assistant chat (ADR0073, batch T3): the calls
/// waiting for the user's approval, key inputs and page links the assistant
/// handed over, and the latest changes with an undo.
class AssistantActivityPanel extends ConsumerStatefulWidget {
  const AssistantActivityPanel({super.key});

  /// Changes shown at once; older ones stay undoable from the journal.
  static const visibleChanges = 3;

  @override
  ConsumerState<AssistantActivityPanel> createState() =>
      _AssistantActivityPanelState();
}

class _AssistantActivityPanelState
    extends ConsumerState<AssistantActivityPanel> {
  /// Changes the user closed without undoing; local to this page.
  final _dismissed = <String>{};
  final _undoing = <String>{};

  Future<void> _undo(String id) async {
    setState(() => _undoing.add(id));
    try {
      await ref.read(assistantChangeJournalProvider).undo(id);
      if (mounted) MoeToast.show(context, '已撤销');
    } on StateError catch (error) {
      if (mounted) MoeToast.error(context, error.message.toString());
    } catch (_) {
      if (mounted) MoeToast.error(context, '撤销失败');
    } finally {
      ref.invalidate(assistantRecentChangesProvider);
      if (mounted) setState(() => _undoing.remove(id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final approvals = ref.watch(assistantApprovalsProvider);
    final cards = ref.watch(assistantCardsProvider);
    final changes = [
      for (final entry
          in ref.watch(assistantRecentChangesProvider).valueOrNull ?? const [])
        if (!_dismissed.contains(entry.id)) entry,
    ].take(AssistantActivityPanel.visibleChanges).toList();
    if (approvals.isEmpty && cards.isEmpty && changes.isEmpty) {
      return const SizedBox.shrink();
    }

    final textStyle = TextStyle(color: colors.text, fontSize: 13);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final pending in approvals)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: MoeContentSurface(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        pending.prompt.title,
                        style: textStyle.copyWith(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (pending.prompt.detail.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          pending.prompt.detail,
                          maxLines: 6,
                          overflow: TextOverflow.ellipsis,
                          style: textStyle.copyWith(
                            color: colors.textSecondary,
                          ),
                        ),
                      ],
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          MoeSecondaryButton(
                            label: '不要',
                            onPressed: () => ref
                                .read(assistantApprovalsProvider.notifier)
                                .answer(pending.id, false),
                          ),
                          const SizedBox(width: 8),
                          MoePrimaryButton(
                            label: '允许',
                            onPressed: () => ref
                                .read(assistantApprovalsProvider.notifier)
                                .answer(pending.id, true),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          for (final card in cards)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: switch (card) {
                AssistantKeyRequest() => _KeyRequestCard(
                  key: ValueKey(card.id),
                  request: card,
                ),
                AssistantPageLink() => _PageLinkCard(link: card),
              },
            ),
          for (final entry in changes)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: MoeContentSurface(
                child: Padding(
                  padding: const EdgeInsets.only(left: 14),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          entry.change.description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: textStyle,
                        ),
                      ),
                      TextButton(
                        onPressed: _undoing.contains(entry.id)
                            ? null
                            : () => _undo(entry.id),
                        child: const Text('撤销'),
                      ),
                      IconButton(
                        tooltip: '收起',
                        iconSize: 18,
                        icon: Icon(
                          Icons.close_rounded,
                          color: colors.textSecondary,
                        ),
                        onPressed: () =>
                            setState(() => _dismissed.add(entry.id)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _PageLinkCard extends ConsumerWidget {
  const _PageLinkCard({required this.link});

  final AssistantPageLink link;

  Future<Widget?> _page(WidgetRef ref) async {
    final id = link.targetId;
    switch (link.target) {
      case 'models':
        return const ModelListPage();
      case 'default_model':
        return const DefaultModelSettingsPage();
      case 'provider':
        return ProviderDetailPage(providerId: id!);
      case 'general':
        return const UiSettingsPage();
      case 'plugins':
        return const ChatPluginSettingsPage();
      case 'profile':
        return const ProfilePage();
      case 'preset':
        return TavernPresetDetailPage(presetId: id!);
      case 'role_edit' || 'role_context':
        final role = (await ref.read(
          conversationsProvider.future,
        )).where((c) => c.id == id && !c.isHidden).firstOrNull;
        if (role == null) return null;
        return link.target == 'role_context'
            ? ContactContextPage(conversation: role)
            : ContactEditPage(
                conversation: role,
                initialSnapshot: ContactEditSnapshot.fromConversation(role),
                editMode: EditMode.editConversation,
              );
    }
    return null;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.moeColors;
    return MoeContentSurface(
      child: Padding(
        padding: const EdgeInsets.only(left: 14),
        child: Row(
          children: [
            Icon(
              Icons.open_in_new_rounded,
              size: 16,
              color: colors.textSecondary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '去看看：${link.label}',
                style: TextStyle(color: colors.text, fontSize: 13),
              ),
            ),
            TextButton(
              onPressed: () async {
                final page = await _page(ref);
                if (!context.mounted) return;
                if (page == null) {
                  MoeToast.error(context, '这个页面已经打不开了');
                } else {
                  MoeWorkspace.open(context, page);
                }
              },
              child: const Text('打开'),
            ),
            IconButton(
              tooltip: '收起',
              iconSize: 18,
              icon: Icon(Icons.close_rounded, color: colors.textSecondary),
              onPressed: () =>
                  ref.read(assistantCardsProvider.notifier).dismiss(link.id),
            ),
          ],
        ),
      ),
    );
  }
}

/// The key goes from this field straight into the channel; nothing of it
/// reaches the chat or the model.
class _KeyRequestCard extends ConsumerStatefulWidget {
  const _KeyRequestCard({super.key, required this.request});

  final AssistantKeyRequest request;

  @override
  ConsumerState<_KeyRequestCard> createState() => _KeyRequestCardState();
}

class _KeyRequestCardState extends ConsumerState<_KeyRequestCard> {
  final _keyCtrl = TextEditingController();
  bool _obscure = true;
  bool _saving = false;

  @override
  void dispose() {
    _keyCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final key = _keyCtrl.text.trim();
    if (key.isEmpty) return;
    setState(() => _saving = true);
    try {
      final settings = ref.read(appSettingsProvider.notifier);
      await settings.editProvider(
        providerId: widget.request.providerId,
        apiKeys: [key],
      );
      final provider = (await ref.read(
        appSettingsProvider.future,
      )).getProvider(widget.request.providerId);
      if (provider != null && !provider.enabled) {
        await settings.setProviderEnabled(provider.id, true);
      }
      ref.read(assistantCardsProvider.notifier).dismiss(widget.request.id);
      if (mounted) MoeToast.show(context, 'Key 已保存');
    } catch (_) {
      if (mounted) {
        setState(() => _saving = false);
        MoeToast.error(context, '保存失败，Key 没有改动');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    return MoeContentSurface(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '填写「${widget.request.providerName}」的 API Key',
              style: TextStyle(
                color: colors.text,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Key 只保存到这个渠道，不会发进聊天，助手也看不到。',
              style: TextStyle(color: colors.textSecondary, fontSize: 12),
            ),
            const SizedBox(height: 8),
            MoeTextField(
              key: const ValueKey('assistant-key-request-field'),
              controller: _keyCtrl,
              hint: '粘贴 Key',
              obscureText: _obscure,
              enabled: !_saving,
              suffix: IconButton(
                tooltip: _obscure ? '显示' : '隐藏',
                icon: Icon(
                  _obscure
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  size: 18,
                ),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                MoeSecondaryButton(
                  label: '先不填',
                  onPressed: _saving
                      ? null
                      : () => ref
                            .read(assistantCardsProvider.notifier)
                            .dismiss(widget.request.id),
                ),
                const SizedBox(width: 8),
                MoePrimaryButton(
                  label: '保存',
                  onPressed: _saving ? null : _save,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
