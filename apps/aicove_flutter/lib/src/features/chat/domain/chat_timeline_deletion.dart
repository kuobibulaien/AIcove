/// Identity shared by timeline pieces, projections and canonical raw messages.
abstract final class ChatTimelinePieceId {
  static const String separator = '__piece_';

  static String compose(String parentMessageId, String pieceKey) =>
      '$parentMessageId$separator$pieceKey';

  static bool isPieceId(String id) => id.contains(separator);

  static String? parentMessageIdOf(String id) {
    final index = id.indexOf(separator);
    return index > 0 ? id.substring(0, index) : null;
  }

  static String rawMessageIdOf(String id, {String? explicitSourceId}) {
    final source = explicitSourceId?.trim();
    if (source != null && source.isNotEmpty) return source;
    final base = parentMessageIdOf(id) ?? id.trim();
    // Semantic and legacy projection IDs share the same raw ID prefix.
    final index = base.lastIndexOf('__proj_');
    return index > 0 ? base.substring(0, index) : base;
  }
}

class ChatTimelineDeletePlan {
  const ChatTimelineDeletePlan({
    this.stagedMessageIds = const <String>[],
    this.rawMessageIdsToDelete = const <String>[],
    this.turnAnchorMessageIdsToDelete = const <String>[],
    this.projectedMessageIdsToHide = const <String>[],
    this.pieceIdsToHide = const <String>[],
  });

  final List<String> stagedMessageIds;
  final List<String> rawMessageIdsToDelete;
  final List<String> turnAnchorMessageIdsToDelete;
  final List<String> projectedMessageIdsToHide;
  final List<String> pieceIdsToHide;

  bool get isEmpty =>
      stagedMessageIds.isEmpty && !hasCanonicalDeletion && !hasPartialHide;
  bool get hasCanonicalDeletion =>
      rawMessageIdsToDelete.isNotEmpty ||
      turnAnchorMessageIdsToDelete.isNotEmpty;
  bool get hasPartialHide =>
      projectedMessageIdsToHide.isNotEmpty || pieceIdsToHide.isNotEmpty;
}
