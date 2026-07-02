library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../../../../features/chat/domain/conversation.dart';

/// 角色编辑页持久快照。
///
/// 用于在进入角色信息页时，直接恢复上次已经准备好的表单内容，
/// 避免每次都重新走“轻壳 -> 正式内容”的装配流程。
class ContactEditSnapshot {
  const ContactEditSnapshot({
    required this.conversationId,
    required this.sourceUpdatedAtMs,
    required this.cachedAtMs,
    required this.displayName,
    this.avatarUrl,
    this.characterImage,
    this.chatBackgroundImage,
    this.selfAddress,
    this.addressUser,
    this.voiceFile,
    this.description,
    required this.personaPrompt,
    this.enabledPlugins,
  });

  final String conversationId;
  final int sourceUpdatedAtMs;
  final int cachedAtMs;
  final String displayName;
  final String? avatarUrl;
  final String? characterImage;
  final String? chatBackgroundImage;
  final String? selfAddress;
  final String? addressUser;
  final String? voiceFile;
  final String? description;
  final String personaPrompt;
  final List<String>? enabledPlugins;

  factory ContactEditSnapshot.fromConversation(Conversation conversation) {
    return ContactEditSnapshot(
      conversationId: conversation.id,
      sourceUpdatedAtMs: conversation.updatedAt.millisecondsSinceEpoch,
      cachedAtMs: DateTime.now().millisecondsSinceEpoch,
      displayName: conversation.displayName,
      avatarUrl: conversation.avatarUrl,
      characterImage: conversation.characterImage,
      chatBackgroundImage: conversation.chatBackgroundImage,
      selfAddress: conversation.selfAddress,
      addressUser: conversation.addressUser,
      voiceFile: conversation.voiceFile,
      description: conversation.description,
      personaPrompt: conversation.personaPrompt,
      enabledPlugins: conversation.enabledPlugins == null
          ? null
          : List<String>.from(conversation.enabledPlugins!),
    );
  }

  factory ContactEditSnapshot.fromJson(Map<String, dynamic> json) {
    final rawPlugins = json['enabledPlugins'];
    final plugins = rawPlugins is List
        ? rawPlugins
            .map((item) => item?.toString() ?? '')
            .where((item) => item.isNotEmpty)
            .toList()
        : null;

    return ContactEditSnapshot(
      conversationId: json['conversationId']?.toString() ?? '',
      sourceUpdatedAtMs: (json['sourceUpdatedAtMs'] as num?)?.toInt() ?? 0,
      cachedAtMs: (json['cachedAtMs'] as num?)?.toInt() ?? 0,
      displayName: json['displayName']?.toString() ?? '',
      avatarUrl: json['avatarUrl']?.toString(),
      characterImage: json['characterImage']?.toString(),
      chatBackgroundImage: json['chatBackgroundImage']?.toString(),
      selfAddress: json['selfAddress']?.toString(),
      addressUser: json['addressUser']?.toString(),
      voiceFile: json['voiceFile']?.toString(),
      description: json['description']?.toString(),
      personaPrompt: json['personaPrompt']?.toString() ?? '',
      enabledPlugins: plugins == null ? null : List<String>.unmodifiable(plugins),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'conversationId': conversationId,
      'sourceUpdatedAtMs': sourceUpdatedAtMs,
      'cachedAtMs': cachedAtMs,
      'displayName': displayName,
      'avatarUrl': avatarUrl,
      'characterImage': characterImage,
      'chatBackgroundImage': chatBackgroundImage,
      'selfAddress': selfAddress,
      'addressUser': addressUser,
      'voiceFile': voiceFile,
      'description': description,
      'personaPrompt': personaPrompt,
      'enabledPlugins': enabledPlugins,
    };
  }

  bool isFreshFor(Conversation conversation) {
    return conversation.id == conversationId &&
        sourceUpdatedAtMs >= conversation.updatedAt.millisecondsSinceEpoch;
  }
}

/// 角色编辑页本地持久快照缓存。
///
/// - 内存层：同一进程内重复打开时直接命中
/// - 文件层：退出/重启应用后仍保留
class ContactEditSnapshotStore {
  ContactEditSnapshotStore._();

  static const int _cacheVersion = 1;
  static const String _cacheDirName = 'contact_edit_snapshots';

  static final ContactEditSnapshotStore instance = ContactEditSnapshotStore._();

  Directory? _cacheDir;
  final Map<String, ContactEditSnapshot> _memoryCache = {};
  final Map<String, Future<ContactEditSnapshot?>> _inFlightReads = {};

  Future<ContactEditSnapshot?> read(String conversationId) async {
    final normalizedId = _normalizeConversationId(conversationId);
    if (normalizedId == null) return null;

    final cached = _memoryCache[normalizedId];
    if (cached != null) return cached;

    final inFlight = _inFlightReads[normalizedId];
    if (inFlight != null) return inFlight;

    final task = _readFromDisk(normalizedId);
    _inFlightReads[normalizedId] = task;
    try {
      final snapshot = await task;
      if (snapshot != null) {
        _memoryCache[normalizedId] = snapshot;
      }
      return snapshot;
    } finally {
      if (identical(_inFlightReads[normalizedId], task)) {
        _inFlightReads.remove(normalizedId);
      }
    }
  }

  Future<ContactEditSnapshot?> readFreshForConversation(
    Conversation conversation,
  ) async {
    final snapshot = await read(conversation.id);
    if (snapshot == null) return null;
    if (!snapshot.isFreshFor(conversation)) return null;
    return snapshot;
  }

  Future<ContactEditSnapshot> prepareFreshSnapshot(
    Conversation conversation,
  ) async {
    final cached = await readFreshForConversation(conversation);
    if (cached != null) return cached;

    final snapshot = ContactEditSnapshot.fromConversation(conversation);
    await write(snapshot);
    return snapshot;
  }

  Future<void> writeFromConversation(Conversation conversation) {
    return write(ContactEditSnapshot.fromConversation(conversation));
  }

  Future<void> write(ContactEditSnapshot snapshot) async {
    final normalizedId = _normalizeConversationId(snapshot.conversationId);
    if (normalizedId == null) return;

    final directory = await _getCacheDir();
    final file = File(_buildSnapshotPath(directory, normalizedId));
    await file.parent.create(recursive: true);

    final payload = jsonEncode(snapshot.toJson());
    final tempFile = File('${file.path}.tmp');
    await tempFile.writeAsString(payload, flush: true);
    if (await file.exists()) {
      await file.delete();
    }
    await tempFile.rename(file.path);

    _memoryCache[normalizedId] = snapshot;
  }

  Future<void> delete(String conversationId) async {
    final normalizedId = _normalizeConversationId(conversationId);
    if (normalizedId == null) return;

    _memoryCache.remove(normalizedId);

    final directory = await _getCacheDir();
    final file = File(_buildSnapshotPath(directory, normalizedId));
    if (await file.exists()) {
      await file.delete();
    }
  }

  Future<void> clearMemory() async {
    _memoryCache.clear();
    _inFlightReads.clear();
    _cacheDir = null;
  }

  Future<ContactEditSnapshot?> _readFromDisk(String normalizedId) async {
    try {
      final directory = await _getCacheDir();
      final file = File(_buildSnapshotPath(directory, normalizedId));
      if (!await file.exists()) return null;

      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return null;

      final parsed = jsonDecode(raw);
      if (parsed is! Map<String, dynamic>) return null;

      final snapshot = ContactEditSnapshot.fromJson(parsed);
      if (_normalizeConversationId(snapshot.conversationId) != normalizedId) {
        return null;
      }
      return snapshot;
    } catch (_) {
      return null;
    }
  }

  Future<Directory> _getCacheDir() async {
    if (_cacheDir != null) return _cacheDir!;
    final appDir = await getApplicationDocumentsDirectory();
    _cacheDir = Directory('${appDir.path}/$_cacheDirName');
    if (!await _cacheDir!.exists()) {
      await _cacheDir!.create(recursive: true);
    }
    return _cacheDir!;
  }

  String _buildSnapshotPath(Directory directory, String normalizedId) {
    final digest = md5.convert(utf8.encode(normalizedId)).toString();
    return '${directory.path}/v${_cacheVersion}_$digest.json';
  }

  String? _normalizeConversationId(String? value) {
    final normalized = value?.trim();
    if (normalized == null || normalized.isEmpty) return null;
    return normalized;
  }
}
