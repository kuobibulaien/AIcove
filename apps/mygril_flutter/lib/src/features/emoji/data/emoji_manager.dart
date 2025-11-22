import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import '../domain/emoji_model.dart';

/// 表情包管理器
/// 负责表情包的加载、保存、查询等操作
class EmojiManager {
  /// 单例
  static final EmojiManager _instance = EmojiManager._internal();
  factory EmojiManager() => _instance;
  EmojiManager._internal();

  /// 表情包数据库
  EmojiDatabase? _database;

  /// 表情包目录路径
  String? _emojiDir;

  /// 是否已初始化
  bool _initialized = false;

  /// 初始化表情包管理器
  Future<void> initialize() async {
    if (_initialized) return;

    try {
      // 1. 获取应用文档目录
      final appDir = await getApplicationDocumentsDirectory();
      _emojiDir = '${appDir.path}/emojis';

      // 2. 确保目录存在
      final dir = Directory(_emojiDir!);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      // 3. 加载表情包数据库
      await _loadDatabase();

      _initialized = true;
      print('[EmojiManager] 初始化完成，共加载 ${_database?.emojis.length ?? 0} 个表情包');
    } catch (e) {
      print('[EmojiManager] 初始化失败: $e');
      rethrow;
    }
  }

  /// 加载表情包数据库
  Future<void> _loadDatabase() async {
    try {
      // 1. 尝试从本地文件加载
      final dbFile = File('$_emojiDir/emoji_database.json');
      
      if (await dbFile.exists()) {
        final jsonStr = await dbFile.readAsString();
        final json = jsonDecode(jsonStr) as Map<String, dynamic>;
        _database = EmojiDatabase.fromJson(json);
      } else {
        // 2. 首次运行，从 assets 加载默认数据库
        await _loadDefaultDatabase();
      }

      // 3. 填充本地路径
      _fillLocalPaths();
    } catch (e) {
      print('[EmojiManager] 加载数据库失败: $e');
      // 加载失败，使用空数据库
      _database = const EmojiDatabase(emojis: []);
    }
  }

  /// 从 assets 加载默认数据库
  Future<void> _loadDefaultDatabase() async {
    try {
      final jsonStr = await rootBundle.loadString('assets/emoji/emoji_database.json');
      final json = jsonDecode(jsonStr) as Map<String, dynamic>;
      _database = EmojiDatabase.fromJson(json);

      // 复制默认表情包到本地目录
      await _copyDefaultEmojis();

      // 保存到本地
      await _saveDatabase();
    } catch (e) {
      print('[EmojiManager] 加载默认数据库失败: $e');
      _database = const EmojiDatabase(emojis: []);
    }
  }

  /// 复制默认表情包到本地目录
  Future<void> _copyDefaultEmojis() async {
    if (_database == null) return;

    for (final emoji in _database!.emojis) {
      try {
        // 从 assets 读取
        final data = await rootBundle.load('assets/emoji/${emoji.filename}');
        
        // 写入本地
        final localFile = File('$_emojiDir/${emoji.filename}');
        await localFile.writeAsBytes(data.buffer.asUint8List());
      } catch (e) {
        print('[EmojiManager] 复制表情包失败 ${emoji.filename}: $e');
      }
    }
  }

  /// 填充表情包的本地路径
  void _fillLocalPaths() {
    if (_database == null || _emojiDir == null) return;

    for (final emoji in _database!.emojis) {
      emoji.localPath = '$_emojiDir/${emoji.filename}';
    }
  }

  /// 保存数据库到本地
  Future<void> _saveDatabase() async {
    if (_database == null || _emojiDir == null) return;

    try {
      final dbFile = File('$_emojiDir/emoji_database.json');
      final jsonStr = jsonEncode(_database!.toJson());
      await dbFile.writeAsString(jsonStr);
    } catch (e) {
      print('[EmojiManager] 保存数据库失败: $e');
    }
  }

  /// 获取所有表情包
  List<EmojiModel> getAllEmojis() {
    return _database?.emojis ?? [];
  }

  /// 根据ID获取表情包
  EmojiModel? getEmojiById(String id) {
    if (_database == null) return null;
    
    try {
      return _database!.emojis.firstWhere((e) => e.id == id);
    } catch (e) {
      return null;
    }
  }

  /// 获取指定分类的表情包
  List<EmojiModel> getEmojisByCategory(String category) {
    return _database?.emojis.where((e) => e.category == category).toList() ?? [];
  }

  /// 获取所有分类
  List<String> getAllCategories() {
    if (_database == null) return [];
    
    final categories = <String>{};
    for (final emoji in _database!.emojis) {
      categories.add(emoji.category);
    }
    return categories.toList()..sort();
  }

  /// 获取语义分组
  List<SemanticGroup> getSemanticGroups() {
    return _database?.semanticGroups ?? [];
  }

  /// 增加表情包使用次数
  Future<void> incrementUsage(String emojiId) async {
    final emoji = getEmojiById(emojiId);
    if (emoji != null) {
      emoji.incrementUsage();
      await _saveDatabase();
    }
  }

  /// 添加表情包（用户导入）
  Future<bool> addEmoji(EmojiModel emoji, File imageFile) async {
    if (_database == null || _emojiDir == null) return false;

    try {
      // 1. 复制图片到本地
      final localFile = File('$_emojiDir/${emoji.filename}');
      await imageFile.copy(localFile.path);

      // 2. 更新路径
      final newEmoji = emoji.copyWith(localPath: localFile.path);

      // 3. 添加到数据库
      _database = EmojiDatabase(
        emojis: [..._database!.emojis, newEmoji],
        semanticGroups: _database!.semanticGroups,
      );

      // 4. 保存
      await _saveDatabase();

      print('[EmojiManager] 添加表情包成功: ${emoji.id}');
      return true;
    } catch (e) {
      print('[EmojiManager] 添加表情包失败: $e');
      return false;
    }
  }

  /// 删除表情包
  Future<bool> deleteEmoji(String emojiId) async {
    if (_database == null) return false;

    try {
      final emoji = getEmojiById(emojiId);
      if (emoji == null) return false;

      // 1. 删除本地文件
      if (emoji.localPath != null) {
        final file = File(emoji.localPath!);
        if (await file.exists()) {
          await file.delete();
        }
      }

      // 2. 从数据库移除
      _database = EmojiDatabase(
        emojis: _database!.emojis.where((e) => e.id != emojiId).toList(),
        semanticGroups: _database!.semanticGroups,
      );

      // 3. 保存
      await _saveDatabase();

      print('[EmojiManager] 删除表情包成功: $emojiId');
      return true;
    } catch (e) {
      print('[EmojiManager] 删除表情包失败: $e');
      return false;
    }
  }

  /// 更新表情包标签
  Future<bool> updateEmojiTags(String emojiId, List<String> tags, List<String> aliases) async {
    if (_database == null) return false;

    try {
      final index = _database!.emojis.indexWhere((e) => e.id == emojiId);
      if (index == -1) return false;

      final updatedEmoji = _database!.emojis[index].copyWith(
        tags: tags,
        aliases: aliases,
      );

      final updatedEmojis = [..._database!.emojis];
      updatedEmojis[index] = updatedEmoji;

      _database = EmojiDatabase(
        emojis: updatedEmojis,
        semanticGroups: _database!.semanticGroups,
      );

      await _saveDatabase();

      print('[EmojiManager] 更新表情包标签成功: $emojiId');
      return true;
    } catch (e) {
      print('[EmojiManager] 更新表情包标签失败: $e');
      return false;
    }
  }

  /// 搜索表情包（按名称）
  List<EmojiModel> searchEmojis(String query) {
    if (_database == null || query.isEmpty) return [];

    final lowerQuery = query.toLowerCase();
    return _database!.emojis.where((emoji) {
      // 搜索标签和别名
      return emoji.tags.any((tag) => tag.toLowerCase().contains(lowerQuery)) ||
          emoji.aliases.any((alias) => alias.toLowerCase().contains(lowerQuery)) ||
          emoji.category.toLowerCase().contains(lowerQuery);
    }).toList();
  }

  /// 获取热门表情包（按使用次数排序）
  List<EmojiModel> getPopularEmojis({int limit = 10}) {
    if (_database == null) return [];

    final sorted = [..._database!.emojis]
      ..sort((a, b) => b.usageCount.compareTo(a.usageCount));
    
    return sorted.take(limit).toList();
  }

  /// 清理缓存（用于测试）
  Future<void> clearCache() async {
    if (_emojiDir == null) return;

    try {
      final dir = Directory(_emojiDir!);
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
      _database = null;
      _initialized = false;
      print('[EmojiManager] 缓存已清理');
    } catch (e) {
      print('[EmojiManager] 清理缓存失败: $e');
    }
  }
}
