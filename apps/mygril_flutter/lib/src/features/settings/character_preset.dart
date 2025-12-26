/// 角色预设数据模型
class CharacterPreset {
  final String id;
  final String name; // 预设名称
  final String displayName; // 角色名称
  final String? avatarUrl;
  final String? characterImage;
  final String? addressUser; // 角色对"我"的称呼
  final String personaPrompt;
  final DateTime createdAt;

  const CharacterPreset({
    required this.id,
    required this.name,
    required this.displayName,
    this.avatarUrl,
    this.characterImage,
    this.addressUser,
    required this.personaPrompt,
    required this.createdAt,
  });

  factory CharacterPreset.fromJson(Map<String, dynamic> json) {
    return CharacterPreset(
      id: json['id'] as String,
      name: json['name'] as String,
      displayName: json['displayName'] as String,
      avatarUrl: json['avatarUrl'] as String?,
      characterImage: json['characterImage'] as String?,
      addressUser: json['addressUser'] as String?,
      personaPrompt: (json['personaPrompt'] as String?) ?? '',
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'displayName': displayName,
      'avatarUrl': avatarUrl,
      'characterImage': characterImage,
      'addressUser': addressUser,
      'personaPrompt': personaPrompt,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  CharacterPreset copyWith({
    String? id,
    String? name,
    String? displayName,
    String? avatarUrl,
    String? characterImage,
    String? addressUser,
    String? personaPrompt,
    DateTime? createdAt,
  }) {
    return CharacterPreset(
      id: id ?? this.id,
      name: name ?? this.name,
      displayName: displayName ?? this.displayName,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      characterImage: characterImage ?? this.characterImage,
      addressUser: addressUser ?? this.addressUser,
      personaPrompt: personaPrompt ?? this.personaPrompt,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}
