import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import '../../../core/app_logger.dart';
import '../../../core/database/repositories/memory_repository.dart';
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

    final prompt = '''
你有一条已存在的记忆和一条新事实，它们是关于同一个主题。
请合并成一条带时间线的记忆：
1. 按时间顺序排列
2. 保留关键细节
3. 结尾必须包含 "→ 当前状态：..."

已存在记忆：
$oldContent

新事实：
$newFact

合并结果：
''';

    final url = Uri.parse('${model.baseUrl}/chat/completions');
    final client = http.Client();
    try {
      final response = await client.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${model.apiKey}',
        },
        body: jsonEncode({
          'model': model.model,
          'messages': [
            {'role': 'user', 'content': prompt}
          ],
          'temperature': 0.2,
        }),
      );
      if (response.statusCode >= 200 && response.statusCode < 300) {
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        final content = data['choices']?[0]?['message']?['content'] as String?;
        if (content != null && content.trim().isNotEmpty) {
          return content.trim();
        }
      }
    } catch (e) {
      AppLogger.warning('MemoryMergerService', 'AI merge failed; fallback used',
          metadata: {
            'error': e.toString(),
          });
    } finally {
      client.close();
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
    return '''
$oldLine
- 更新：$newFact
→ 当前状态：以最新事实为准
'''
        .trim();
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
