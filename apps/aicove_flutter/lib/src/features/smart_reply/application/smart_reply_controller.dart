import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../domain/smart_reply.dart';
import '../infrastructure/smart_reply_adapter.dart';

/// Session-only candidates; never delivered to chat history or persisted.
final smartReplyControllerProvider = Provider.autoDispose
    .family<SmartReplyController, String>(
      (ref, id) => SmartReplyController(ref.watch(smartReplyPortProvider), id),
    );

/// Scoped insertion avoids delivering a suggestion to another conversation.
final smartReplyDraftProvider = StateProvider.autoDispose
    .family<String?, String>((ref, id) => null);

class SmartReplyController {
  SmartReplyController(this.port, this.conversationId);
  final SmartReplyPort port;
  final String conversationId;
  String? _key;
  List<String>? _cached;
  final _pending = <String, Future<List<String>>>{};

  Future<List<String>> load(String modelRef) => _pending.putIfAbsent(
    modelRef,
    () => _load(modelRef).whenComplete(() {
      _pending.remove(modelRef);
    }),
  );

  Future<List<String>> _load(String modelRef) async {
    final snapshot = await port.snapshot(conversationId);
    final key = '$modelRef:${snapshot.revision}';
    if (_key == key && _cached != null) return _cached!;
    final replies = await port.generate(snapshot, modelRef);
    if ((await port.snapshot(conversationId)).revision != snapshot.revision) {
      throw const FormatException('对话已更新，请重新生成辅助回答');
    }
    _key = key;
    return _cached = List.unmodifiable(replies);
  }

  Future<bool> isCurrent(String modelRef) async =>
      _key == '$modelRef:${(await port.snapshot(conversationId)).revision}';
}
