import 'package:crypto/crypto.dart';
import 'dart:convert';
import 'package:uuid/uuid.dart';
import '../../../core/app_logger.dart';
import '../../../core/database/repositories/memory_repository.dart';
import '../models/memory_entity.dart';
import '../utils/memory_time_formatter.dart';

class ProfileService {
  final MemoryRepository _memoryRepository;
  final int promoteThreshold;

  ProfileService(
    this._memoryRepository, {
    this.promoteThreshold = 3,
  });

  Future<String> getProfilePrompt(String conversationId) async {
    final profiles = await _memoryRepository.getProfileMemories(conversationId);
    if (profiles.isEmpty) return '';

    final sorted = [...profiles]
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    if (sorted.length > 15) {
      AppLogger.warning(
          'ProfileService', 'L1 profile entries exceed recommended limit',
          metadata: {
            'conversationId': conversationId,
            'count': sorted.length,
          });
    }

    final buffer = StringBuffer()..writeln('## 用户画像');
    for (final p in sorted.take(15)) {
      buffer.writeln(
        '- ${MemoryTimeFormatter.getTimePrefix(p.createdAt)}：${p.content.trim()}',
      );
    }
    return buffer.toString();
  }

  Future<void> checkAndPromoteProfile({
    required String conversationId,
    required String trait,
    required String evidence,
  }) async {
    final normalizedTrait = trait.trim();
    if (normalizedTrait.isEmpty) return;

    final existing = await _memoryRepository.getProfileMemories(conversationId);
    final existed = existing.any((m) => m.content.contains(normalizedTrait));
    if (existed) return;

    final l2 = await _memoryRepository.getLayerMemories(conversationId, 'L2',
        limit: 500);
    final hitCount =
        l2.where((m) => m.content.contains(normalizedTrait)).length;
    if (hitCount + 1 < promoteThreshold) return;

    final content = evidence.trim().isEmpty
        ? normalizedTrait
        : '$normalizedTrait（依据：$evidence）';
    final memory = MemoryEntity(
      id: const Uuid().v4(),
      content: content,
      layer: 'L1',
      category: 'core_preference',
      conversationId: conversationId,
      contentHash: sha256.convert(utf8.encode(content)).toString(),
      persistenceP: MemoryEntity.categoryToPersistenceP('core_preference'),
      createdAt: DateTime.now(),
    ).recalculateImportance();

    await _memoryRepository.upsertProfileMemory(memory);
    AppLogger.info('ProfileService', 'Promoted profile trait', metadata: {
      'conversationId': conversationId,
      'trait': normalizedTrait,
      'evidenceHits': hitCount + 1,
    });
  }

  Future<void> updateProfileEntry(String id, String newContent) async {
    final current = await _memoryRepository.getById(id);
    if (current == null || current.layer != 'L1') return;
    final content = newContent.trim();
    if (content.isEmpty) return;
    await _memoryRepository.updateMemory(
      current.copyWith(
        content: content,
        contentHash: sha256.convert(utf8.encode(content)).toString(),
        updatedAt: DateTime.now(),
      ),
    );
  }

  Future<int> getProfileCount(String conversationId) {
    return _memoryRepository.getProfileCount(conversationId);
  }
}
