import 'dart:math';
import '../../plugins/domain/handlers/ai_tool.dart';
import 'codemode_declarations.dart';

/// BM25 catalog lookup; all grants remain in the catalog, even when omitted
/// from the inline description. Ties keep registration order.
class CodemodeSearch {
  CodemodeSearch(Iterable<AITool> tools) : tools = tools.toList();
  final List<AITool> tools;
  static List<String> _tokens(String text) => RegExp(
    r'[a-z0-9]+|[\u3400-\u9fff]',
  ).allMatches(text.toLowerCase()).map((m) => m[0]!).toList();
  List<Map<String, dynamic>> search(
    String query, {
    int limit = 8,
    String? namespace,
  }) {
    final candidates = [
      for (final tool in tools)
        if (namespace == null || namespace == toolNamespace(tool)) tool,
    ];
    if (candidates.isEmpty) return [];
    final docs = [
      for (final tool in candidates)
        _tokens('${tool.name.replaceAll('_', ' ')} ${tool.description}'),
    ];
    final avg = docs.fold<int>(0, (n, d) => n + d.length) / docs.length;
    final scores = <(int, double)>[];
    for (var i = 0; i < docs.length; i++) {
      var score = 0.0;
      for (final word in _tokens(query).toSet()) {
        final frequency = docs[i].where((v) => v == word).length;
        if (frequency == 0) continue;
        final df = docs.where((d) => d.contains(word)).length;
        final idf = log(1 + (docs.length - df + 0.5) / (df + 0.5));
        score +=
            idf *
            (frequency * 2.2) /
            (frequency +
                1.2 * (0.25 + 0.75 * docs[i].length / (avg == 0 ? 1 : avg)));
      }
      if (score > 0 || query.trim().isEmpty) scores.add((i, score));
    }
    scores.sort(
      (a, b) => b.$2.compareTo(a.$2) == 0
          ? a.$1.compareTo(b.$1)
          : b.$2.compareTo(a.$2),
    );
    return [
      for (final item in scores.take(limit.clamp(0, 100)))
        describeCodemodeTool(candidates[item.$1]),
    ];
  }
}
