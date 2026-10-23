import 'dart:async';
import 'dart:convert';

import '../../plugins/domain/handlers/ai_tool.dart';
import 'assistant_review.dart';

/// What came of one tap in a quick panel.
sealed class PanelActionResult {
  const PanelActionResult();
}

class PanelActionDone extends PanelActionResult {
  const PanelActionDone(this.change, {this.undoable = false});

  /// One line on what changed, from the tool.
  final String change;
  final bool undoable;
}

/// The user said no in the confirmation dialog.
class PanelActionCancelled extends PanelActionResult {
  const PanelActionCancelled();
}

class PanelActionFailed extends PanelActionResult {
  const PanelActionFailed(this.message);
  final String message;
}

/// Runs what the user tapped in a quick panel (ADR0094) through the
/// assistant's own tool, so it is rated, checked and journaled exactly like
/// the model's call. The tap is the user's consent: read-only, reversible
/// and review-tier calls run at once (the reviewer guards against the
/// model, not the user); major ones, and every change while 「修改前每次问我」
/// is on, wait for [confirm].
class AssistantPanelActions {
  AssistantPanelActions({
    required this.tools,
    required this.riskOf,
    required this.describe,
    required this.alwaysAsk,
  });

  final List<AITool> Function() tools;
  final AssistantRiskOf riskOf;
  final FutureOr<ApprovalPrompt> Function(
    String toolName,
    Map<String, dynamic> args,
  )
  describe;
  final bool Function() alwaysAsk;

  Future<PanelActionResult> run(
    String toolName,
    Map<String, dynamic> args, {
    required Future<bool> Function(ApprovalPrompt prompt) confirm,
  }) async {
    final tool = tools().where((t) => t.name == toolName).firstOrNull;
    final risk = riskOf(toolName, args);
    // Only the assistant's own tools: anything else has no rating here.
    if (tool == null || risk == null) {
      return PanelActionFailed('AIcove酱没有这个操作：$toolName');
    }
    final asks =
        risk == AssistantRisk.major ||
        (risk != AssistantRisk.readOnly && alwaysAsk());
    if (asks && !await confirm(await describe(toolName, args))) {
      return const PanelActionCancelled();
    }
    final Object? reply;
    try {
      reply = jsonDecode(await tool.handler(args) ?? '{}');
    } on StateError catch (error) {
      return PanelActionFailed(error.message);
    } on FormatException catch (error) {
      return PanelActionFailed(error.message);
    } on Exception catch (error) {
      // Storage failures (the undo journal on disk) end as a message, not
      // as a panel stuck waiting.
      return PanelActionFailed('没改成：$error');
    }
    if (reply is! Map) return const PanelActionFailed('操作没有返回结果');
    if (reply['error'] != null) {
      return PanelActionFailed('${reply['message'] ?? reply['error']}');
    }
    return PanelActionDone(
      '${reply['change'] ?? reply['note'] ?? reply['card'] ?? '已完成'}',
      undoable: reply['undo'] != null,
    );
  }
}
