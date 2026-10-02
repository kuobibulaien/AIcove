import 'dart:convert';
import 'dart:io';

import '../../../core/models/image_generation_snapshot.dart';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:uuid/uuid.dart';

import '../models/export_format.dart';
import '../../../core/database/repositories/repositories.dart';
import '../../../core/database/database.dart' show Message;
import '../../chat/id_gen.dart';
import 'transfer_safety.dart';

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
    conversationIds = List.unmodifiable(conversationIds);
    validateTransferScopes(options.scopes);
    if (conversationIds.isEmpty ||
        conversationIds.toSet().length != conversationIds.length) {
      throw const FormatException('请选择有效且不重复的角色');
    }
    final scopes = options.scopes.toSet();
    final includeCards = scopes.contains(SyncScope.characterCards);
    final includeSettings = scopes.contains(SyncScope.characterSettings);
    void report(ExportProgress progress) =>
        notifyTransferProgress(onProgress, progress);
    report(const ExportProgress(
      ExportPhase.preparing,
      0.0,
      message: '准备导出...',
    ));

    // 1. 创建临时目录
    final tempDir = await _temporaryDirectoryResolver();
    final exportId = const Uuid().v4();
    final exportDir = await tempDir.createTemp('export_');
    final filesDir = Directory(p.join(exportDir.path, 'files'));
    await filesDir.create();

    try {
      // 2. 查询数据
      report(const ExportProgress(
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
        if (dbConv == null || dbConv.deletedAt != null) {
          throw const FormatException('选中的角色已不存在，请重新选择');
        }

        // 查询消息（全部）
        final dbMsgs = scopes.contains(SyncScope.chatHistory)
            ? await _msgRepo.getAllByConversationOrderedStable(convId)
            : <Message>[];
        final messageIds = dbMsgs.map((m) => m.id).toList();
        final dbBlocks = await _blockRepo.getByMessages(messageIds);

        if (dbBlocks.any((block) => block.type == 'video')) {
          throw const FormatException('暂不支持备份视频块及缩略图，请取消聊天记录；不会生成不完整的备份。');
        }

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
        report(ExportProgress(
          ExportPhase.copyingFiles,
          progress,
          message: '处理 ${dbConv.displayName} 的文件...',
        ));

        // 复制头像
        if (includeCards &&
            dbConv.avatarUrl != null &&
            dbConv.avatarUrl!.isNotEmpty) {
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
        if (includeCards &&
            dbConv.characterImage != null &&
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
        if (includeSettings &&
            dbConv.chatBackgroundImage != null &&
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
        conversations.add(filterTransferConversation(
          _buildConversationJson(dbConv, fileMapping),
          scopes,
        ));

        // (注释已丢失)
        for (final dbMsg in dbMsgs) {
          final blocks = _withStoredMedia(
            dbMsg,
            blocksByMsgId[dbMsg.id] ?? [],
            options,
          );

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
            } else if (blockType == 'emoji' && options.includeImages) {
              filePath = data['path'] as String?;
            }

            if (filePath != null &&
                !filePath.startsWith('http') &&
                !fileMapping.containsKey(filePath)) {
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
      report(const ExportProgress(
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
        includedScopes: scopes.toList(growable: false),
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
      report(const ExportProgress(
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
            'export_${_sanitizeFileName(name)}_${dateStr}_$exportId$kExportFileExtension';
      } else {
        fileName =
            'export_${conversations.length}个角色_${dateStr}_$exportId$kExportFileExtension';
      }

      // (注释已丢失)
      File outputFile;
      try {
        final downloadsDir = _outputDirectoryResolver != null
            ? await _outputDirectoryResolver()
            : await _getDownloadsDirectory();
        await downloadsDir.create(recursive: true);
        outputFile = await _writeOutput(downloadsDir, fileName, zipBytes);
      } on FileSystemException {
        final fallbackDir = await _documentsDirectoryResolver();
        await fallbackDir.create(recursive: true);
        outputFile = await _writeOutput(fallbackDir, fileName, zipBytes);
      }

      // 6. 清理临时目录
      await _cleanup(exportDir);

      report(const ExportProgress(
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
      await _cleanup(exportDir);
      rethrow;
    }
  }

  Future<File> _writeOutput(
      Directory directory, String name, List<int> bytes) async {
    final target = File(p.join(directory.path, name));
    // 独占保留目标名；任何已有文件（包括其它实例刚写的）都不能覆盖。
    await target.create(exclusive: true);
    final partial = File('${target.path}.partial');
    try {
      await partial.writeAsBytes(bytes, flush: true);
      await partial.rename(target.path);
      return target;
    } catch (_) {
      for (final file in [partial, target]) {
        try {
          if (await file.exists()) await file.delete();
        } on FileSystemException {/* 不遮盖写入异常 */}
      }
      rethrow;
    }
  }

  static Future<void> _cleanup(Directory directory) async {
    try {
      if (await directory.exists()) await directory.delete(recursive: true);
    } on FileSystemException {/* 清理失败不影响已经生成的有效备份 */}
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
      throw const FormatException(
        '无法完整导出：选中的本地附件已缺失。请恢复文件或取消对应导出项后重试；原有备份未被修改。',
      );
    }

    final ext = p.extension(sourcePath);
    final targetPath = 'files/${genId('file')}$ext';
    final targetFile = File(p.join(targetDir.parent.path, targetPath));

    await sourceFile.copy(targetFile.path);
    return targetPath;
  }

  // 保留应用已有的内置资源/网络引用，但不能把本机私有路径冒充可移植图片。
  String? _portableImageReference(String? value) {
    if (value == null) return null;
    if (value.startsWith('assets/') ||
        value.startsWith('http://') ||
        value.startsWith('https://')) {
      return value;
    }
    return null;
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
      'avatar_file': fileMapping[dbConv.avatarUrl] ??
          _portableImageReference(dbConv.avatarUrl),
      'character_image_file': fileMapping[dbConv.characterImage] ??
          _portableImageReference(dbConv.characterImage),
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

  /// 将 DB 中已保存的媒体材料转换为 v1 本就支持的附件块。
  /// 不导出整份 raw_payload，不改原始正文，不读取当前 UI 或插件配置。
  List<Map<String, dynamic>> _withStoredMedia(
    Message message,
    List<Map<String, dynamic>> original,
    ExportOptions options,
  ) {
    // 排除媒体也适用于既有块（包括内嵌 base64），不能只停止复制文件。
    original = original
        .where((b) =>
            ((b['type'] != 'image' && b['type'] != 'emoji') ||
                options.includeImages) &&
            (b['type'] != 'audio' || options.includeAudio))
        .toList();
    if (message.rawPayload == null || message.rawPayload!.trim().isEmpty) {
      return original;
    }
    Map<String, dynamic> payload;
    try {
      // 普通文件没有图片/语音开关，关闭两项后仍需读取有效缓存中的文件。
      payload = _decodeJsonMapSafely(message.rawPayload!);
    } on FormatException {
      // 保留此前显式排除媒体时，仅恢复可读正文与标准块的降级边界。
      if (!options.includeImages && !options.includeAudio) return original;
      rethrow;
    }
    final media = <Map<String, dynamic>>[];
    void collect(dynamic kind, Map<String, dynamic> item,
        {String audioKey = 'url', bool nativeBlock = false}) {
      if (kind == 'video') {
        throw const FormatException('暂不支持备份视频块及缩略图，请取消聊天记录；不会生成不完整的备份。');
      }
      final selected = switch (kind) {
        'image' => options.includeImages,
        'audio' => options.includeAudio,
        'emoji' => nativeBlock && options.includeImages,
        'file' => nativeBlock,
        _ => false,
      };
      if (selected) {
        media.add(
            _normalizeStoredMedia(kind as String, item, audioKey: audioKey));
      }
    }

    // 与真实聊天还原器的优先级保持一致，避免把已被覆盖的旧附件复活。
    final cached = _mediaObjects(payload['projectedMessages']);
    var authoritative = cached.isNotEmpty;
    if (cached.isNotEmpty) {
      for (final message in cached) {
        for (final block in _mediaObjects(message['blocks'])) {
          collect(block['type'], block, nativeBlock: true);
        }
      }
    } else if (message.role == 'assistant') {
      final supplements = _mediaObjects(payload['supplementInsertOps']);
      authoritative = supplements.isNotEmpty;
      if (supplements.isNotEmpty) {
        for (final item in supplements) {
          collect(item['kind'], item, audioKey: 'audioUrl');
        }
      } else {
        final contents = _mediaObjects(payload['pluginContents']);
        final audioResults = _mediaObjects(payload['toolAudioResults']);
        authoritative = contents.isNotEmpty || audioResults.isNotEmpty;
        for (final item in contents) {
          collect(item['type'], item, audioKey: 'localPath');
        }
        for (final item in audioResults) {
          collect('audio', item, audioKey: 'audioUrl');
        }
      }
    }
    if (authoritative) {
      // 高优先级材料也会明确隐藏旧 DB 媒体，不能把两份表示简单求并集。
      final active = <String, List<Map<String, dynamic>>>{};
      for (final item in media) {
        final key = _mediaIdentity(item['type'] as String, item);
        active.putIfAbsent(key, () => []).add(item);
      }
      final positions = <String, int>{};
      final reconciled = <Map<String, dynamic>>[];
      for (final block in original) {
        if (!_isFileBackedBlock(block['type'])) {
          reconciled.add(block);
          continue;
        }
        final key = _mediaIdentity(
            block['type'] as String, block['data'] as Map<String, dynamic>);
        final candidates = active[key] ?? const [];
        final index = positions[key] ?? 0;
        if (index >= candidates.length) continue;
        positions[key] = index + 1;
        final current = candidates[index];
        // 文件引用相同也不能保留旧名称/旧表情文字；只保留标准块身份。
        reconciled.add({
          ...block,
          'status': current['status'],
          'data': {
            ...current,
            'id': block['id'],
            'messageId': message.id,
            'createdAt': DateTime.fromMillisecondsSinceEpoch(message.createdAt)
                .toIso8601String(),
          }
        });
      }
      original = reconciled;
    }
    if (media.isEmpty) return original;

    final result = original.map((b) => Map<String, dynamic>.from(b)).toList();
    final ids = result.map((b) => b['id']).toSet();
    final represented = <String, int>{};
    for (final block in original) {
      if (_isFileBackedBlock(block['type'])) {
        final key = _mediaIdentity(
            block['type'] as String, block['data'] as Map<String, dynamic>);
        represented[key] = (represented[key] ?? 0) + 1;
      }
    }
    var ordinal = 0;
    Map<String, dynamic> makeBlock(Map<String, dynamic> data, int order) {
      String id;
      do {
        id = const Uuid().v5(Namespace.url.value,
            'aicove/export-media/${message.id}/${ordinal++}');
      } while (!ids.add(id));
      return {
        'id': id,
        'source_block_id': id,
        'type': data['type'],
        'status': data['status'] ?? 'success',
        'sort_order': order,
        'data': {
          ...data,
          'id': id,
          'messageId': message.id,
          'createdAt': DateTime.fromMillisecondsSinceEpoch(message.createdAt)
              .toIso8601String()
        },
      };
    }

    // 附件存在后气泡会按 blocks 渲染，必须保留原正文，不能让正文被附件遮掉。
    if (message.content.isNotEmpty &&
        !result.any((b) => b['type'] == 'mainText')) {
      final firstOrder = result.fold<int>(
          0,
          (min, b) =>
              (b['sort_order'] as int) < min ? b['sort_order'] as int : min);
      result.insert(
          0,
          makeBlock({
            'type': 'mainText',
            'status': 'success',
            'content': message.content
          }, firstOrder - 1));
    }
    var order = result.fold<int>(
            0,
            (max, b) =>
                (b['sort_order'] as int) > max ? b['sort_order'] as int : max) +
        1;
    for (final item in media) {
      final key = _mediaIdentity(item['type'] as String, item);
      final remaining = represented[key] ?? 0;
      if (remaining > 0) {
        represented[key] = remaining - 1;
      } else {
        result.add(makeBlock(item, order++));
      }
    }
    return result;
  }

  List<Map<String, dynamic>> _mediaObjects(dynamic value) {
    if (value == null) return const [];
    if (value is! List || value.any((item) => item is! Map<String, dynamic>)) {
      throw const FormatException('聊天媒体材料损坏，已停止导出，未修改原记录。');
    }
    return value.cast<Map<String, dynamic>>();
  }

  String? _mediaString(Map<String, dynamic> data, String key) {
    final value = data[key];
    if (value == null) return null;
    if (value is! String) throw const FormatException('聊天媒体字段格式错误，已停止导出。');
    return value.isEmpty ? null : value;
  }

  Map<String, dynamic> _normalizeStoredMedia(
      String kind, Map<String, dynamic> item,
      {required String audioKey}) {
    final data = <String, dynamic>{
      'type': kind,
      'status': _mediaString(item, 'status') ?? 'success'
    };
    if (kind == 'image') {
      final snapshot = ImageGenerationSnapshot.tryRead(item['generationSnapshot']);
      if (snapshot != null) data['generationSnapshot'] = snapshot.toJson();
      for (final key in ['localPath', 'url', 'base64', 'prompt']) {
        final value = _mediaString(item, key);
        if (value != null) data[key] = value;
      }
      final caption = _mediaString(item, 'caption');
      if (!data.containsKey('prompt') && caption != null) {
        data['prompt'] = caption;
      }
      for (final key in ['width', 'height']) {
        final value = item[key];
        if (value != null) {
          if (value is! int || value < 0) {
            throw const FormatException('聊天图片尺寸格式错误，已停止导出。');
          }
          data[key] = value;
        }
      }
      if (!data.containsKey('localPath') &&
          !data.containsKey('url') &&
          !data.containsKey('base64')) {
        throw const FormatException('聊天图片缺少内容或文件地址，已停止导出。');
      }
    } else if (kind == 'file' || kind == 'emoji') {
      final requiredKeys = kind == 'file'
          ? ['filePath', 'fileName', 'mimeType']
          : ['path', 'emojiId'];
      for (final key in requiredKeys) {
        final value = _mediaString(item, key);
        if (value == null) throw const FormatException('聊天文件或表情包信息缺失，已停止导出。');
        data[key] = value;
      }
      if (kind == 'file') {
        final size = item['fileSize'];
        if (size is! int || size < 0) {
          throw const FormatException('聊天文件大小格式错误，已停止导出。');
        }
        data['fileSize'] = size;
      } else {
        for (final key in ['matchedTag', 'originalText']) {
          final value = _mediaString(item, key);
          if (value != null) data[key] = value;
        }
      }
    } else {
      final url = _mediaString(item, audioKey);
      if (url == null) throw const FormatException('聊天语音缺少文件地址，已停止导出。');
      data['url'] = url;
      final text = _mediaString(item, 'text');
      if (text != null) data['text'] = text;
      final duration = item['durationSeconds'] ?? item['durationMs'];
      if (duration != null) {
        if (duration is! num || !duration.isFinite || duration < 0) {
          throw const FormatException('聊天语音时长格式错误，已停止导出。');
        }
        data['durationSeconds'] =
            duration.toDouble() / (item['durationSeconds'] == null ? 1000 : 1);
      }
    }
    return data;
  }

  bool _isFileBackedBlock(Object? type) =>
      const {'image', 'audio', 'file', 'emoji'}.contains(type);

  String _mediaIdentity(String kind, Map<String, dynamic> data) => jsonEncode([
        kind,
        switch (kind) {
          'image' => data['localPath'] ?? data['url'] ?? data['base64'],
          'file' => data['filePath'],
          'emoji' => data['path'],
          _ => data['url'],
        },
      ]);

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
        final value = newData[key];
        if (value is String && fileMapping.containsKey(value)) {
          newData[key] = fileMapping[value];
        } else if (value is String &&
            value.isNotEmpty &&
            !value.startsWith('http://') &&
            !value.startsWith('https://') &&
            !value.startsWith('assets/') &&
            !value.startsWith('data:')) {
          // 未打包或主动排除的本地附件不能留下设备私有路径。
          newData.remove(key);
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
    } on FormatException {
      // 不带原始 JSON 内容，避免把聊天或文件路径塞进错误提示。
      throw const FormatException('聊天附件数据损坏，已停止导出；原始记录和已有备份未被修改。');
    }
    throw const FormatException('聊天附件数据格式无效，已停止导出；原始记录和已有备份未被修改。');
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
