import 'dart:math';
import '../../../core/app_logger.dart';
import '../../../core/database/repositories/memory_repository.dart';
import '../../../core/network/json_http_client.dart';
import '../../../core/prompts/prompt_builtin_defaults.g.dart';
import '../../../core/prompts/prompt_template_renderer.dart';
import '../models/memory_entity.dart';
import 'memory_service.dart';

class MemoryMergerService {
  final MemoryRepository _memoryRepository;
  final ResolvedModelConfig? _mergeModel;

  MemoryMergerService(
    this._memoryRepository, {
    ResolvedModelConfig? mergeModel,
  }) : _mergeModel = mergeModel;

  Future<MemoryEntity?> findRelatedMemory({
    required String conversationId,
    required String newFact,
    required List<double> newEmbedding,
  }) async {
    final entities = extractEntities(newFact);
    final candidates = await _memoryRepository.findPotentialRelatedL2(
      conversationId: conversationId,
      entities: entities,
      limit: 50,
    );
    if (candidates.isEmpty) return null;

    MemoryEntity? best;
    var bestScore = -1.0;
    for (final c in candidates) {
      if (c.embedding.isEmpty || newEmbedding.isEmpty) continue;
      final sim = _cosineSimilarity(c.embedding, newEmbedding);
      if (sim > 0.65 && sim > bestScore) {
        best = c;
        bestScore = sim;
      }
    }
    return best;
  }

  Future<String> mergeMemories({
    required String oldContent,
    required String newFact,
  }) async {
    final model = _mergeModel;
    if (model == null || !model.isValid) {
      return _fallbackMerge(oldContent: oldContent, newFact: newFact);
    }

    final prompt = PromptTemplateRenderer.renderTrimmed(
      PromptBuiltinDefaults.requireTemplate('memory.merge.prompt'),
      <String, Object?>{
        'old_content': oldContent,
        'new_fact': newFact,
      },
    );

    final url = Uri.parse('${model.baseUrl}/chat/completions');
    try {
      final response = await JsonHttpClient.postJson(
        uri: url,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${model.apiKey}',
        },
        jsonBody: {
          'model': model.model,
          'messages': [
            {'role': 'user', 'content': prompt}
          ],
          'temperature': 0.2,
        },
      );
      final content =
          response.data['choices']?[0]?['message']?['content'] as String?;
      if (content != null && content.trim().isNotEmpty) {
        return content.trim();
      }
    } catch (e) {
      AppLogger.warning('MemoryMergerService', 'AI merge failed; fallback used',
          metadata: {
            'error': e.toString(),
          });
    }

    return _fallbackMerge(oldContent: oldContent, newFact: newFact);
  }

  List<String> extractEntities(String text) {
    final entities = <String>{};
    for (final m in RegExp(r'[\u4e00-\u9fa5]{2,6}').allMatches(text)) {
      final token = m.group(0);
      if (token == null) continue;
      if (token.length >= 2) entities.add(token);
    }
    for (final m in RegExp(r'[A-Za-z0-9_]{3,}').allMatches(text)) {
      final token = m.group(0);
      if (token == null) continue;
      entities.add(token.toLowerCase());
    }
    return entities.take(8).toList();
  }

  String _fallbackMerge({
    required String oldContent,
    required String newFact,
  }) {
    final lines =
        oldContent.split('\n').where((e) => e.trim().isNotEmpty).toList();
    final oldLine = lines.isEmpty ? oldContent.trim() : lines.first;
    return '$oldLine\n- 更新：$newFact\n→ 当前状态：以最新事实为准';
  }

  double _cosineSimilarity(List<double> a, List<double> b) {
    if (a.length != b.length || a.isEmpty) return 0.0;
    double dot = 0;
    double normA = 0;
    double normB = 0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }
    if (normA == 0 || normB == 0) return 0.0;
    return dot / (sqrt(normA) * sqrt(normB));
  }
}
