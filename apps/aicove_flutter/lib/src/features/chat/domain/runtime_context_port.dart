import '../../memory/domain/compaction_memory.dart';

abstract interface class RuntimeContextPort {
  Future<List<Map<String, dynamic>>> prepare(
    List<Map<String, dynamic>> messages, {
    bool force = false,
  });
}

abstract interface class RuntimeContextStorePort {
  Future<String> save({
    required String owner,
    required List<Map<String, dynamic>> source,
    required List<Map<String, dynamic>> replacement,
    List<CompactionMemoryUpdate> updates = const [],
    String? expectedSourceId,
  });
  Future<String?> read(
    String owner,
    String id,
    int messageIndex, {
    int offset = 0,
    String? query,
  });
}
