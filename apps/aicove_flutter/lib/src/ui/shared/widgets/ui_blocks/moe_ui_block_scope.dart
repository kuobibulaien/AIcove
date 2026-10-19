import 'package:flutter/widgets.dart';

/// Where interactive blocks (ADR0073 交互组件) of a chat live: the chat list
/// puts one above its messages. Without it (exports, previews) blocks keep
/// plain local state, store nothing and their `ask` buttons do nothing.
class MoeUiBlockScope extends InheritedWidget {
  const MoeUiBlockScope({
    super.key,
    required this.conversationId,
    required this.onAsk,
    required super.child,
  });

  final String conversationId;

  /// Puts a follow-up into the composer; never sends it.
  final ValueChanged<String> onAsk;

  static MoeUiBlockScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MoeUiBlockScope>();

  @override
  bool updateShouldNotify(MoeUiBlockScope oldWidget) =>
      conversationId != oldWidget.conversationId || onAsk != oldWidget.onAsk;
}

/// The raw message a block belongs to; its state is stored under this id.
class MoeUiBlockMessage extends InheritedWidget {
  const MoeUiBlockMessage({
    super.key,
    required this.messageId,
    required super.child,
  });

  final String messageId;

  static String? maybeIdOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MoeUiBlockMessage>()?.messageId;

  @override
  bool updateShouldNotify(MoeUiBlockMessage oldWidget) =>
      messageId != oldWidget.messageId;
}
