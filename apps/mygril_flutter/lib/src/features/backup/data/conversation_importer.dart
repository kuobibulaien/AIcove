import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/export_format.dart';
import '../../../core/database/database.dart';
import '../../../core/database/repositories/repositories.dart';
import '../../chat/id_gen.dart';

/// 会话导入服务
class ConversationImporter {
  final ConversationRepository _convRepo;
  final MessageRepository _msgRepo;
  final MessageBlockRepository _blockRepo;

  ConversationImporter({
    required ConversationRepository convRepo,
    required MessageRepository msgRepo,
    required MessageBlockRepository blockRepo,
  })  : _convRepo = convRepo,
        _msgRepo = msgRepo,
        _blockRepo = blockRepo;

  /// 注释已清理乱码
  Future<ImportPreview> preview(File file) async {
    final importDir = await _extractToTempDir(file);

    try {
      // 读取 manifest
      final manifestFile = File(p.join(importDir.path, 'manifest.json'));
      if (!await manifestFile.exists()) {
        throw ImportException('无效的导入文件：缺少 manifest.json');
      }

      final manifestJson = jsonDecode(await manifestFile.readAsString());
      final manifest = ExportManifest.fromJson(manifestJson);

      // 注释已清理乱码
      final isCompatible = manifest.formatVersion <= kExportFormatVersion;
      String? incompatibleReason;
      if (!isCompatible) {
        incompatibleReason = '文件版本过新（v${manifest.formatVersion}），请更新 App';
      }

      // 读取 conversations
      final conversationsFile =
          File(p.join(importDir.path, 'conversations.json'));
      if (!await conversationsFile.exists()) {
        throw ImportException('无效的导入文件：缺少 conversations.json');
      }

      final conversationsJson =
          jsonDecode(await conversationsFile.readAsString());
      final convList = conversationsJson['conversations'] as List<dynamic>;

      // 读取 messages 统计
      final messagesFile = File(p.join(importDir.path, 'messages.json'));
      Map<String, int> messageCountByConv = {};
      Map<String, int> imageCountByConv = {};
      Map<String, int> audioCountByConv = {};
      Map<String, int?> lastMessageTimeByConv = {};

      if (await messagesFile.exists()) {
        final messagesJson = jsonDecode(await messagesFile.readAsString());
        final msgList = messagesJson['messages'] as List<dynamic>;

        for (final msg in msgList) {
          final convId = msg['conversation_id'] as String;
          messageCountByConv[convId] = (messageCountByConv[convId] ?? 0) + 1;

          // 注释已清理乱码
          final createdAt = msg['created_at'] as int?;
          if (createdAt != null) {
            final current = lastMessageTimeByConv[convId];
            if (current == null || createdAt > current) {
              lastMessageTimeByConv[convId] = createdAt;
            }
          }

          // 统计媒体文件
          final blocks = msg['blocks'] as List<dynamic>?;
          if (blocks != null) {
            for (final block in blocks) {
              final type = block['type'] as String?;
              if (type == 'image') {
                imageCountByConv[convId] = (imageCountByConv[convId] ?? 0) + 1;
              } else if (type == 'audio') {
                audioCountByConv[convId] = (audioCountByConv[convId] ?? 0) + 1;
              }
            }
          }
        }
      }

      // 注释已清理乱码
      final conversations = convList.map((conv) {
        final id = conv['id'] as String;
        final lastTime = lastMessageTimeByConv[id];
        return ConversationPreview(
          id: id,
          displayName: conv['display_name'] as String? ??
              conv['title'] as String? ??
              '未知',
          avatarPath: conv['avatar_file'] as String?,
          messageCount: messageCountByConv[id] ?? 0,
          imageCount: imageCountByConv[id] ?? 0,
          audioCount: audioCountByConv[id] ?? 0,
          lastMessageTime: lastTime != null
              ? DateTime.fromMillisecondsSinceEpoch(lastTime)
              : null,
        );
      }).toList();

      return ImportPreview(
        formatVersion: manifest.formatVersion,
        appVersion: manifest.appVersion,
        exportTime: manifest.exportTime,
        exportDevice: manifest.exportDevice,
        conversations: conversations,
        includedScopes: manifest.includedScopes,
        isCompatible: isCompatible,
        incompatibleReason: incompatibleReason,
      );
    } finally {
      // 清理临时目录
      await importDir.delete(recursive: true);
    }
  }

  /// 执行导入
  Future<ImportResult> import({
    required File file,
    required List<String> selectedScopes,
    required List<String> selectedConversationIds,
    Map<String, ImportConflictResolution> conflictResolutions = const {},
    void Function(ImportProgress)? onProgress,
  }) async {
    onProgress?.call(const ImportProgress(
      ImportPhase.extracting,
      0.0,
      message: '解压文件...',
    ));

    final importDir = await _extractToTempDir(file);

    try {
      // 注释已清理乱码
      onProgress?.call(const ImportProgress(
        ImportPhase.validating,
        0.1,
        message: '验证文件格式...',
      ));

      final manifestFile = File(p.join(importDir.path, 'manifest.json'));
      if (!await manifestFile.exists()) {
        throw ImportException('Invalid import file');
      }

      final manifestJson = jsonDecode(await manifestFile.readAsString());
      final manifest = ExportManifest.fromJson(manifestJson);

      if (manifest.formatVersion > kExportFormatVersion) {
        throw ImportException('文件版本过新，请更新 App');
      }

      // 读取数据
      final conversationsJson = jsonDecode(
        await File(p.join(importDir.path, 'conversations.json')).readAsString(),
      );
      final messagesJson = jsonDecode(
        await File(p.join(importDir.path, 'messages.json')).readAsString(),
      );

      final convList = conversationsJson['conversations'] as List<dynamic>;
      final msgList = messagesJson['messages'] as List<dynamic>;

      // 注释已清理乱码
      final selectedConvs = convList
          .where((c) => selectedConversationIds.contains(c['id']))
          .toList();

      // 获取应用数据目录
      final appDir = await getApplicationDocumentsDirectory();
      final filesDir = Directory(p.join(appDir.path, 'imported_files'));
      await filesDir.create(recursive: true);

      // 注释已清理乱码
      onProgress?.call(const ImportProgress(
        ImportPhase.importing,
        0.2,
        message: '检查冲突...',
      ));

      final conflicts = <ImportConflict>[];
      final existingConvIds = <String>{};

      for (final conv in selectedConvs) {
        final convId = conv['id'] as String;
        final existing = await _convRepo.getById(convId);
        if (existing != null) {
          existingConvIds.add(convId);
          final resolution = conflictResolutions[convId];
          conflicts.add(ImportConflict(
            type: 'conversation',
            id: convId,
            name: conv['display_name'] as String? ?? '未知',
            resolution: resolution,
          ));
        }
      }

      // 如果有未解决的冲突，返回等待用户处理
      final unresolvedConflicts =
          conflicts.where((c) => c.resolution == null).toList();
      if (unresolvedConflicts.isNotEmpty) {
        return ImportResult(
          conversationIds: [],
          messagesImported: 0,
          filesImported: 0,
          conflicts: unresolvedConflicts,
        );
      }

      // 导入数据
      final importedConvIds = <String>[];
      int messagesImported = 0;
      int filesImported = 0;
      int skipped = 0;

      for (var i = 0; i < selectedConvs.length; i++) {
        final conv = selectedConvs[i];
        final originalId = conv['id'] as String;
        final progress = 0.3 + (0.5 * i / selectedConvs.length);

        onProgress?.call(ImportProgress(
          ImportPhase.importing,
          progress,
          currentItem: conv['display_name'] as String?,
          message: '导入中 ${conv['display_name']}...',
        ));

        // 注释已清理乱码
        String newConvId;
        final resolution = conflictResolutions[originalId];

        if (existingConvIds.contains(originalId)) {
          switch (resolution) {
            case ImportConflictResolution.skip:
              skipped++;
              continue;
            case ImportConflictResolution.createNew:
              newConvId = genId('conv');
              break;
            case ImportConflictResolution.merge:
            case ImportConflictResolution.replace:
              newConvId = originalId;
              if (resolution == ImportConflictResolution.replace) {
                // 注释已清理乱码
                await _msgRepo.deleteByConversation(originalId);
              }
              break;
            default:
              continue;
          }
        } else {
          newConvId = originalId;
        }

        // 复制文件
        final fileMapping = <String, String>{};

        // 复制头像
        final avatarFile = conv['avatar_file'] as String?;
        if (avatarFile != null) {
          final newPath = await _copyImportedFile(
            importDir,
            avatarFile,
            filesDir,
            'avatar_$newConvId',
          );
          if (newPath != null) {
            fileMapping[avatarFile] = newPath;
            filesImported++;
          }
        }

        // 复制立绘
        final characterFile = conv['character_image_file'] as String?;
        if (characterFile != null) {
          final newPath = await _copyImportedFile(
            importDir,
            characterFile,
            filesDir,
            'character_$newConvId',
          );
          if (newPath != null) {
            fileMapping[characterFile] = newPath;
            filesImported++;
          }
        }

        // copy chat background
        final chatBackgroundFile =
            conv['chat_background_image_file'] as String?;
        if (chatBackgroundFile != null &&
            chatBackgroundFile.startsWith('files/')) {
          final newPath = await _copyImportedFile(
            importDir,
            chatBackgroundFile,
            filesDir,
            'chat_bg_$newConvId',
          );
          if (newPath != null) {
            fileMapping[chatBackgroundFile] = newPath;
            filesImported++;
          }
        }

        // 导入会话
        if (!existingConvIds.contains(originalId) ||
            resolution == ImportConflictResolution.createNew) {
          await _importConversation(conv, newConvId, fileMapping);
        }
        importedConvIds.add(newConvId);

        // 导入消息
        final convMessages =
            msgList.where((m) => m['conversation_id'] == originalId).toList();

        // 获取已有消息 ID（用于合并模式去重）
        Set<String> existingMsgIds = {};
        if (resolution == ImportConflictResolution.merge) {
          final existingMsgs = await _msgRepo.getByConversation(newConvId);
          existingMsgIds = existingMsgs.map((m) => m.id).toSet();
        }

        for (final msg in convMessages) {
          final msgId = msg['id'] as String;

          // 合并模式跳过已存在的消息
          if (resolution == ImportConflictResolution.merge &&
              existingMsgIds.contains(msgId)) {
            skipped++;
            continue;
          }

          // 复制消息中的文件
          final blocks = msg['blocks'] as List<dynamic>?;
          if (blocks != null) {
            for (final block in blocks) {
              final data = block['data'] as Map<String, dynamic>?;
              if (data == null) continue;

              for (final key in ['localPath', 'url', 'filePath', 'path']) {
                final filePath = data[key] as String?;
                if (filePath != null && filePath.startsWith('files/')) {
                  final newPath = await _copyImportedFile(
                    importDir,
                    filePath,
                    filesDir,
                    block['id'] as String,
                  );
                  if (newPath != null) {
                    fileMapping[filePath] = newPath;
                    filesImported++;
                  }
                }
              }
            }
          }

          await _importMessage(msg, newConvId, fileMapping);
          messagesImported++;
        }
      }

      onProgress?.call(const ImportProgress(
        ImportPhase.done,
        1.0,
        message: 'Import completed',
      ));

      return ImportResult(
        conversationIds: importedConvIds,
        messagesImported: messagesImported,
        filesImported: filesImported,
        skipped: skipped,
        conflicts: [],
      );
    } finally {
      // 清理临时目录
      await importDir.delete(recursive: true);
    }
  }

  /// 注释已清理乱码
  Future<Directory> _extractToTempDir(File file) async {
    final bytes = await file.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);

    final tempDir = await getTemporaryDirectory();
    final importDir = Directory(
      p.join(tempDir.path, 'import_${DateTime.now().millisecondsSinceEpoch}'),
    );
    await importDir.create(recursive: true);

    for (final archiveFile in archive) {
      final filePath = p.join(importDir.path, archiveFile.name);
      if (archiveFile.isFile) {
        final file = File(filePath);
        await file.create(recursive: true);
        await file.writeAsBytes(archiveFile.content as List<int>);
      } else {
        await Directory(filePath).create(recursive: true);
      }
    }

    return importDir;
  }

  /// 注释已清理乱码
  Future<String?> _copyImportedFile(
    Directory importDir,
    String relativePath,
    Directory targetDir,
    String baseName,
  ) async {
    final sourceFile = File(p.join(importDir.path, relativePath));
    if (!await sourceFile.exists()) {
      return null;
    }

    final ext = p.extension(relativePath);
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final targetPath = p.join(targetDir.path, '${baseName}_$timestamp$ext');
    await sourceFile.copy(targetPath);

    return targetPath;
  }

  /// 导入会话
  Future<void> _importConversation(
    Map<String, dynamic> conv,
    String newId,
    Map<String, String> fileMapping,
  ) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;

    await _convRepo.upsert(ConversationsCompanion.insert(
      id: newId,
      title: conv['title'] as String? ?? conv['display_name'] as String? ?? '',
      displayName: conv['display_name'] as String? ?? '',
      avatarUrl: Value(
          fileMapping[conv['avatar_file']] ?? conv['avatar_file'] as String?),
      characterImage: Value(fileMapping[conv['character_image_file']] ??
          conv['character_image_file'] as String?),
      chatBackgroundImage: Value(
        fileMapping[conv['chat_background_image_file']] ??
            conv['chat_background_image_file'] as String?,
      ),
      chatBackgroundMaskOpacity:
          Value((conv['chat_background_mask_opacity'] as num?)?.toDouble()),
      voiceFile: Value(conv['voice_file'] as String?),
      personaPrompt: Value(conv['persona_prompt'] as String? ?? ''),
      selfAddress: Value(conv['self_address'] as String?),
      addressUser: Value(conv['address_user'] as String?),
      defaultProvider: Value(conv['default_provider'] as String?),
      createdAt: conv['created_at'] as int? ?? nowMs,
      updatedAt: nowMs,
      isPinned: Value(conv['is_pinned'] as bool? ?? false),
      isFavorite: Value(conv['is_favorite'] as bool? ?? false),
      isMuted: Value(conv['is_muted'] as bool? ?? false),
      notificationSound: Value(conv['notification_sound'] as bool? ?? true),
    ));
  }

  /// 导入消息
  Future<void> _importMessage(
    Map<String, dynamic> msg,
    String convId,
    Map<String, String> fileMapping,
  ) async {
    final msgId = msg['id'] as String;
    final nowMs = DateTime.now().millisecondsSinceEpoch;

    await _msgRepo.upsert(MessagesCompanion.insert(
      id: msgId,
      conversationId: convId,
      role: msg['role'] as String? ?? 'user',
      content: msg['content'] as String? ?? '',
      status: Value(msg['status'] as String? ?? 'sent'),
      createdAt: msg['created_at'] as int? ?? nowMs,
    ));

    // 导入 blocks
    final blocks = msg['blocks'] as List<dynamic>?;
    if (blocks != null) {
      for (var i = 0; i < blocks.length; i++) {
        final block = blocks[i];
        final data = block['data'] as Map<String, dynamic>?;

        // 更新文件路径
        Map<String, dynamic>? updatedData;
        if (data != null) {
          updatedData = Map<String, dynamic>.from(data);
          for (final key in ['localPath', 'url', 'filePath', 'path']) {
            if (updatedData[key] != null &&
                fileMapping.containsKey(updatedData[key])) {
              updatedData[key] = fileMapping[updatedData[key]];
            }
          }
        }

        await _blockRepo.upsert(MessageBlocksCompanion.insert(
          id: block['id'] as String,
          messageId: msgId,
          type: block['type'] as String? ?? 'unknown',
          status: Value(block['status'] as String? ?? 'success'),
          sortOrder: Value(block['sort_order'] as int? ?? i),
          data: updatedData != null ? jsonEncode(updatedData) : '',
          createdAt: nowMs,
        ));
      }
    }
  }
}

/// 导入异常
class ImportException implements Exception {
  final String message;
  ImportException(this.message);

  @override
  String toString() => message;
}
