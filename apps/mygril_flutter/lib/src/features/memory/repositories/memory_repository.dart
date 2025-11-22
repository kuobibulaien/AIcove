import 'dart:convert';
import 'dart:math';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import '../models/memory_entity.dart';

class MemoryRepository {
  static final MemoryRepository instance = MemoryRepository._();
  static Database? _database;

  MemoryRepository._();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final dbPath = await getApplicationDocumentsDirectory();
    final path = join(dbPath.path, 'mygril_memory.db');

    return await openDatabase(
      path,
      version: 1,
      onCreate: _onCreate,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE memories (
        id TEXT PRIMARY KEY,
        content TEXT NOT NULL,
        embedding TEXT NOT NULL,
        importance INTEGER DEFAULT 1,
        created_at INTEGER,
        last_accessed_at INTEGER,
        is_synced INTEGER DEFAULT 0
      )
    ''');
  }

  Future<void> addMemory(MemoryEntity memory) async {
    final db = await database;
    await db.insert(
      'memories',
      memory.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deleteMemory(String id) async {
    final db = await database;
    await db.delete(
      'memories',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<List<MemoryEntity>> getAllMemories() async {
    final db = await database;
    final maps = await db.query('memories', orderBy: 'created_at DESC');
    return maps.map((e) => MemoryEntity.fromMap(e)).toList();
  }

  /// Vector Search using Cosine Similarity (Dot Product if normalized)
  Future<List<MemoryEntity>> search(List<double> queryVector, {int limit = 5}) async {
    final allMemories = await getAllMemories();
    if (allMemories.isEmpty) return [];

    // Calculate scores
    final scored = allMemories.map((mem) {
      final score = _cosineSimilarity(queryVector, mem.embedding);
      return MapEntry(mem, score);
    }).toList();

    // Sort by score descending
    scored.sort((a, b) => b.value.compareTo(a.value));

    // Take top K
    return scored.take(limit).map((e) => e.key).toList();
  }

  double _cosineSimilarity(List<double> a, List<double> b) {
    if (a.length != b.length) return 0.0;
    
    double dotProduct = 0.0;
    double normA = 0.0;
    double normB = 0.0;

    for (int i = 0; i < a.length; i++) {
      dotProduct += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }

    if (normA == 0 || normB == 0) return 0.0;
    return dotProduct / (sqrt(normA) * sqrt(normB));
  }
}
