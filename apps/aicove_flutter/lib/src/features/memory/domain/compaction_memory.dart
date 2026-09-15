import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'contact_memory_port.dart';

String memoryTextDigest(String text) =>
    sha256.convert(utf8.encode(text)).toString();

String memoryEventDigest(ContactMemoryEvent event) =>
    memoryTextDigest(jsonEncode([event.title, event.body, event.memoryKind]));

/// 模型只提出有来源的增量；既有手写内容不在可写目标中。
class CompactionMemoryUpdate {
  const CompactionMemoryUpdate({
    required this.key,
    required this.title,
    required this.body,
    required this.kind,
    required this.sourceIds,
    this.existingId,
    this.expectedDigest,
  });
  final String key, title, body, kind;
  final List<String> sourceIds;
  final String? existingId, expectedDigest;
  Map<String, dynamic> toJson() => {
    'key': key,
    'title': title,
    'body': body,
    'kind': kind,
    'sourceIds': sourceIds,
    'existingId': existingId,
    'expectedDigest': expectedDigest,
  };
  factory CompactionMemoryUpdate.fromJson(Map<String, dynamic> json) =>
      CompactionMemoryUpdate(
        key: json['key'] as String,
        title: json['title'] as String,
        body: json['body'] as String,
        kind: json['kind'] as String,
        sourceIds: (json['sourceIds'] as List).cast<String>(),
        existingId: json['existingId'] as String?,
        expectedDigest: json['expectedDigest'] as String?,
      );
}

class CompactionMemoryJob {
  const CompactionMemoryJob(this.id, this.owner, this.updates);
  final String id, owner;
  final List<CompactionMemoryUpdate> updates;
}

abstract interface class CompactionMemoryQueuePort {
  Future<List<CompactionMemoryJob>> pending(String owner);
  Future<bool> sourcesValid(String jobId);
  Future<void> finish(String jobId, {bool discarded = false});
}

abstract interface class CompactionMemoryPort {
  Future<ContactMemoryNotebook?> prepare(String owner);
  Future<bool> flush(String owner);
}
