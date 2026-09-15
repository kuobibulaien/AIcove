import 'package:flutter/foundation.dart';

import '../../../../features/chat/domain/message.dart';

/// Page-owned selection of displayed bubbles, independent of raw chat history.
class ChatMessageSelection extends ChangeNotifier {
  bool _active = false;
  Map<String, Message> _messages = {};
  Set<String> _selected = {};
  Set<String>? _dragBaseline;
  String? _dragAnchor;
  bool _dragSelects = true;

  bool get active => _active;
  int get count => _selected.length;
  bool contains(String id) => _selected.contains(id);
  bool canSelect(String id) => _messages.containsKey(id);

  List<Message> get selectedMessages => List.unmodifiable(
    _messages.values.where((message) => _selected.contains(message.id)),
  );

  /// Called by the timeline owner; returns whether the count was pruned.
  /// Notification is deferred by the owner when synchronizing during build.
  bool updateMessages(Iterable<Message> messages) {
    _messages = {
      for (final message in messages)
        if (message.status != 'sending') message.id: message,
    };
    final previousCount = count;
    _selected.removeWhere((id) => !_messages.containsKey(id));
    return previousCount != count;
  }

  void refresh() => notifyListeners();

  void enter() {
    _active = true;
    _selected.clear();
    notifyListeners();
  }

  void start(String id) {
    if (!canSelect(id)) return;
    _active = true;
    _selected = {id};
    notifyListeners();
  }

  void toggle(String id) {
    if (!_active || !canSelect(id)) return;
    if (!_selected.remove(id)) _selected.add(id);
    notifyListeners();
  }

  void beginDrag(String id) {
    if (!_active || !canSelect(id)) return;
    _dragBaseline = Set.of(_selected);
    _dragAnchor = id;
    _dragSelects = !_selected.contains(id);
    extendDrag(id);
  }

  /// Reversing a drag restores selections outside the current range.
  /// IDs keep the anchor stable when older messages are loaded at the edge.
  void extendDrag(String id) {
    final baseline = _dragBaseline;
    if (baseline == null) return;
    final ids = _messages.keys.toList(growable: false);
    final anchor = ids.indexOf(_dragAnchor!);
    final target = ids.indexOf(id);
    if (anchor < 0 || target < 0) return;
    final first = anchor < target ? anchor : target;
    final last = anchor > target ? anchor : target;
    final range = ids.sublist(first, last + 1);
    final next = Set<String>.of(baseline);
    if (_dragSelects) {
      next.addAll(range);
    } else {
      next.removeAll(range);
    }
    next.removeWhere((id) => !_messages.containsKey(id));
    if (setEquals(next, _selected)) return;
    _selected = next;
    notifyListeners();
  }

  void endDrag() {
    _dragAnchor = null;
    _dragBaseline = null;
  }

  void clear() {
    endDrag();
    _active = false;
    _selected.clear();
    notifyListeners();
  }
}
