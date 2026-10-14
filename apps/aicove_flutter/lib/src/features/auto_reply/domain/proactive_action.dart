/// What a proactive trigger does when it fires (plan 12, §4.8).
///
/// [sendMessage] needs no tool: the text the chat model writes is the
/// message. [callUser] is offered as the `call_user` tool only when the user
/// allowed proactive calls and the role can take a call; the tool call is
/// recorded while writing ahead and carried out at fire time.
enum ProactiveAction {
  sendMessage('send_message'),
  callUser('call_user');

  const ProactiveAction(this.id);

  /// Stored in the trigger JSON and used as the tool name.
  final String id;

  static ProactiveAction fromId(String? id) {
    for (final action in values) {
      if (action.id == id) return action;
    }
    return sendMessage;
  }
}

/// A reply written ahead of its fire time. For [ProactiveAction.callUser]
/// [text] is the opening line spoken once the user picks up; it doubles as
/// the message text when a guardrail turns the call back into a message.
class ProactiveDraft {
  const ProactiveDraft({
    required this.text,
    this.action = ProactiveAction.sendMessage,
  });

  final String text;
  final ProactiveAction action;

  bool get isCall => action == ProactiveAction.callUser;
}

/// The argument of the `call_user` tool.
const String callUserOpeningLineArg = 'opening_line';
