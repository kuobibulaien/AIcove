import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'assistant_review.dart';

/// One call waiting for the user's decision in the assistant chat.
class PendingAssistantApproval {
  PendingAssistantApproval(this.id, this.prompt, this._answer);

  final String id;
  final ApprovalPrompt prompt;
  final Completer<bool> _answer;
}

/// Calls the assistant waits on the user for (major tier, or handed over by
/// the reviewer). The assistant chat page shows them as cards.
class AssistantApprovalsNotifier
    extends Notifier<List<PendingAssistantApproval>> {
  int _sequence = 0;

  @override
  List<PendingAssistantApproval> build() => const [];

  /// Resolves true only on the user's explicit consent; [withdrawn] removes
  /// the card when the run stops waiting.
  Future<bool> ask(ApprovalPrompt prompt, Future<void> withdrawn) {
    final pending = PendingAssistantApproval(
      'approval_${_sequence++}',
      prompt,
      Completer<bool>(),
    );
    state = [...state, pending];
    unawaited(withdrawn.then((_) => _settle(pending.id, false)));
    return pending._answer.future;
  }

  void answer(String id, bool approved) => _settle(id, approved);

  void _settle(String id, bool approved) {
    final pending = state.where((p) => p.id == id).firstOrNull;
    if (pending == null) return;
    state = [
      for (final p in state)
        if (p.id != id) p,
    ];
    if (!pending._answer.isCompleted) pending._answer.complete(approved);
  }
}

final assistantApprovalsProvider =
    NotifierProvider<
      AssistantApprovalsNotifier,
      List<PendingAssistantApproval>
    >(AssistantApprovalsNotifier.new);

/// The user's choice to approve every change the assistant makes (ADR0073
/// decision 3): the reviewer is skipped and nothing runs unasked. Kept on
/// this device only; the assistant has no tool to change it.
class AssistantAlwaysAskNotifier extends AsyncNotifier<bool> {
  static const prefsKey = 'assistant_always_ask_v1';

  @override
  Future<bool> build() async =>
      (await SharedPreferences.getInstance()).getBool(prefsKey) ?? false;

  Future<void> set(bool value) async {
    await (await SharedPreferences.getInstance()).setBool(prefsKey, value);
    state = AsyncValue.data(value);
  }
}

final assistantAlwaysAskProvider =
    AsyncNotifierProvider<AssistantAlwaysAskNotifier, bool>(
      AssistantAlwaysAskNotifier.new,
    );
