import '../domain/emoji_model.dart';
import 'emoji_manager.dart';

/// 匹配结果
class EmojiMatchResult {
  final EmojiModel emoji;
  final double score;
  final String matchType; // 'exact' | 'contain' | 'fuzzy' | 'semantic'

  const EmojiMatchResult({
    required this.emoji,
    required this.score,
    required this.matchType,
  });
}

/// 表情包匹配器
/// 实现混合匹配策略（方案3）
class EmojiMatcher {
  final EmojiManager _manager;

  /// 精确匹配阈值
  final double exactThreshold = 1.0;

  /// 包含匹配阈值
  final double containThreshold = 0.85;

  /// 模糊匹配阈值
  final double fuzzyThreshold = 0.6;

  /// 是否启用语义匹配
  final bool enableSemanticMatch;

  EmojiMatcher(this._manager, {this.enableSemanticMatch = false});

  /// 匹配表情包（主入口）
  /// 
  /// 策略优先级：
  /// 1. 精确匹配 (100%)
  /// 2. 包含匹配 (90%)
  /// 3. 模糊匹配 (60-85%)
  /// 4. 语义匹配 (60%)
  EmojiModel? match(String tag) {
    if (tag.isEmpty) return null;

    final allEmojis = _manager.getAllEmojis();
    if (allEmojis.isEmpty) return null;

    EmojiMatchResult? bestMatch;

    // Level 1: 精确匹配
    bestMatch = _exactMatch(tag, allEmojis);
    if (bestMatch != null && bestMatch.score >= exactThreshold) {
      print('[EmojiMatcher] 精确匹配: $tag -> ${bestMatch.emoji.id} (${bestMatch.score})');
      return bestMatch.emoji;
    }

    // Level 2: 包含匹配
    bestMatch = _containMatch(tag, allEmojis);
    if (bestMatch != null && bestMatch.score >= containThreshold) {
      print('[EmojiMatcher] 包含匹配: $tag -> ${bestMatch.emoji.id} (${bestMatch.score})');
      return bestMatch.emoji;
    }

    // Level 3: 模糊匹配
    bestMatch = _fuzzyMatch(tag, allEmojis);
    if (bestMatch != null && bestMatch.score >= fuzzyThreshold) {
      print('[EmojiMatcher] 模糊匹配: $tag -> ${bestMatch.emoji.id} (${bestMatch.score})');
      return bestMatch.emoji;
    }

    // Level 4: 语义匹配（可选）
    if (enableSemanticMatch) {
      bestMatch = _semanticMatch(tag, allEmojis);
      if (bestMatch != null && bestMatch.score >= fuzzyThreshold) {
        print('[EmojiMatcher] 语义匹配: $tag -> ${bestMatch.emoji.id} (${bestMatch.score})');
        return bestMatch.emoji;
      }
    }

    print('[EmojiMatcher] 未找到匹配: $tag');
    return null;
  }

  /// Level 1: 精确匹配
  EmojiMatchResult? _exactMatch(String tag, List<EmojiModel> emojis) {
    for (final emoji in emojis) {
      // 检查标签
      if (emoji.tags.contains(tag)) {
        return EmojiMatchResult(
          emoji: emoji,
          score: 1.0,
          matchType: 'exact',
        );
      }

      // 检查别名
      if (emoji.aliases.contains(tag)) {
        return EmojiMatchResult(
          emoji: emoji,
          score: 1.0,
          matchType: 'exact',
        );
      }
    }

    return null;
  }

  /// Level 2: 包含匹配
  /// 支持长标签匹配，如 "抱抱宝宝" 匹配 "抱抱"
  EmojiMatchResult? _containMatch(String tag, List<EmojiModel> emojis) {
    final candidates = <EmojiMatchResult>[];

    for (final emoji in emojis) {
      for (final t in emoji.allMatchableTexts) {
        double? score;

        // 情况1: 标签包含在输入中 ("抱抱" in "抱抱宝宝")
        if (tag.contains(t)) {
          // 匹配度 = 标签长度 / 输入长度
          score = t.length / tag.length;
        }
        // 情况2: 输入包含在标签中 ("抱" in "抱抱")
        else if (t.contains(tag)) {
          // 匹配度稍低
          score = tag.length / t.length * 0.9;
        }

        if (score != null) {
          candidates.add(EmojiMatchResult(
            emoji: emoji,
            score: score,
            matchType: 'contain',
          ));
          break; // 找到一个就跳出
        }
      }
    }

    // 返回得分最高的
    if (candidates.isEmpty) return null;
    candidates.sort((a, b) => b.score.compareTo(a.score));
    return candidates.first;
  }

  /// Level 3: 模糊匹配（基于字符串相似度）
  EmojiMatchResult? _fuzzyMatch(String tag, List<EmojiModel> emojis) {
    final candidates = <EmojiMatchResult>[];

    for (final emoji in emojis) {
      double maxScore = 0.0;

      for (final t in emoji.allMatchableTexts) {
        final similarity = _calculateSimilarity(tag, t);
        if (similarity > maxScore) {
          maxScore = similarity;
        }
      }

      if (maxScore > 0) {
        candidates.add(EmojiMatchResult(
          emoji: emoji,
          score: maxScore,
          matchType: 'fuzzy',
        ));
      }
    }

    if (candidates.isEmpty) return null;
    candidates.sort((a, b) => b.score.compareTo(a.score));
    return candidates.first;
  }

  /// Level 4: 语义匹配
  /// 基于预定义的语义分组
  EmojiMatchResult? _semanticMatch(String tag, List<EmojiModel> emojis) {
    final semanticGroups = _manager.getSemanticGroups();
    if (semanticGroups.isEmpty) return null;

    // 1. 找到tag所属的语义组
    String? targetGroup;
    for (final group in semanticGroups) {
      if (group.keywords.any((kw) => tag.contains(kw) || kw.contains(tag))) {
        targetGroup = group.name;
        break;
      }
    }

    if (targetGroup == null) return null;

    // 2. 找到同属该语义组的表情包
    final candidates = <EmojiMatchResult>[];
    for (final emoji in emojis) {
      for (final emojiTag in emoji.allMatchableTexts) {
        for (final group in semanticGroups) {
          if (group.name == targetGroup && group.keywords.contains(emojiTag)) {
            candidates.add(EmojiMatchResult(
              emoji: emoji,
              score: 0.7, // 语义匹配得分固定为0.7
              matchType: 'semantic',
            ));
            break;
          }
        }
      }
    }

    if (candidates.isEmpty) return null;

    // 3. 优先返回使用频率高的
    candidates.sort((a, b) {
      final scoreCompare = b.score.compareTo(a.score);
      if (scoreCompare != 0) return scoreCompare;
      return b.emoji.usageCount.compareTo(a.emoji.usageCount);
    });

    return candidates.first;
  }

  /// 计算字符串相似度（Levenshtein距离的归一化版本）
  /// 返回值范围：0.0 - 1.0
  double _calculateSimilarity(String s1, String s2) {
    if (s1.isEmpty && s2.isEmpty) return 1.0;
    if (s1.isEmpty || s2.isEmpty) return 0.0;
    if (s1 == s2) return 1.0;

    // 使用 Levenshtein 距离
    final distance = _levenshteinDistance(s1, s2);
    final maxLength = s1.length > s2.length ? s1.length : s2.length;

    // 归一化：相似度 = 1 - (距离 / 最大长度)
    return 1.0 - (distance / maxLength);
  }

  /// 计算 Levenshtein 距离（编辑距离）
  int _levenshteinDistance(String s1, String s2) {
    final len1 = s1.length;
    final len2 = s2.length;

    // 创建矩阵
    final matrix = List.generate(
      len1 + 1,
      (i) => List.filled(len2 + 1, 0),
    );

    // 初始化第一行和第一列
    for (var i = 0; i <= len1; i++) {
      matrix[i][0] = i;
    }
    for (var j = 0; j <= len2; j++) {
      matrix[0][j] = j;
    }

    // 填充矩阵
    for (var i = 1; i <= len1; i++) {
      for (var j = 1; j <= len2; j++) {
        final cost = s1[i - 1] == s2[j - 1] ? 0 : 1;

        matrix[i][j] = _min3(
          matrix[i - 1][j] + 1, // 删除
          matrix[i][j - 1] + 1, // 插入
          matrix[i - 1][j - 1] + cost, // 替换
        );
      }
    }

    return matrix[len1][len2];
  }

  /// 取三个数的最小值
  int _min3(int a, int b, int c) {
    return a < b ? (a < c ? a : c) : (b < c ? b : c);
  }

  /// 批量匹配（用于一次性处理多个标签）
  Map<String, EmojiModel?> matchBatch(List<String> tags) {
    final results = <String, EmojiModel?>{};
    for (final tag in tags) {
      results[tag] = match(tag);
    }
    return results;
  }

  /// 获取推荐表情包（基于分类或情绪）
  List<EmojiModel> getRecommendations({
    String? category,
    String? emotion,
    int limit = 10,
  }) {
    var emojis = _manager.getAllEmojis();

    // 按分类过滤
    if (category != null) {
      emojis = emojis.where((e) => e.category == category).toList();
    }

    // 按情绪过滤
    if (emotion != null) {
      emojis = emojis.where((e) => e.emotion == emotion).toList();
    }

    // 按使用频率排序
    emojis.sort((a, b) => b.usageCount.compareTo(a.usageCount));

    return emojis.take(limit).toList();
  }
}
