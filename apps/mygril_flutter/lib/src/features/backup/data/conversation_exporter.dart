import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../models/export_format.dart';
import '../../../core/database/repositories/repositories.dart';

/// 浼氳瘽瀵煎嚭鏈嶅姟
class ConversationExporter {
  final ConversationRepository _convRepo;
  final MessageRepository _msgRepo;
  final MessageBlockRepository _blockRepo;

  ConversationExporter({
    required ConversationRepository convRepo,
    required MessageRepository msgRepo,
    required MessageBlockRepository blockRepo,
  })  : _convRepo = convRepo,
        _msgRepo = msgRepo,
        _blockRepo = blockRepo;

  /// 瀵煎嚭澶氫釜浼氳瘽
  Future<ExportResult> exportConversations({
    required List<String> conversationIds,
    ExportOptions options = const ExportOptions(),
    void Function(ExportProgress)? onProgress,
  }) async {
    onProgress?.call(const ExportProgress(
      ExportPhase.preparing,
      0.0,
      message: '鍑嗗瀵煎嚭...',
    ));

    // 1. 鍒涘缓涓存椂鐩綍
    final tempDir = await getTemporaryDirectory();
    final exportId = DateTime.now().millisecondsSinceEpoch.toString();
    final exportDir = Directory(p.join(tempDir.path, 'export_$exportId'));
    await exportDir.create(recursive: true);
    final filesDir = Directory(p.join(exportDir.path, 'files'));
    await filesDir.create();

    try {
      // 2. 鏌ヨ鏁版嵁
      onProgress?.call(const ExportProgress(
        ExportPhase.queryingData,
        0.1,
        message: '鏌ヨ鏁版嵁...',
      ));

      final conversations = <Map<String, dynamic>>[];
      final allMessages = <Map<String, dynamic>>[];
      final fileMapping = <String, String>{}; // 鍘熻矾寰?鈫?ZIP鍐呰矾寰?
      int totalFileCount = 0;

      for (var i = 0; i < conversationIds.length; i++) {
        final convId = conversationIds[i];
        final progress = 0.1 + (0.3 * i / conversationIds.length);

        // 鏌ヨ浼氳瘽
        final dbConv = await _convRepo.getById(convId);
        if (dbConv == null) continue;

        // 鏌ヨ娑堟伅锛堝叏閮級
        final dbMsgs = await _msgRepo.getByConversation(convId);
        final messageIds = dbMsgs.map((m) => m.id).toList();
        final dbBlocks = await _blockRepo.getByMessages(messageIds);

        // 鎸?messageId 鍒嗙粍 blocks
        final blocksByMsgId = <String, List<Map<String, dynamic>>>{};
        for (final dbBlock in dbBlocks) {
          blocksByMsgId.putIfAbsent(dbBlock.messageId, () => []).add({
            'id': dbBlock.id,
            'type': dbBlock.type,
            'status': dbBlock.status,
            'sort_order': dbBlock.sortOrder,
            'data': jsonDecode(dbBlock.data),
          });
        }

        // 3. 澶嶅埗鏂囦欢骞舵洿鏂拌矾寰?
        onProgress?.call(ExportProgress(
          ExportPhase.copyingFiles,
          progress,
          message: '澶勭悊 ${dbConv.displayName} 鐨勬枃浠?..',
        ));

        // 澶嶅埗澶村儚
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

        // 澶嶅埗瑙掕壊绔嬬粯
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

        // 鏋勫缓浼氳瘽 JSON
        conversations.add(_buildConversationJson(dbConv, fileMapping));

        // 鏋勫缓娑堟伅 JSON 骞跺鍒堕檮浠?
        for (final dbMsg in dbMsgs) {
          final blocks = blocksByMsgId[dbMsg.id] ?? [];

          // 澶嶅埗娑堟伅涓殑濯掍綋鏂囦欢
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

      // 4. 鐢熸垚 JSON 鏂囦欢
      onProgress?.call(const ExportProgress(
        ExportPhase.packaging,
        0.7,
        message: '鐢熸垚瀵煎嚭鏂囦欢...',
      ));

      // 鑾峰彇搴旂敤鐗堟湰
      final packageInfo = await PackageInfo.fromPlatform();

      // manifest.json
      final manifest = ExportManifest(
        formatVersion: kExportFormatVersion,
        appVersion: packageInfo.version,
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

      // 5. 鎵撳寘鎴?ZIP
      onProgress?.call(const ExportProgress(
        ExportPhase.packaging,
        0.85,
        message: '鍘嬬缉鏂囦欢...',
      ));

      final archive = Archive();
      await _addDirectoryToArchive(archive, exportDir, exportDir.path);

      final zipBytes = ZipEncoder().encode(archive);
      if (zipBytes == null) {
        throw Exception('ZIP 鍘嬬缉澶辫触');
      }

      // 鐢熸垚鏂囦欢鍚?
      final dateStr = _formatDate(DateTime.now());
      String fileName;
      if (conversations.length == 1) {
        final name = conversations.first['display_name'] as String? ?? 'export';
        fileName = 'export_${name}_$dateStr$kExportFileExtension';
      } else {
        fileName =
            'export_${conversations.length}涓鑹瞋$dateStr$kExportFileExtension';
      }

      // 淇濆瓨鍒颁笅杞界洰褰?
      final downloadsDir = await _getDownloadsDirectory();
      final outputFile = File(p.join(downloadsDir.path, fileName));
      await outputFile.writeAsBytes(zipBytes);

      // 6. 娓呯悊涓存椂鐩綍
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
      // 娓呯悊涓存椂鐩綍
      if (await exportDir.exists()) {
        await exportDir.delete(recursive: true);
      }
      rethrow;
    }
  }

  /// 澶嶅埗鏂囦欢鍒板鍑虹洰褰?
  Future<String?> _copyFileIfExists(
    String sourcePath,
    Directory targetDir,
    String baseName,
  ) async {
    // 璺宠繃缃戠粶 URL
    if (sourcePath.startsWith('http://') || sourcePath.startsWith('https://')) {
      return null;
    }
    if (sourcePath.startsWith('data:image')) {
      return null;
    }

    // 璺宠繃 assets
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

  /// 鏋勫缓浼氳瘽 JSON
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
      'description': dbConv.description,
      'default_provider': dbConv.defaultProvider,
      'created_at': dbConv.createdAt?.millisecondsSinceEpoch,
      'updated_at': dbConv.updatedAt?.millisecondsSinceEpoch,
      'is_pinned': dbConv.isPinned,
      'is_favorite': dbConv.isFavorite,
      'is_muted': dbConv.isMuted,
      'notification_sound': dbConv.notificationSound,
    };
  }

  /// 鏋勫缓娑堟伅 JSON
  Map<String, dynamic> _buildMessageJson(
    dynamic dbMsg,
    List<Map<String, dynamic>> blocks,
    Map<String, String> fileMapping,
  ) {
    // 鏇存柊 blocks 涓殑鏂囦欢璺緞
    final updatedBlocks = blocks.map((block) {
      final data = block['data'] as Map<String, dynamic>?;
      if (data == null) return block;

      final newData = Map<String, dynamic>.from(data);

      // 鏇存柊鍚勭鏂囦欢璺緞
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
      'conversation_id': dbMsg.conversationId,
      'role': dbMsg.role,
      'content': dbMsg.content,
      'status': dbMsg.status,
      'created_at': dbMsg.createdAt?.millisecondsSinceEpoch,
      'blocks': updatedBlocks,
    };
  }

  /// 灏嗙洰褰曟坊鍔犲埌 Archive
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

  /// 鑾峰彇涓嬭浇鐩綍
  Future<Directory> _getDownloadsDirectory() async {
    if (Platform.isAndroid) {
      // Android: /storage/emulated/0/Download
      final dir = Directory('/storage/emulated/0/Download');
      if (await dir.exists()) {
        return dir;
      }
      // 澶囩敤锛氬簲鐢ㄥ閮ㄧ洰褰?
      final extDir = await getExternalStorageDirectory();
      return extDir ?? await getApplicationDocumentsDirectory();
    } else if (Platform.isWindows) {
      // Windows: 鐢ㄦ埛涓嬭浇鏂囦欢澶?
      final userProfile = Platform.environment['USERPROFILE'];
      if (userProfile != null) {
        final dir = Directory(p.join(userProfile, 'Downloads'));
        if (await dir.exists()) {
          return dir;
        }
      }
    }
    // 榛樿锛氬簲鐢ㄦ枃妗ｇ洰褰?
    return await getApplicationDocumentsDirectory();
  }

  /// 鏍煎紡鍖栨棩鏈?
  String _formatDate(DateTime date) {
    return '${date.year}${date.month.toString().padLeft(2, '0')}${date.day.toString().padLeft(2, '0')}';
  }
}
