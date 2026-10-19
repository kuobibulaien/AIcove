import '../../chat/domain/message.dart';

/// Marks the persona message that relayed a receipt, so no device relays
/// it twice (ADR0088 §7).
const taskRelayReceiptKey = 'taskRelayReceiptId';

final _relayKeyPattern = RegExp('"$taskRelayReceiptKey":"([^"]+)"');

/// Reads the relay marker from an encoded raw payload without decoding it.
String? taskRelayReceiptIdFromEncoded(String? rawPayload) {
  if (rawPayload == null || !rawPayload.contains(taskRelayReceiptKey)) {
    return null;
  }
  return _relayKeyPattern.firstMatch(rawPayload)?.group(1);
}

String? taskRelayReceiptIdOf(Map<String, dynamic>? rawPayload) {
  final value = rawPayload?[taskRelayReceiptKey];
  return value is String && value.isNotEmpty ? value : null;
}

typedef TaskRelayMark = ({String receiptId, DateTime createdAt});

/// Each device may relay the same receipt before the other's relay syncs in.
/// All relays stay in raw history; display and request copies keep only the
/// earliest per receipt, ties broken by raw message ID (ADR0088 §7).
Set<String> supersededTaskRelayIds(Map<String, TaskRelayMark> relaysByRawId) {
  final winners = <String, MapEntry<String, TaskRelayMark>>{};
  final superseded = <String>{};
  for (final entry in relaysByRawId.entries) {
    final current = winners[entry.value.receiptId];
    if (current == null) {
      winners[entry.value.receiptId] = entry;
    } else if (_isEarlier(entry, current)) {
      superseded.add(current.key);
      winners[entry.value.receiptId] = entry;
    } else {
      superseded.add(entry.key);
    }
  }
  return superseded;
}

bool _isEarlier(
  MapEntry<String, TaskRelayMark> a,
  MapEntry<String, TaskRelayMark> b,
) {
  final byTime = a.value.createdAt.compareTo(b.value.createdAt);
  return byTime != 0 ? byTime < 0 : a.key.compareTo(b.key) < 0;
}

/// Request copy of raw history with duplicate relays dropped.
List<Message> dropSupersededTaskRelays(List<Message> rawMessages) {
  final relays = <String, TaskRelayMark>{
    for (final message in rawMessages)
      if (taskRelayReceiptIdOf(message.rawPayload) case final receiptId?)
        message.id: (receiptId: receiptId, createdAt: message.createdAt),
  };
  if (relays.length < 2) return rawMessages;
  final superseded = supersededTaskRelayIds(relays);
  if (superseded.isEmpty) return rawMessages;
  return [
    for (final message in rawMessages)
      if (!superseded.contains(message.id)) message,
  ];
}
