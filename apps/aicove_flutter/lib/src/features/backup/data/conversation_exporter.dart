import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../models/export_format.dart';
import '../../../core/database/repositories/repositories.dart';

/// 会话导出服务
class ConversationExporter {
  final ConversationRepository _convRepo;
  final MessageRepository _msgRepo;
  final MessageBlockRepository _blockRepo;
  final Future<Directory> Function() _temporaryDirectoryResolver;
  final Future<Directory> Function() _documentsDirectoryResolver;
  final Future<Directory?> Function() _externalStorageDirectoryResolver;
  final Future<String> Function() _appVersionResolver;
  final Future<Directory> Function()? _outputDirectoryResolver;

  ConversationExporter({
    required ConversationRepository convRepo,
    required MessageRepository msgRepo,
    required MessageBlockRepository blockRepo,
    Future<Directory> Function()? temporaryDirectoryResolver,
    Future<Directory> Function()? documentsDirectoryResolver,
    Future<Directory?> Function()? externalStorageDirectoryResolver,
    Future<String> Function()? appVersionResolver,
    Future<Directory> Function()? outputDirectoryResolver,
  })  : _convRepo = convRepo,
        _msgRepo = msgRepo,
        _blockRepo = blockRepo,
        _temporaryDirectoryResolver =
            temporaryDirectoryResolver ?? getTemporaryDirectory,
        _documentsDirectoryResolver =
            documentsDirectoryResolver ?? getApplicationDocumentsDirectory,
        _externalStorageDirectoryResolver =
            externalStorageDirectoryResolver ?? getExternalStorageDirectory,
        _appVersionResolver = appVersionResolver ?? _defaultAppVersionResolver,
        _outputDirectoryResolver = outputDirectoryResolver;

  /// 导出多个会话
  Future<ExportResult> exportConversations({
    required List<String> conversationIds,
    ExportOptions options = const ExportOptions(),
    void Function(ExportProgress)? onProgress,
  }) async {
    onProgress?.call(const ExportProgress(
      ExportPhase.preparing,
      0.0,
      message: '准备导出...',
    ));

    // 1. 创建临时目录
    final tempDir = await _temporaryDirectoryResolver();
    final exportId = DateTime.now().millisecondsSinceEpoch.toString();
    final exportDir = Directory(p.join(tempDir.path, 'export_$exportId'));
    await exportDir.create(recursive: true);
    final filesDir = Directory(p.join(exportDir.path, 'files'));
    await filesDir.create();

    try {
      // 2. 查询数据
      onProgress?.call(const ExportProgress(
        ExportPhase.queryingData,
        0.1,
        message: '查询数据...',
      ));

      final conversations = <Map<String, dynamic>>[];
      final allMessages = <Map<String, dynamic>>[];
      final fileMapping = <String, String>{}; // (注释已丢失)
      int totalFileCount = 0;

      for (var i = 0; i < conversationIds.length; i++) {
        final convId = conversationIds[i];
        final progress = 0.1 + (0.3 * i / conversationIds.length);

        // 查询会话
        final dbConv = await _convRepo.getById(convId);
        if (dbConv == null) continue;

        // 查询消息（全部）
        final dbMsgs = await _msgRepo.getAllByConversationOrderedStable(convId);
        final messageIds = dbMsgs.map((m) => m.id).toList();
        final dbBlocks = await _blockRepo.getByMessages(messageIds);

        // (注释已丢失)
        final blocksByMsgId = <String, List<Map<String, dynamic>>>{};
        for (final dbBlock in dbBlocks) {
          blocksByMsgId.putIfAbsent(dbBlock.messageId, () => []).add({
            'id': dbBlock.id,
            'source_block_id': dbBlock.sourceBlockId,
            'type': dbBlock.type,
            'status': dbBlock.status,
            'sort_order': dbBlock.sortOrder,
            'data': _decodeJsonMapSafely(dbBlock.data),
          });
        }

        // (注释已丢失)
        onProgress?.call(ExportProgress(
          ExportPhase.copyingFiles,
          progress,
          message: '处理 ${dbConv.displayName} 的文件...',
        ));

        // 复制头像
        if (dbConv.avatarUrl != null && dbConv.avatarUrl!.isNotEmpty) {
          final newPath = await _copyFileIfExists(
            dbConv.avatarUrl!,
            filesDir,
            'avatar_${dbConv.id}',
          );
          if (newPath != null) {
            fileMapping[dbConv.avatarUrl!] = newPath;
            totalFileCount++;
          }
        }

        // 复制角色立绘
        if (dbConv.characterImage != null &&
            dbConv.characterImage!.isNotEmpty) {
          final newPath = await _copyFileIfExists(
            dbConv.characterImage!,
            filesDir,
            'character_${dbConv.id}',
          );
          if (newPath != null) {
            fileMapping[dbConv.characterImage!] = newPath;
            totalFileCount++;
          }
        }

        // copy chat background
        if (dbConv.chatBackgroundImage != null &&
            dbConv.chatBackgroundImage!.isNotEmpty) {
          final newPath = await _copyFileIfExists(
            dbConv.chatBackgroundImage!,
            filesDir,
            'chat_bg_${dbConv.id}',
          );
          if (newPath != null) {
            fileMapping[dbConv.chatBackgroundImage!] = newPath;
            totalFileCount++;
          }
        }

        // 构建会话 JSON
        conversations.add(_buildConversationJson(dbConv, fileMapping));

        // (注释已丢失)
        for (final dbMsg in dbMsgs) {
          final blocks = blocksByMsgId[dbMsg.id] ?? [];

          // 复制消息中的媒体文件
          for (final block in blocks) {
            final data = block['data'] as Map<String, dynamic>?;
            if (data == null) continue;

            final blockType = block['type'] as String?;
            String? filePath;

            if (blockType == 'image' && options.includeImages) {
              filePath = data['localPath'] as String? ?? data['url'] as String?;
            } else if (blockType == 'audio' && options.includeAudio) {
              filePath = data['url'] as String?;
            } else if (blockType == 'file') {
              filePath = data['filePath'] as String?;
            }

            if (filePath != null && !filePath.startsWith('http')) {
              final newPath = await _copyFileIfExists(
                filePath,
                filesDir,
                block['id'] as String,
              );
              if (newPath != null) {
                fileMapping[filePath] = newPath;
                totalFileCount++;
              }
            }
          }

          allMessages.add(_buildMessageJson(dbMsg, blocks, fileMapping));
        }
      }

      // 4. 生成 JSON 文件
      onProgress?.call(const ExportProgress(
        ExportPhase.packaging,
        0.7,
        message: '生成导出文件...',
      ));

      // 获取应用版本
      final appVersion = await _appVersionResolver();

      // manifest.json
      final manifest = ExportManifest(
        formatVersion: kExportFormatVersion,
        appVersion: appVersion,
        exportTime: DateTime.now(),
        exportDevice: '${Platform.operatingSystem} / ${Platform.localHostname}',
        includedScopes: options.scopes,
        conversationCount: conversations.length,
        messageCount: allMessages.length,
        fileCount: totalFileCount,
      );
      await File(p.join(exportDir.path, 'manifest.json')).writeAsString(
          const JsonEncoder.withIndent('  ').convert(manifest.toJson()));

      // conversations.json
      await File(p.join(exportDir.path, 'conversations.json'))
          .writeAsString(const JsonEncoder.withIndent('  ').convert({
        'version': 1,
        'conversations': conversations,
      }));

      // messages.json
      await File(p.join(exportDir.path, 'messages.json'))
          .writeAsString(const JsonEncoder.withIndent('  ').convert({
        'version': 1,
        'messages': allMessages,
      }));

      // (注释已丢失)
      onProgress?.call(const ExportProgress(
        ExportPhase.packaging,
        0.85,
        message: '压缩文件...',
      ));

      final archive = Archive();
      await _addDirectoryToArchive(archive, exportDir, exportDir.path);

      final zipBytes = ZipEncoder().encode(archive);
      if (zipBytes == null) {
        throw Exception('ZIP 压缩失败');
      }

      // (注释已丢失)
      final dateStr = _formatDate(DateTime.now());
      String fileName;
      if (conversations.length == 1) {
        final name = conversations.first['display_name'] as String? ?? 'export';
        fileName =
            'export_${_sanitizeFileName(name)}_$dateStr$kExportFileExtension';
      } else {
        fileName =
            'export_${conversations.length}个角色_$dateStr$kExportFileExtension';
      }

      // (注释已丢失)
      File outputFile;
      try {
        final downloadsDir = _outputDirectoryResolver != null
            ? await _outputDirectoryResolver()
            : await _getDownloadsDirectory();
        await downloadsDir.create(recursive: true);
        outputFile = File(p.join(downloadsDir.path, fileName));
        await outputFile.writeAsBytes(zipBytes, flush: true);
      } on FileSystemException {
        final fallbackDir = await _documentsDirectoryResolver();
        await fallbackDir.create(recursive: true);
        outputFile = File(p.join(fallbackDir.path, fileName));
        await outputFile.writeAsBytes(zipBytes, flush: true);
      }

      // 6. 清理临时目录
      await exportDir.delete(recursive: true);

      onProgress?.call(const ExportProgress(
        ExportPhase.done,
        1.0,
        message: 'Export completed',
      ));

      return ExportResult(
        filePath: outputFile.path,
        fileName: fileName,
        conversationCount: conversations.length,
        messageCount: allMessages.length,
        fileCount: totalFileCount,
        sizeBytes: await outputFile.length(),
      );
    } catch (e) {
      // 清理临时目录
      if (await exportDir.exists()) {
        await exportDir.delete(recursive: true);
      }
      rethrow;
    }
  }

  /// (注释已丢失)
  Future<String?> _copyFileIfExists(
    String sourcePath,
    Directory targetDir,
    String baseName,
  ) async {
    // 跳过网络 URL
    if (sourcePath.startsWith('http://') || sourcePath.startsWith('https://')) {
      return null;
    }
    if (sourcePath.startsWith('data:image')) {
      return null;
    }

    // 跳过 assets
    if (sourcePath.startsWith('assets/')) {
      return null;
    }

    final sourceFile = File(sourcePath);
    if (!await sourceFile.exists()) {
      return null;
    }

    final ext = p.extension(sourcePath);
    final targetPath = 'files/$baseName$ext';
    final targetFile = File(p.join(targetDir.parent.path, targetPath));

    await sourceFile.copy(targetFile.path);
    return targetPath;
  }

  /// 构建会话 JSON
  Map<String, dynamic> _buildConversationJson(
    dynamic dbConv,
    Map<String, String> fileMapping,
  ) {
    return {
      'id': dbConv.id,
      'title': dbConv.title,
      'display_name': dbConv.displayName,
      'avatar_file': fileMapping[dbConv.avatarUrl],
      'character_image_file': fileMapping[dbConv.characterImage],
      'chat_background_image_file':
          fileMapping[dbConv.chatBackgroundImage] ?? dbConv.chatBackgroundImage,
      'chat_background_mask_opacity': dbConv.chatBackgroundMaskOpacity,
      'voice_file': dbConv.voiceFile,
      'persona_prompt': dbConv.personaPrompt,
      'self_address': dbConv.selfAddress,
      'address_user': dbConv.addressUser,
      'default_provider': dbConv.defaultProvider,
      'created_at': _toEpochMillis(dbConv.createdAt),
      'updated_at': _toEpochMillis(dbConv.updatedAt),
      'is_pinned': dbConv.isPinned,
      'is_favorite': dbConv.isFavorite,
      'is_muted': dbConv.isMuted,
      'notification_sound': dbConv.notificationSound,
    };
  }

  /// 构建消息 JSON
  Map<String, dynamic> _buildMessageJson(
    dynamic dbMsg,
    List<Map<String, dynamic>> blocks,
    Map<String, String> fileMapping,
  ) {
    // 更新 blocks 中的文件路径
    final updatedBlocks = blocks.map((block) {
      final data = block['data'] as Map<String, dynamic>?;
      if (data == null) return block;

      final newData = Map<String, dynamic>.from(data);

      // 更新各种文件路径
      for (final key in ['localPath', 'url', 'filePath', 'path']) {
        if (newData[key] != null && fileMapping.containsKey(newData[key])) {
          newData[key] = fileMapping[newData[key]];
        }
      }

      return {
        ...block,
        'data': newData,
      };
    }).toList();

    return {
      'id': dbMsg.id,
      'source_message_id': dbMsg.sourceMessageId,
      'conversation_id': dbMsg.conversationId,
      'role': dbMsg.role,
      'content': dbMsg.content,
      'status': dbMsg.status,
      'created_at': _toEpochMillis(dbMsg.createdAt),
      'blocks': updatedBlocks,
    };
  }

  /// 将目录添加到 Archive
  Future<void> _addDirectoryToArchive(
    Archive archive,
    Directory dir,
    String basePath,
  ) async {
    await for (final entity in dir.list(recursive: true)) {
      if (entity is File) {
        final relativePath = p.relative(entity.path, from: basePath);
        final bytes = await entity.readAsBytes();
        archive.addFile(ArchiveFile(
          relativePath.replaceAll('\\', '/'),
          bytes.length,
          bytes,
        ));
      }
    }
  }

  /// 获取下载目录
  Future<Directory> _getDownloadsDirectory() async {
    if (Platform.isAndroid) {
      // Android: /storage/emulated/0/Download
      final dir = Directory('/storage/emulated/0/Download');
      if (await dir.exists()) {
        return dir;
      }
      // (注释已丢失)
      final extDir = await _externalStorageDirectoryResolver();
      return extDir ?? await _documentsDirectoryResolver();
    } else if (Platform.isWindows) {
      // (注释已丢失)
      final userProfile = Platform.environment['USERPROFILE'];
      if (userProfile != null) {
        final dir = Directory(p.join(userProfile, 'Downloads'));
        if (await dir.exists()) {
          return dir;
        }
      }
    }
    // (注释已丢失)
    return await _documentsDirectoryResolver();
  }

  /// (注释已丢失)
  String _formatDate(DateTime date) {
    return '${date.year}${date.month.toString().padLeft(2, '0')}${date.day.toString().padLeft(2, '0')}';
  }

  Map<String, dynamic> _decodeJsonMapSafely(String raw) {
    if (raw.trim().isEmpty) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return decoded.map(
          (key, value) => MapEntry(key.toString(), value),
        );
      }
    } catch (_) {
      // ignore malformed legacy block data
    }
    return <String, dynamic>{};
  }

  String _sanitizeFileName(String fileName) {
    final sanitized = fileName
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return sanitized.isEmpty ? 'export' : sanitized;
  }

  static Future<String> _defaultAppVersionResolver() async {
    final packageInfo = await PackageInfo.fromPlatform();
    return packageInfo.version;
  }

  int? _toEpochMillis(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is DateTime) return value.millisecondsSinceEpoch;
    return null;
  }
}
