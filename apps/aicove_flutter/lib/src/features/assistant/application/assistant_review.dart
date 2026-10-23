import 'dart:async';
import 'dart:convert';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart';

/// Risk tier retained for manual confirmation, quick panels and review clients.
/// Default assistant runs allow every tier without review (ADR0107).
enum AssistantRisk {
  /// Reads only.
  readOnly,

  /// Undoable change the user can see at once: runs and offers an undo.
  reversible,

  /// Content changes and anything the user may not have asked for: the
  /// reviewer decides, and may hand it to the user.
  review,

  /// Requires the user rather than a reviewer when approval is requested.
  major,
}

/// Risk of a call by tool name and arguments; null for tools that are not
/// the assistant's own, which run as in ordinary chat.
typedef AssistantRiskOf =
    AssistantRisk? Function(String toolName, Map<String, dynamic> arguments);

bool _never() => false;

class AssistantToolGate implements ToolGate {
  const AssistantToolGate(this.riskOf, {this.alwaysAsk = _never});

  final AssistantRiskOf riskOf;

  /// The user wants to approve every change: reversible ones, and tools of
  /// other plugins that are not reads. Read on every call, so switching it
  /// takes effect inside a running reply.
  final bool Function() alwaysAsk;

  static bool _reads(ToolEffect effect) =>
      effect == ToolEffect.readDiagnostic || effect == ToolEffect.readPrivate;

  static const _unrestricted = #assistantUnrestricted;

  /// True only inside a call allowed by the assistant's no-approval policy.
  /// Handlers may use this instead of requiring per-call consent.
  static bool get unrestricted =>
      ToolCallScope.current?.outcome == GateOutcome.allowed &&
      ToolCallScope.current?.notes[_unrestricted] == true;

  @override
  GateVerdict check(KernelToolCall call, ToolEffect effect) {
    // Rating also records the target snapshot used by write conflict checks.
    final risk = riskOf(call.name, call.arguments);
    final manual = alwaysAsk();
    ToolCallScope.current?.notes[_unrestricted] = !manual;
    if (!manual ||
        risk == AssistantRisk.readOnly ||
        (risk == null && _reads(effect))) {
      return const GateVerdict.allow();
    }
    return const GateVerdict.ask('每次都问我');
  }
}

enum ReviewVerdict { allow, deny, askUser }

class ReviewResult {
  const ReviewResult(this.verdict, this.reason);

  final ReviewVerdict verdict;
  final String reason;
}

/// The reviewer model. It sees what the user said and the call the agent
/// wants to make, never the agent's own text or tool results, so neither
/// the agent nor content it read can talk it into approving.
class AssistantReviewer {
  AssistantReviewer(this.complete);

  /// One model request without tools; returns the reply text.
  final Future<String> Function(List<Map<String, dynamic>> messages) complete;

  /// Longer text arguments are not reviewed: the user approves them.
  static const argumentLimit = 8000;

  static bool tooLongToReview(Map<String, dynamic> arguments) => arguments
      .values
      .any((value) => value is String && value.length > argumentLimit);

  static const systemPrompt =
      '你是 AIcove酱的修改审核员。AIcove酱是一个帮用户写角色卡、'
      '调插件和酒馆预设的 Agent，它现在想调用一个修改工具。'
      '你只能看到用户最近说的话和这次工具调用，看不到助手自己的解释。\n'
      '判断规则：\n'
      '- allow：这次修改是用户明确要求的，或者是完成用户请求直接需要的一步，'
      '且范围没有超出用户的意思。\n'
      '- deny：用户没有要求这类修改，或者修改范围明显大于用户的意思'
      '（比如只让改一句却整段重写、让看看却直接改、改了别的角色）。'
      '理由要具体，让助手知道该怎么换做法。\n'
      '- ask_user：用户的意思不明确，或者修改会覆盖用户可能很在意的大段内容，'
      '需要用户亲自确认。\n'
      '用户的泛泛请求（「帮我优化一下」）可以授权与之相符的修改，'
      '但不授权删除或改动用户没提到的角色和预设。\n'
      '只输出一个 JSON 对象，不要输出别的：'
      '{"verdict":"allow|deny|ask_user","reason":"一句话理由"}';

  Future<ReviewResult> review({
    required List<String> userMessages,
    required String toolName,
    required String toolDescription,
    required Map<String, dynamic> arguments,
  }) async {
    final request = [
      '## 用户最近说的话（从早到晚）',
      for (final (index, text) in userMessages.indexed) '${index + 1}. $text',
      if (userMessages.isEmpty) '（没有）',
      '',
      '## 助手想调用的工具',
      '$toolName：$toolDescription',
      '参数：${jsonEncode(_clipped(arguments))}',
    ].join('\n');
    final reply = await complete([
      {'role': 'system', 'content': systemPrompt},
      {'role': 'user', 'content': request},
    ]);
    return parse(reply);
  }

  static Map<String, dynamic> _clipped(Map<String, dynamic> arguments) => {
    for (final MapEntry(:key, :value) in arguments.entries)
      key: value is String && value.length > argumentLimit
          ? '${value.substring(0, argumentLimit)}…（共 ${value.length} 字）'
          : value,
  };

  /// Anything that is not a well-formed verdict hands the call to the user;
  /// a reviewer that cannot answer never approves.
  static ReviewResult parse(String reply) {
    final start = reply.indexOf('{');
    final end = reply.lastIndexOf('}');
    if (start >= 0 && end > start) {
      try {
        final json = jsonDecode(reply.substring(start, end + 1));
        if (json is Map) {
          final reason = (json['reason'] ?? '').toString().trim();
          final verdict = switch ((json['verdict'] ?? '').toString().trim()) {
            'allow' => ReviewVerdict.allow,
            'deny' => ReviewVerdict.deny,
            'ask_user' => ReviewVerdict.askUser,
            _ => null,
          };
          if (verdict != null) {
            return ReviewResult(verdict, reason.isEmpty ? '未说明' : reason);
          }
        }
      } on FormatException {
        // Falls through to asking the user.
      }
    }
    return const ReviewResult(ReviewVerdict.askUser, '审核结果无法解析');
  }
}

/// What the user sees when asked to approve one call.
class ApprovalPrompt {
  const ApprovalPrompt({required this.title, required this.detail});

  factory ApprovalPrompt.workspaceScript(String workspaceName) =>
      ApprovalPrompt(
        title: '运行脚本',
        detail: '在空间「$workspaceName」里运行脚本，可能访问网络；空间内的改动可以撤销',
      );

  factory ApprovalPrompt.workspaceShell(String workspaceName, String command) =>
      ApprovalPrompt(
        title: '运行命令',
        detail: '在空间「$workspaceName」里执行：\n$command\n命令可能改动空间以外的文件，命令造成的改动无法撤销',
      );

  final String title;
  final String detail;
}

/// Approval channel of one assistant run: [AssistantRisk.major] always asks
/// the user; [AssistantRisk.review] asks the reviewer, which may hand it to
/// the user. Three rejections in a row stop automatic review for the run.
class AssistantApprovalPort implements ExplainingApprovalPort {
  AssistantApprovalPort({
    required this.riskOf,
    required this.describe,
    required this.toolDescription,
    required this.userMessages,
    required this.review,
    required this.askUser,
    this.alwaysAsk = _never,
  });

  final AssistantRiskOf riskOf;

  /// Every change goes to the user; the reviewer is not asked.
  final bool Function() alwaysAsk;

  /// May look the target up first, so the card names what it changes.
  final FutureOr<ApprovalPrompt> Function(
    String toolName,
    Map<String, dynamic> args,
  )
  describe;
  final String Function(String toolName) toolDescription;
  final List<String> userMessages;
  final Future<ReviewResult> Function({
    required List<String> userMessages,
    required String toolName,
    required String toolDescription,
    required Map<String, dynamic> arguments,
  })
  review;

  /// Resolves true only when the user approves; [withdrawn] completes if
  /// the run stops waiting.
  final Future<bool> Function(ApprovalPrompt prompt, Future<void> withdrawn)
  askUser;

  static const rejectionLimit = 3;
  int _rejections = 0;

  @override
  Future<bool> request(ApprovalRequest request) =>
      answer(request).then((answer) => answer.approved);

  @override
  Future<ApprovalAnswer> answer(ApprovalRequest request) async {
    final risk = riskOf(request.toolName, request.arguments);
    if (request.requiresHumanApproval ||
        risk == AssistantRisk.major ||
        alwaysAsk() ||
        AssistantReviewer.tooLongToReview(request.arguments)) {
      return _askUser(request);
    }
    if (_rejections >= rejectionLimit) {
      return const ApprovalAnswer.rejected(
        '本轮已连续 $rejectionLimit 次未获允许，自动审核已停止。'
        '不要再尝试修改，把你打算做的修改和原因告诉用户，由用户决定。',
      );
    }
    final ReviewResult result;
    try {
      result = await review(
        userMessages: userMessages,
        toolName: request.toolName,
        toolDescription: toolDescription(request.toolName),
        arguments: request.arguments,
      );
    } catch (_) {
      return _askUser(request);
    }
    switch (result.verdict) {
      case ReviewVerdict.allow:
        _rejections = 0;
        return const ApprovalAnswer.approved();
      case ReviewVerdict.deny:
        _rejections++;
        return ApprovalAnswer.rejected('审核未通过：${result.reason}');
      case ReviewVerdict.askUser:
        return _askUser(request);
    }
  }

  Future<ApprovalAnswer> _askUser(ApprovalRequest request) async {
    final approved = await askUser(
      await describe(request.toolName, request.arguments),
      request.withdrawn,
    );
    if (approved) {
      ToolCallScope.current?.humanApproved = true;
      _rejections = 0;
      return const ApprovalAnswer.approved();
    }
    _rejections++;
    return const ApprovalAnswer.rejected('用户没有同意这次修改，先问问用户想怎么改');
  }
}
