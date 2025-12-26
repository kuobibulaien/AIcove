import 'dart:math';

/// 表情包注册表 - 基于标签的表情包管理系统
/// 
/// 核心特性：
/// 1. AI 使用 [标签] 语法标记表情包
/// 2. 同一标签可对应多个表情包（随机发送）
/// 3. 同义词自动归一化（如 "睡觉" → "晚安" 组）
/// 
/// 添加新表情包：
/// 1. 将图片放入 assets/stickers/
/// 2. 在 _stickers 中添加配置（指定 tags）
/// 3. 如有新同义词，更新 _synonymGroups

/// 表情包数据模型
class Sticker {
  /// 表情包唯一ID
  final String id;
  
  /// 资源路径（格式：assets/stickers/{文件夹}/{图片}.png）
  final String assetPath;
  
  /// 标签列表（AI匹配索引，每个标签都可触发此表情包）
  final List<String> tags;
  
  /// 描述（用于 UI 显示）
  final String description;

  const Sticker({
    required this.id,
    required this.assetPath,
    required this.tags,
    this.description = '',
  });
  
  /// 从资源路径提取文件夹名（物理存储分组）
  String get folder {
    // 路径格式：assets/stickers/{folder}/{filename}.png
    final parts = assetPath.split('/');
    if (parts.length >= 3) {
      return parts[parts.length - 2]; // 倒数第二段是文件夹名
    }
    return '默认';
  }
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
    _buildIndex();
  }
  static final StickerRegistry instance = StickerRegistry._();
  
  final _random = Random();
  
  /// 标签 → 表情包列表 索引（归一化后的标签）
  final Map<String, List<Sticker>> _tagIndex = {};
  
  /// 文件夹/套组 → 表情包列表 索引
  final Map<String, List<Sticker>> _folderIndex = {};
  
  /// 标签 → 归一化标签 映射
  final Map<String, String> _synonymMap = {};
  
  /// 构建索引
  void _buildIndex() {
    // 1. 构建同义词映射（每组取第一个为标准形式）
    for (final group in _synonymGroups) {
      if (group.isEmpty) continue;
      final canonical = group.first; // 标准形式
      for (final word in group) {
        _synonymMap[word.toLowerCase()] = canonical.toLowerCase();
      }
    }
    
    // 2. 构建标签索引（使用 Set 避免同一表情包因多个同义标签被重复添加）
    for (final sticker in _stickers) {
      final addedTags = <String>{}; // 记录该表情包已添加到哪些归一化标签
      for (final tag in sticker.tags) {
        final normalizedTag = _normalizeTag(tag);
        // 只有该表情包尚未添加到此归一化标签时才添加
        if (!addedTags.contains(normalizedTag)) {
          addedTags.add(normalizedTag);
          _tagIndex.putIfAbsent(normalizedTag, () => []).add(sticker);
        }
      }
      
      // 3. 构建文件夹索引
      _folderIndex.putIfAbsent(sticker.folder, () => []).add(sticker);
    }
  }
  
  /// 归一化标签（转小写 + 同义词替换）
  String _normalizeTag(String tag) {
    final lower = tag.toLowerCase().trim();
    return _synonymMap[lower] ?? lower;
  }
  
  /// 所有已注册的表情包
  List<Sticker> get stickers => _stickers;
  
  /// 获取所有标签（归一化后，去重）
  Set<String> get allTags => _tagIndex.keys.toSet();
  
  /// 按标签分组获取表情包
  Map<String, List<Sticker>> get stickersByTag => Map.unmodifiable(_tagIndex);
  
  /// 按文件夹/套组分组获取表情包
  Map<String, List<Sticker>> get stickersByFolder => Map.unmodifiable(_folderIndex);
  
  /// 获取所有文件夹/套组名称
  Set<String> get allFolders => _folderIndex.keys.toSet();
  
  /// 根据ID获取表情包
  Sticker? getById(String id) {
    try {
      return _stickers.firstWhere((s) => s.id == id);
    } catch (_) {
      return null;
    }
  }
  
  /// 根据标签获取表情包（随机选一个）
  /// 支持同义词自动匹配
  Sticker? getByTag(String tag) {
    final normalizedTag = _normalizeTag(tag);
    final candidates = _tagIndex[normalizedTag];
    if (candidates == null || candidates.isEmpty) return null;
    
    // 随机选择一个
    return candidates[_random.nextInt(candidates.length)];
  }
  
  /// 根据标签获取所有匹配的表情包
  List<Sticker> getAllByTag(String tag) {
    final normalizedTag = _normalizeTag(tag);
    return _tagIndex[normalizedTag] ?? [];
  }
  
  /// 检查标签是否存在（支持同义词）
  bool hasTag(String tag) {
    final normalizedTag = _normalizeTag(tag);
    return _tagIndex.containsKey(normalizedTag);
  }
}

/// 表情包数据配置
/// 
/// 资源路径格式：assets/stickers/{文件夹}/{图片}.png
/// - 文件夹 = 物理存储分组（如 nahida、miku 等）
/// - 标签 = AI匹配索引（同义词自动归一化）
/// 
/// 添加新表情包组：
/// 1. 创建文件夹 assets/stickers/{新文件夹名}/
/// 2. 放入图片文件
/// 3. 在此处添加配置（路径指向新文件夹）
/// 4. 如有新同义词，更新 _synonymGroups
const List<Sticker> _stickers = [
  // ============================================================
  // nahida - 纳西妲表情包
  // ============================================================
  Sticker(
    id: 'nahida_happy_smile',
    assetPath: 'assets/stickers/nahida/happy_smile.png',
    tags: ['开心', '高兴', '快乐'],
    description: '开心微笑',
  ),
  Sticker(
    id: 'nahida_sad_cry',
    assetPath: 'assets/stickers/nahida/sad_cry.png',
    tags: ['难过', '伤心', '哭'],
    description: '伤心哭泣',
  ),
  Sticker(
    id: 'nahida_angry_pout',
    assetPath: 'assets/stickers/nahida/angry_pout.png',
    tags: ['生气', '哼', '讨厌'],
    description: '生气嘟嘴',
  ),
  Sticker(
    id: 'nahida_shocked_gasp',
    assetPath: 'assets/stickers/nahida/shocked_gasp.png',
    tags: ['震惊', '惊讶'],
    description: '震惊惊讶',
  ),
  Sticker(
    id: 'nahida_yay_cheer',
    assetPath: 'assets/stickers/nahida/yay_cheer.png',
    tags: ['开心', '太棒了', '耶'],
    description: '欢呼庆祝',
  ),
  Sticker(
    id: 'nahida_good_morning_wave',
    assetPath: 'assets/stickers/nahida/good_morning_wave.png',
    tags: ['早安', '早上好'],
    description: '早安招手',
  ),
  Sticker(
    id: 'nahida_good_night_sleep',
    assetPath: 'assets/stickers/nahida/good_night_sleep.png',
    tags: ['晚安', '睡觉', '好梦'],
    description: '晚安睡觉',
  ),
  Sticker(
    id: 'nahida_bye_bye_wave',
    assetPath: 'assets/stickers/nahida/bye_bye_wave.png',
    tags: ['再见', '拜拜'],
    description: '挥手告别',
  ),
  Sticker(
    id: 'nahida_see_you_tomorrow',
    assetPath: 'assets/stickers/nahida/see_you_tomorrow.png',
    tags: ['明天见'],
    description: '明天见',
  ),
  Sticker(
    id: 'nahida_im_here_arrival',
    assetPath: 'assets/stickers/nahida/im_here_arrival.png',
    tags: ['来了', '到了'],
    description: '到达现身',
  ),
  Sticker(
    id: 'nahida_hug_request',
    assetPath: 'assets/stickers/nahida/hug_request.png',
    tags: ['抱抱', '贴贴'],
    description: '求抱抱',
  ),
  Sticker(
    id: 'nahida_thanks_prayer',
    assetPath: 'assets/stickers/nahida/thanks_prayer.png',
    tags: ['谢谢', '感谢'],
    description: '感谢祈祷',
  ),
  Sticker(
    id: 'nahida_thumbs_up_like',
    assetPath: 'assets/stickers/nahida/thumbs_up_like.png',
    tags: ['赞', '好的', 'ok'],
    description: '点赞认可',
  ),
  Sticker(
    id: 'nahida_received_salute',
    assetPath: 'assets/stickers/nahida/received_salute.png',
    tags: ['收到', '了解'],
    description: '收到敬礼',
  ),
  Sticker(
    id: 'nahida_lets_go_start',
    assetPath: 'assets/stickers/nahida/lets_go_start.png',
    tags: ['加油', '冲', '出发'],
    description: '出发开始',
  ),
  Sticker(
    id: 'nahida_curious_hmm',
    assetPath: 'assets/stickers/nahida/curious_hmm.png',
    tags: ['嗯', '思考'],
    description: '好奇思考',
  ),
  Sticker(
    id: 'nahida_question_confused',
    assetPath: 'assets/stickers/nahida/question_confused.png',
    tags: ['疑惑', '不懂'],
    description: '疑惑不解',
  ),
  Sticker(
    id: 'nahida_hungry_drool',
    assetPath: 'assets/stickers/nahida/hungry_drool.png',
    tags: ['饿了', '想吃', '馋'],
    description: '饥饿流口水',
  ),
  Sticker(
    id: 'nahida_resting_nap',
    assetPath: 'assets/stickers/nahida/resting_nap.png',
    tags: ['累了', '休息'],
    description: '休息小憩',
  ),
  Sticker(
    id: 'nahida_slacking_fish',
    assetPath: 'assets/stickers/nahida/slacking_fish.png',
    tags: ['摸鱼', '偷懒', '躺平'],
    description: '摸鱼偷懒',
  ),
  Sticker(
    id: 'nahida_busy_peeking',
    assetPath: 'assets/stickers/nahida/busy_peeking.png',
    tags: ['忙', '稍等'],
    description: '忙碌偷看',
  ),
  Sticker(
    id: 'nahida_bush_peek',
    assetPath: 'assets/stickers/nahida/bush_peek.png',
    tags: ['偷看', '悄悄'],
    description: '草丛偷看',
  ),
  Sticker(
    id: 'nahida_dendro_reaction',
    assetPath: 'assets/stickers/nahida/dendro_reaction.png',
    tags: ['原神', '草元素'],
    description: '草元素反应',
  ),
  Sticker(
    id: 'nahida_wisdom_glow',
    assetPath: 'assets/stickers/nahida/wisdom_glow.png',
    tags: ['智慧', '懂了', '原来如此'],
    description: '智慧发光',
  ),
];
