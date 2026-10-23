import 'dart:math';

/// 表情包注册表 - AI 发送表情包时的标签索引
///
/// 1. AI 用 `<sticker tag="标签"/>` 标记表情包（语义标签，见 sticker_tag.dart）
/// 2. 同一标签可对应多个表情包（随机发送）
/// 3. 同义词自动归一化（如 "睡觉" → "晚安" 组）
///
/// 注册表只收「已启用套组」里的表情；套组与图片由 [StickerLibrary] 管理，
/// 库变化后调用 [replaceStickers] 重建索引。启动时默认只有内置表情。

/// 表情包数据模型
class Sticker {
  /// 表情包唯一ID
  final String id;

  /// 所属套组 id
  final String packId;

  /// 图片位置：本机文件绝对路径
  final String path;

  /// 标签列表（AI匹配索引，每个标签都可触发此表情包）
  final List<String> tags;

  /// 描述（用于 UI 显示）
  final String description;

  const Sticker({
    required this.id,
    required this.packId,
    required this.path,
    required this.tags,
    this.description = '',
  });
}

/// 同义词组 - 同组内的标签视为等价
/// AI 输出任一词都会匹配到该组的所有表情包
const List<List<String>> _synonymGroups = [
  // 问候类
  ['晚安', '睡觉', '好梦', '安安', '困了', '睡了', '休息'],
  ['早安', '早上好', '早', '起床', '新的一天'],
  ['再见', '拜拜', '回头见', '告辞', '下次见'],

  // 情绪类
  ['开心', '高兴', '快乐', '好开心', '哈哈', '嘻嘻', '太棒了', '好耶'],
  ['难过', '伤心', '哭', '呜呜', '委屈', '想哭', '心痛'],
  ['生气', '气死了', '哼', '讨厌', '不理你', '烦'],
  ['震惊', '天哪', '什么', '惊讶', '不会吧', '我的天'],

  // 动作类
  ['抱抱', '拥抱', '贴贴', '蹭蹭', '求抱'],
  ['谢谢', '感谢', '多谢', '谢啦', '感恩'],
  ['赞', '好的', 'ok', '可以', '行', '没问题', '同意'],
  ['收到', '了解', '明白', '知道了', '遵命', '好嘞'],
  ['加油', '冲', '干', '走起', '搞起', '出发'],

  // 状态类
  ['饿了', '好饿', '想吃', '馋', '好吃'],
  ['累了', '休息', '歇歇', '打盹', '困'],
  ['摸鱼', '偷懒', '划水', '躺平', '放松'],
  ['忙', '在忙', '稍等', '等一下', '马上'],
];

/// 表情包注册表（单例）
class StickerRegistry {
  StickerRegistry._() {
    // 1. 构建同义词映射（每组取第一个为标准形式）
    for (final group in _synonymGroups) {
      if (group.isEmpty) continue;
      final canonical = group.first.toLowerCase();
      for (final word in group) {
        _synonymMap[word.toLowerCase()] = canonical;
      }
    }
    replaceStickers(const []);
  }
  static final StickerRegistry instance = StickerRegistry._();

  final _random = Random();

  List<Sticker> _stickers = const [];

  /// 标签 → 表情包列表 索引（归一化后的标签）
  final Map<String, List<Sticker>> _tagIndex = {};

  /// 标签 → 归一化标签 映射
  final Map<String, String> _synonymMap = {};

  /// 用新的表情集合重建索引（库加载、导入、编辑、启停套组后调用）
  void replaceStickers(List<Sticker> stickers) {
    _stickers = List.unmodifiable(stickers);
    _tagIndex.clear();
    for (final sticker in _stickers) {
      // 同一表情的多个同义标签只入索引一次
      final addedTags = <String>{};
      for (final tag in sticker.tags) {
        final normalizedTag = normalizeTag(tag);
        if (normalizedTag.isEmpty || !addedTags.add(normalizedTag)) continue;
        _tagIndex.putIfAbsent(normalizedTag, () => []).add(sticker);
      }
    }
  }

  /// 归一化标签（转小写 + 同义词替换）
  String normalizeTag(String tag) {
    final lower = tag.toLowerCase().trim();
    return _synonymMap[lower] ?? lower;
  }

  /// 当前可供 AI 发送的表情包
  List<Sticker> get stickers => _stickers;

  /// 获取所有标签（归一化后，去重）
  Set<String> get allTags => _tagIndex.keys.toSet();

  /// 当前有表情的套组 id（即已启用的套组）
  Set<String> get packIds => {for (final s in _stickers) s.packId};

  /// [packIds] 内表情的标签；null 表示全部套组
  Set<String> tagsIn(Set<String>? packIds) => packIds == null
      ? allTags
      : {
          for (final entry in _tagIndex.entries)
            if (entry.value.any((s) => packIds.contains(s.packId))) entry.key,
        };

  /// 根据ID获取表情包
  Sticker? getById(String id) {
    for (final sticker in _stickers) {
      if (sticker.id == id) return sticker;
    }
    return null;
  }

  /// 根据标签获取表情包（随机选一个），只在 [packIds] 内挑；null 表示全部套组
  /// 支持同义词自动匹配
  Sticker? getByTag(String tag, {Set<String>? packIds}) {
    final candidates = [
      for (final s in _tagIndex[normalizeTag(tag)] ?? const <Sticker>[])
        if (packIds == null || packIds.contains(s.packId)) s,
    ];
    if (candidates.isEmpty) return null;
    return candidates[_random.nextInt(candidates.length)];
  }

  /// 根据标签获取所有匹配的表情包
  List<Sticker> getAllByTag(String tag) => _tagIndex[normalizeTag(tag)] ?? [];

  /// 检查标签是否存在（支持同义词）
  bool hasTag(String tag) => _tagIndex.containsKey(normalizeTag(tag));

  /// 获取能命中指定标签的全部触发词（含归一化前的同义词写法）
  /// 例如 triggerWordsOf('晚安') → {晚安, 睡觉, 好梦, 安安, 困了, 睡了}
  Set<String> triggerWordsOf(String tag) {
    final normalizedTag = normalizeTag(tag);
    final words = <String>{normalizedTag};
    for (final entry in _synonymMap.entries) {
      if (entry.value == normalizedTag) words.add(entry.key);
    }
    return words;
  }
}
