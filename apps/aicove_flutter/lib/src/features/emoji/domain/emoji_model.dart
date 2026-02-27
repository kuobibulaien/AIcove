/// 表情包模型
class EmojiModel {
  /// 表情包唯一ID
  final String id;

  /// 文件名（如 "hug_001.gif"）
  final String filename;

  /// 主要标签列表（用于精确匹配）
  final List<String> tags;

  /// 别名列表（用于扩展匹配）
  final List<String> aliases;

  /// 分类（如 "亲密", "生气", "开心"）
  final String category;

  /// 情绪标签（可选）
  final String? emotion;

  /// 优先级（用于多个匹配时选择，数值越大优先级越高）
  final int priority;

  /// 使用次数（用于热度排序）
  int usageCount;

  /// 来源：'local' | 'cloud' | 'user'
  final String source;

  /// 云端ID（如果是从云端下载的）
  final String? cloudId;

  /// 本地文件路径（运行时填充）
  String? localPath;

  EmojiModel({
    required this.id,
    required this.filename,
    required this.tags,
    this.aliases = const [],
    required this.category,
    this.emotion,
    this.priority = 0,
    this.usageCount = 0,
    this.source = 'local',
    this.cloudId,
    this.localPath,
  });

  /// 从JSON创建
  factory EmojiModel.fromJson(Map<String, dynamic> json) {
    return EmojiModel(
      id: json['id'] as String,
      filename: json['filename'] as String,
      tags: (json['tags'] as List<dynamic>).cast<String>(),
      aliases: (json['aliases'] as List<dynamic>?)?.cast<String>() ?? [],
      category: json['category'] as String,
      emotion: json['emotion'] as String?,
      priority: json['priority'] as int? ?? 0,
      usageCount: json['usageCount'] as int? ?? 0,
      source: json['source'] as String? ?? 'local',
      cloudId: json['cloudId'] as String?,
      localPath: json['localPath'] as String?,
    );
  }

  /// 转换为JSON
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'filename': filename,
      'tags': tags,
      'aliases': aliases,
      'category': category,
      'emotion': emotion,
      'priority': priority,
      'usageCount': usageCount,
      'source': source,
      'cloudId': cloudId,
      'localPath': localPath,
    };
  }

  /// 复制并更新字段
  EmojiModel copyWith({
    String? id,
    String? filename,
    List<String>? tags,
    List<String>? aliases,
    String? category,
    String? emotion,
    int? priority,
    int? usageCount,
    String? source,
    String? cloudId,
    String? localPath,
  }) {
    return EmojiModel(
      id: id ?? this.id,
      filename: filename ?? this.filename,
      tags: tags ?? this.tags,
      aliases: aliases ?? this.aliases,
      category: category ?? this.category,
      emotion: emotion ?? this.emotion,
      priority: priority ?? this.priority,
      usageCount: usageCount ?? this.usageCount,
      source: source ?? this.source,
      cloudId: cloudId ?? this.cloudId,
      localPath: localPath ?? this.localPath,
    );
  }

  /// 获取所有可匹配的文本（tags + aliases）
  List<String> get allMatchableTexts => [...tags, ...aliases];

  /// 增加使用次数
  void incrementUsage() {
    usageCount++;
  }
}

/// 语义分组（用于语义匹配）
class SemanticGroup {
  final String name;
  final List<String> keywords;

  const SemanticGroup({
    required this.name,
    required this.keywords,
  });

  factory SemanticGroup.fromJson(Map<String, dynamic> json) {
    return SemanticGroup(
      name: json['name'] as String,
      keywords: (json['keywords'] as List<dynamic>).cast<String>(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'keywords': keywords,
    };
  }
}

/// 表情包数据库模型
class EmojiDatabase {
  final List<EmojiModel> emojis;
  final List<SemanticGroup> semanticGroups;

  const EmojiDatabase({
    required this.emojis,
    this.semanticGroups = const [],
  });

  factory EmojiDatabase.fromJson(Map<String, dynamic> json) {
    return EmojiDatabase(
      emojis: (json['emojis'] as List<dynamic>)
          .map((e) => EmojiModel.fromJson(e as Map<String, dynamic>))
          .toList(),
      semanticGroups: (json['semanticGroups'] as List<dynamic>?)
              ?.map((e) => SemanticGroup.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'emojis': emojis.map((e) => e.toJson()).toList(),
      'semanticGroups': semanticGroups.map((e) => e.toJson()).toList(),
    };
  }
}
