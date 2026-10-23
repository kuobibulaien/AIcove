import 'package:flutter/widgets.dart';

import '../../../../features/ui_blocks/domain/ui_block.dart' show UiNode;
import 'ui_block_style.dart';

/// What an action panel (ADR0094) is drawn from: its props, the state the
/// user left it in and how to keep a new one.
class UiActionPanelRequest {
  const UiActionPanelRequest({
    required this.node,
    required this.style,
    required this.saved,
    this.save,
    this.ask,
  });

  final UiNode node;
  final UiBlockStyle style;

  /// Cleaned saved state; empty when nothing was kept.
  final Map<String, Object?> saved;

  /// Replaces the saved state; null where nothing is stored.
  final ValueChanged<Map<String, Object?>>? save;
  final ValueChanged<String>? ask;
}

typedef UiActionPanelBuilder =
    Widget Function(BuildContext context, UiActionPanelRequest request);

/// Where interactive blocks (ADR0073 交互组件) of a chat live: the chat list
/// puts one above its messages. Without it (exports, previews) blocks keep
/// plain local state, store nothing and their `ask` buttons do nothing.
class MoeUiBlockScope extends InheritedWidget {
  const MoeUiBlockScope({
    super.key,
    required this.conversationId,
    required this.onAsk,
    this.actions,
    required super.child,
  });

  final String conversationId;

  /// Renderers of action panels by component name; only the assistant chat
  /// gives them (ADR0094). Elsewhere such blocks show a note and do nothing.
  final Map<String, UiActionPanelBuilder>? actions;

  /// Puts a follow-up into the composer; never sends it.
  final ValueChanged<String> onAsk;

  static MoeUiBlockScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MoeUiBlockScope>();

  @override
  bool updateShouldNotify(MoeUiBlockScope oldWidget) =>
      conversationId != oldWidget.conversationId ||
      onAsk != oldWidget.onAsk ||
      actions != oldWidget.actions;
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
