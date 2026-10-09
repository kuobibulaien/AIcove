import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'transfer_safety.dart';
import '../models/export_format.dart';
import '../../../core/database/database.dart' hide SyncScope;
import '../../../core/database/repositories/repositories.dart';
import '../../../core/models/message_block.dart' as domain;
import '../../chat/id_gen.dart';

/// 会话导入服务
class ConversationImporter {
  final ConversationRepository _convRepo;
  final MessageRepository _msgRepo;
  final MessageBlockRepository _blockRepo;
  final Future<Directory> Function() _temporaryDirectoryResolver;
  final Future<Directory> Function() _documentsDirectoryResolver;

  ConversationImporter({
    required ConversationRepository convRepo,
    required MessageRepository msgRepo,
    required MessageBlockRepository blockRepo,
    Future<Directory> Function()? temporaryDirectoryResolver,
    Future<Directory> Function()? documentsDirectoryResolver,
  })  : _convRepo = convRepo,
        _msgRepo = msgRepo,
        _blockRepo = blockRepo,
        _temporaryDirectoryResolver =
            temporaryDirectoryResolver ?? getTemporaryDirectory,
        _documentsDirectoryResolver =
            documentsDirectoryResolver ?? getApplicationDocumentsDirectory;

  /// (注释已丢失)
  Future<ImportPreview> preview(File file, {String? password}) async {
    final importDir = await _extractToTempDir(file, password);

    try {
      // 读取 manifest
      final manifestFile = File(p.join(importDir.path, 'manifest.json'));
      if (!await manifestFile.exists()) {
        throw ImportException('无效的导入文件：缺少 manifest.json');
      }

      final manifestJson = jsonDecode(await manifestFile.readAsString());
      final manifest = ExportManifest.fromJson(manifestJson);

      // (注释已丢失)
      final isCompatible = manifest.formatVersion >= 1 &&
          manifest.formatVersion <= kExportFormatVersion;
      String? incompatibleReason;
      if (!isCompatible) {
        incompatibleReason = manifest.formatVersion < 1
            ? '文件格式版本无效'
            : '文件版本过新（v${manifest.formatVersion}），请更新 App';
      }

      final convList =
          await _readRecords(importDir, 'conversations.json', 'conversations');
      final hasHistory =
          manifest.includedScopes.contains(SyncScope.chatHistory);
      final msgList = hasHistory
          ? await _readRecords(importDir, 'messages.json', 'messages')
          : <dynamic>[];
      _validateArchiveIndex(
          manifestJson, convList, hasHistory ? msgList : null);

      // 按包声明统计；不读取旧包误夹带的未声明聊天。
      Map<String, int> messageCountByConv = {};
      Map<String, int> imageCountByConv = {};
      Map<String, int> audioCountByConv = {};
      Map<String, int?> lastMessageTimeByConv = {};

      if (hasHistory) {
        for (final msg in msgList) {
          final convId = msg['conversation_id'] as String;
          messageCountByConv[convId] = (messageCountByConv[convId] ?? 0) + 1;

          // (注释已丢失)
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

      // (注释已丢失)
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
    String? password,
    void Function(ImportProgress)? onProgress,
  }) async {
    selectedScopes = List.unmodifiable(selectedScopes);
    selectedConversationIds = List.unmodifiable(selectedConversationIds);
    conflictResolutions = Map.unmodifiable(conflictResolutions);
    validateTransferScopes(selectedScopes);
    if (selectedConversationIds.isEmpty ||
        selectedConversationIds.toSet().length !=
            selectedConversationIds.length) {
      throw ImportException('请选择有效且不重复的角色');
    }
    void report(ImportProgress progress) =>
        notifyTransferProgress(onProgress, progress);
    report(const ImportProgress(
      ImportPhase.extracting,
      0.0,
      message: '解压文件...',
    ));

    final importDir = await _extractToTempDir(file, password);
    Directory? jobFiles;
    var committed = false;

    try {
      report(const ImportProgress(
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

      if (manifest.formatVersion < 1) throw ImportException('文件格式版本无效');
      if (manifest.formatVersion > kExportFormatVersion) {
        throw ImportException('文件版本过新，请更新 App');
      }

      final scopes =
          selectedScopes.toSet().intersection(manifest.includedScopes.toSet());
      validateTransferScopes(scopes);
      final includeHistory = scopes.contains(SyncScope.chatHistory);

      final convList =
          await _readRecords(importDir, 'conversations.json', 'conversations');
      final msgList = includeHistory
          ? await _readRecords(importDir, 'messages.json', 'messages')
          : <dynamic>[];
      _validateArchiveIndex(
          manifestJson, convList, includeHistory ? msgList : null);

      // (注释已丢失)
      final selectedConvs = convList
          .where((c) => selectedConversationIds.contains(c['id']))
          .map((c) {
            final source = Map<String, dynamic>.from(c as Map);
            validateTransferConversation(source, scopes);
            return filterTransferConversation(source, scopes);
          })
          .toList();
      if (selectedConvs.length != selectedConversationIds.length ||
          selectedConvs.map((c) => c['id']).toSet().length !=
              selectedConvs.length) {
        throw ImportException('备份中的角色缺失或 ID 重复');
      }
      final selectedMessages = msgList
          .where((m) => selectedConversationIds.contains(m['conversation_id']))
          .toList();
      _validateMessageIds(selectedMessages);

      // 获取应用数据目录
      final appDir = await _documentsDirectoryResolver();
      final filesRoot = Directory(p.join(appDir.path, 'imported_files'));
      if (await FileSystemEntity.type(filesRoot.path, followLinks: false) ==
          FileSystemEntityType.link) {
        throw ImportException('附件目录不能是符号链接');
      }
      await filesRoot.create(recursive: true);
      final filesDir = await filesRoot.createTemp('import_');
      jobFiles = filesDir;

      final result = await _convRepo.transaction(() async {
        // (注释已丢失)
        report(const ImportProgress(
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
            if (existing.deletedAt != null &&
                (resolution == ImportConflictResolution.merge ||
                    resolution == ImportConflictResolution.replace)) {
              throw ImportException('目标角色在回收站中，请先恢复角色或导入为新副本');
            }
            if (resolution == ImportConflictResolution.merge &&
                scopes.contains(SyncScope.characterSettings)) {
              throw ImportException('暂不支持合并基本偏好。请取消基本偏好，或选择新副本/替换；现有数据不会被修改。');
            }
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

          report(ImportProgress(
            ImportPhase.importing,
            progress,
            currentItem: conv['display_name'] as String?,
            message: '导入中 ${conv['display_name']}...',
          ));

          // (注释已丢失)
          String newConvId;
          final resolution = conflictResolutions[originalId];
          final messageIdMapping = <String, String>{};
          final blockIdMapping = <String, String>{};

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
                if (includeHistory &&
                    resolution == ImportConflictResolution.replace) {
                  final existingMsgs = await _msgRepo
                      .getAllByConversationOrderedStable(originalId);
                  await _blockRepo.deleteByMessages(
                    existingMsgs.map((m) => m.id).toList(growable: false),
                  );
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
          if (chatBackgroundFile != null) {
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
          } else if (scopes.contains(SyncScope.characterCards)) {
            await _mergeBasicCard(conv, newConvId, fileMapping);
          }
          importedConvIds.add(newConvId);

          // 导入消息
          final convMessages =
              msgList.where((m) => m['conversation_id'] == originalId).toList();

          // 获取已有消息 ID（用于合并模式去重）
          Set<String> existingMsgIds = {};
          Set<String> existingSourceMsgIds = {};
          if (resolution == ImportConflictResolution.merge) {
            final existingMsgs =
                await _msgRepo.getAllByConversationOrderedStable(newConvId);
            _validateMergeOrder(existingMsgs, convMessages);
            existingMsgIds = existingMsgs.map((m) => m.id).toSet();
            existingSourceMsgIds = {
              ...existingMsgIds,
              ...existingMsgs.map((m) => m.sourceMessageId).whereType<String>(),
            };
          }

          if (resolution == ImportConflictResolution.createNew) {
            for (final msg in convMessages) {
              final oldMsgId = msg['id'] as String;
              messageIdMapping[oldMsgId] = genId('msg');
              final blocks = msg['blocks'] as List<dynamic>? ?? const [];
              for (final block in blocks) {
                final oldBlockId = block['id'] as String?;
                if (oldBlockId == null || oldBlockId.isEmpty) continue;
                blockIdMapping[oldBlockId] = genId('blk');
              }
            }
          }

          for (final msg in convMessages) {
            final msgId = msg['id'] as String;
            final sourceMessageId = _sourceId(msg['source_message_id'], msgId);

            // 合并模式跳过已存在的消息
            if (resolution == ImportConflictResolution.merge &&
                (existingMsgIds.contains(msgId) ||
                    existingSourceMsgIds.contains(msgId) ||
                    existingSourceMsgIds.contains(sourceMessageId))) {
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
                  if (filePath != null &&
                      filePath.isNotEmpty &&
                      !filePath.startsWith('data:')) {
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

            await _importMessage(
              msg,
              newConvId,
              fileMapping,
              overrideMessageId: messageIdMapping[msgId],
              blockIdMapping: blockIdMapping,
            );
            existingMsgIds.add(messageIdMapping[msgId] ?? msgId);
            existingSourceMsgIds.add(sourceMessageId);
            messagesImported++;
          }

          if (!includeHistory) continue;
          final lastMessage = await _msgRepo.getLastMessageStable(newConvId);
          if (lastMessage == null) {
            await _convRepo.clearSummary(
              newConvId,
              DateTime.now().millisecondsSinceEpoch,
            );
          } else {
            await _convRepo.updateSummary(
              newConvId,
              lastMessage.content,
              lastMessage.createdAt,
            );
          }
        }

        return ImportResult(
          conversationIds: importedConvIds,
          messagesImported: messagesImported,
          filesImported: filesImported,
          skipped: skipped,
          conflicts: [],
        );
      });
      committed = result.conflicts.isEmpty;
      if (committed) {
        report(const ImportProgress(ImportPhase.done, 1.0, message: '导入完成'));
      }
      return result;
    } finally {
      // 独立任务目录：回滚只删除本次附件，不触碰旧角色的文件。
      if (!committed && jobFiles != null) await _cleanupDirectory(jobFiles);
      await _cleanupDirectory(importDir);
    }
  }

  /// (注释已丢失)
  Future<Directory> _extractToTempDir(File file, String? password) async {
    const maxArchiveBytes = 256 * 1024 * 1024;
    const maxExpandedBytes = 512 * 1024 * 1024;
    if (await file.length() > maxArchiveBytes) {
      throw ImportException('备份文件超过 256 MiB，请拆分后导入');
    }
    final bytes = await file.readAsBytes();
    if (bytes.length > maxArchiveBytes) throw ImportException('备份文件过大');
    // 先读目录和本地文件头，禁止在大小/路径预检之前启用 CRC 解压校验。
    final zipDirectory = ZipDirectory.read(InputStream(bytes));
    if (zipDirectory.fileHeaders.length > 10000) {
      throw ImportException('备份文件数量超过 10000');
    }
    final encrypted =
        zipDirectory.fileHeaders.any((h) => (h.file!.flags & 0x1) != 0);
    if (encrypted && (password == null || password.isEmpty)) {
      throw BackupPasswordRequiredException('该备份已加密，请输入密码');
    }
    final tempDir = await _temporaryDirectoryResolver();
    final importDir = await tempDir.createTemp('import_');
    try {
      final paths = <String>{};
      var expanded = 0;
      // 使用原始目录而非 Archive（会合并同名条目），才能发现重复名称。
      for (final header in zipDirectory.fileHeaders) {
        final local = header.file!;
        final path = safeArchivePath(importDir, header.filename);
        final size = local.uncompressedSize ?? -1;
        if (header.filename != local.filename ||
            ((header.externalFileAttributes ?? 0) >> 16 & 0xF000) == 0xA000 ||
            !paths.add(path.toLowerCase())) {
          throw ImportException('备份含链接、重复路径或不一致的文件头');
        }
        expanded += size;
        if (size < 0 ||
            size != header.uncompressedSize ||
            expanded > maxExpandedBytes) {
          throw ImportException('备份解压大小不一致或超过 512 MiB，请拆分后导入');
        }
      }
      final Archive archive;
      try {
        archive = ZipDecoder().decodeBytes(
          bytes,
          verify: true,
          password: encrypted ? password : null,
        );
      } on ArchiveException {
        rethrow;
      } catch (_) {
        // archive 对 AES 密码校验失败只抛普通 Exception。
        if (!encrypted) rethrow;
        throw BackupPasswordRequiredException('密码错误，请重新输入');
      }
      var written = 0;
      for (final item in archive) {
        final path = safeArchivePath(importDir, item.name);
        if (item.isFile) {
          final content = item.content as List<int>;
          written += content.length;
          if (written > maxExpandedBytes || content.length != item.size) {
            throw ImportException('备份文件大小不一致或超限');
          }
          final output = File(path);
          await output.create(recursive: true);
          await output.writeAsBytes(content);
        } else {
          await Directory(path).create(recursive: true);
        }
      }
      return importDir;
    } catch (_) {
      await _cleanupDirectory(importDir);
      rethrow;
    }
  }

  /// (注释已丢失)
  Future<String?> _copyImportedFile(
    Directory importDir,
    String relativePath,
    Directory targetDir,
    String baseName,
  ) async {
    if (relativePath.startsWith('https://') ||
        relativePath.startsWith('http://') ||
        relativePath.startsWith('assets/')) {
      return null;
    }
    final path = safeArchivePath(importDir, relativePath);
    if (!relativePath.replaceAll('\\', '/').startsWith('files/')) {
      throw ImportException('附件引用必须位于备份的 files 目录');
    }
    final sourceFile = File(path);
    if (await FileSystemEntity.type(path, followLinks: false) !=
            FileSystemEntityType.file ||
        !p.isWithin(await importDir.resolveSymbolicLinks(),
            await sourceFile.resolveSymbolicLinks())) {
      throw ImportException('备份附件缺失或路径不安全');
    }
    final ext = p.extension(relativePath);
    final targetPath = p.join(targetDir.path, '${genId('file')}$ext');
    await sourceFile.copy(targetPath);

    return targetPath;
  }

  static Future<void> _cleanupDirectory(Directory directory) async {
    try {
      if (await directory.exists()) await directory.delete(recursive: true);
    } on FileSystemException {
      // 清理失败最多留下独立任务的孤立文件，不能遮盖原异常或已提交的结果。
    }
  }

  Future<List<dynamic>> _readRecords(
      Directory directory, String name, String key) async {
    final file = File(p.join(directory.path, name));
    if (!await file.exists()) throw ImportException('无效备份：缺少 $name');
    dynamic decoded;
    try {
      decoded = jsonDecode(await file.readAsString());
    } on FormatException {
      throw ImportException('备份文件 $name 格式损坏');
    }
    if (decoded is! Map || decoded[key] is! List) {
      throw ImportException('备份文件 $name 数据结构无效');
    }
    return decoded[key] as List<dynamic>;
  }

  /// 统计字段可缺省，但明确声明的数量不能与内容矛盾。
  /// 基础归属检查覆盖整个聊天索引；具体块字段仍只校验选中的角色。
  static void _validateArchiveIndex(Map<String, dynamic> manifest,
      List<dynamic> conversations, List<dynamic>? messages) {
    void count(String key, int actual) {
      final expected = manifest[key];
      if (expected != null &&
          (expected is! int || expected < 0 || expected != actual)) {
        throw ImportException('备份声明的记录数量与实际内容不一致，已取消导入');
      }
    }

    // SQLite 可存的整数范围大于 Dart DateTime；落库成功不等于能显示。
    void timestamp(dynamic record, String field) {
      final value = record[field];
      if (value != null &&
          (value is! int ||
              value < -8640000000000000 ||
              value > 8640000000000000)) {
        throw ImportException('备份时间字段 $field 无效，已取消导入');
      }
    }

    count('conversation_count', conversations.length);
    final owners = <String>{};
    for (final record in conversations) {
      final id = record is Map ? record['id'] : null;
      if (!_validArchiveId(id) || !owners.add(id)) {
        throw ImportException('备份角色标识无效或重复');
      }
      timestamp(record, 'created_at');
      timestamp(record, 'updated_at');
    }
    if (messages == null) return;
    count('message_count', messages.length);
    final ids = <String>{};
    for (final record in messages) {
      final id = record is Map ? record['id'] : null;
      final owner = record is Map ? record['conversation_id'] : null;
      if (!_validArchiveId(id) || !ids.add(id)) {
        throw ImportException('备份消息标识无效或重复');
      }
      if (owner is! String || !owners.contains(owner)) {
        throw ImportException('备份包含无法归属到角色的聊天记录，已取消导入');
      }
      _sourceId(record['source_message_id'], id);
      timestamp(record, 'created_at');
    }
  }

  // SQLite 绑定采用 UTF-8；孤立 UTF-16 代理项会被替换，导致不同 ID 合并。
  // 只接受可无损往返的标识，不能自动替换后继续导入。
  static bool _validArchiveId(dynamic id) =>
      id is String &&
      id.trim().isNotEmpty &&
      id.length <= 512 &&
      utf8.decode(utf8.encode(id)) == id;

  static String _sourceId(dynamic source, String fallback) {
    // 可选来源缺省/空白意味着未知，不能把所有新消息都归到同一个空去重键。
    if (source == null || (source is String && source.trim().isEmpty)) {
      return fallback;
    }
    if (!_validArchiveId(source)) throw ImportException('备份来源标识无效');
    return source as String;
  }

  static void _validateMessageIds(List<dynamic> messages) {
    final messageIds = <String>{};
    final blockIds = <String>{};
    bool addId(Set<String> ids, dynamic id) =>
        _validArchiveId(id) && ids.add(id);
    for (final msg in messages) {
      if (!addId(messageIds, msg['id'])) throw ImportException('消息 ID 无效或重复');
      for (final block in msg['blocks'] as List<dynamic>? ?? const []) {
        if (!addId(blockIds, block['id'])) throw ImportException('附件 ID 无效或重复');
        _sourceId(block['source_block_id'], block['id']);
      }
    }
  }

  /// 同毫秒的稳定顺序由 SQLite 插入次序决定；不能靠追加修复中间缺口。
  /// 不重排本地 rowid、不篡改时间；检测到已知矛盾时由副本导入保留包内顺序。
  static void _validateMergeOrder(
      List<Message> existing, List<dynamic> incoming) {
    final byIdentity = <String, int>{};
    for (var i = 0; i < existing.length; i++) {
      byIdentity[existing[i].id] = i;
      final source = existing[i].sourceMessageId;
      if (source != null && source.trim().isNotEmpty) byIdentity[source] = i;
    }
    final pendingTimes = <int>{};
    final lastExistingIndex = <int, int>{};
    for (final message in incoming) {
      final time = message['created_at'] as int?;
      final id = message['id'] as String;
      final index = byIdentity[id] ??
          byIdentity[_sourceId(message['source_message_id'], id)];
      if (time == null) continue; // 旧包未知时间不猜测相对位置。
      if (index == null) {
        pendingTimes.add(time);
      } else if (existing[index].createdAt == time) {
        if (pendingTimes.contains(time) ||
            index < (lastExistingIndex[time] ?? -1)) {
          throw ImportException('备份与本地的同毫秒消息顺序无法安全合并，请导入为新副本');
        }
        lastExistingIndex[time] = index;
      }
    }
  }

  /// 只更新本次明确选择且包中实际存在的基本卡片字段。
  /// 音色/插件绑定和角色设置仍留给各自的迁移流程，不能借卡片合并覆盖。
  Future<void> _mergeBasicCard(Map<String, dynamic> card, String id,
      Map<String, String> fileMapping) async {
    final existing = (await _convRepo.getById(id))!;
    Value<String?> optional(String key) => card.containsKey(key)
        ? Value(fileMapping[card[key]] ?? card[key] as String?)
        : const Value.absent();
    await _convRepo.upsert(ConversationsCompanion.insert(
      id: id,
      title: card['title'] as String? ?? existing.title,
      displayName: card['display_name'] as String? ?? existing.displayName,
      createdAt: existing.createdAt,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      avatarUrl: optional('avatar_file'),
      characterImage: optional('character_image_file'),
      personaPrompt: card.containsKey('persona_prompt')
          ? Value(card['persona_prompt'] as String? ?? '')
          : const Value.absent(),
      selfAddress: optional('self_address'),
      addressUser: optional('address_user'),
    ));
  }

  /// 导入会话
  Future<void> _importConversation(
    Map<String, dynamic> conv,
    String newId,
    Map<String, String> fileMapping,
  ) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final avatarUrl =
        fileMapping[conv['avatar_file']] ?? conv['avatar_file'] as String?;
    final characterImage = fileMapping[conv['character_image_file']] ??
        conv['character_image_file'] as String?;

    await _convRepo.upsert(ConversationsCompanion.insert(
      id: newId,
      title: conv['title'] as String? ?? conv['display_name'] as String? ?? '',
      displayName: conv['display_name'] as String? ?? '',
      avatarUrl: Value(avatarUrl),
      characterImage: Value(characterImage),
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
      isHidden: Value(conv['is_hidden'] as bool? ?? false),
      isFavorite: Value(conv['is_favorite'] as bool? ?? false),
      isMuted: Value(conv['is_muted'] as bool? ?? false),
      notificationSound: Value(conv['notification_sound'] as bool? ?? true),
    ));

    // 模糊背景属于可重建缓存，不在原子导入事务中触发平台/图像异步任务。
  }

  /// 先校验本轮覆盖的主要聊天块，不能等读取端吞掉解码错误后才发现丢内容。
  /// 只接受可读取的既有领域类型，不执行工具或代码。
  void _validateReadableChatBlock(String type, Map<String, dynamic> data) {
    if (type == 'unknown') return; // 原生初始化占位块没有待还原的业务内容。
    if (!const {
      'mainText',
      'thinking',
      'image',
      'audio',
      'file',
      'emoji',
      'tool',
      'code',
      'error'
    }.contains(type)) {
      throw ImportException('当前版本无法读取该聊天内容类型，已取消整批导入');
    }
    const failure = '聊天内容块损坏或当前版本无法读取，已取消整批导入';
    if (type == 'image' &&
        !['localPath', 'url', 'base64'].any((key) =>
            data[key] is String && (data[key] as String).trim().isNotEmpty)) {
      throw ImportException(failure);
    }
    if (type == 'audio') {
      final url = data['url'];
      if (url is! String ||
          (url.trim().isEmpty && data['status'] == 'success')) {
        throw ImportException(failure);
      }
      final duration = data['durationSeconds'];
      if (duration != null) {
        if (duration is! num || !duration.isFinite || duration < 0) {
          throw ImportException(failure);
        }
        data['durationSeconds'] = duration.toDouble();
      }
    }
    if (type == 'file' || type == 'emoji') {
      final path = data[type == 'file' ? 'filePath' : 'path'];
      if (path is! String ||
          (path.trim().isEmpty && data['status'] == 'success')) {
        throw ImportException(failure);
      }
      if (type == 'file' &&
          (data['fileSize'] is! int || (data['fileSize'] as int) < 0)) {
        throw ImportException(failure);
      }
    }
    try {
      // 与实际聊天读取用相同领域解码器；不触发图片解码、播放或网络请求。
      domain.MessageBlock.fromJson(data);
    } catch (_) {
      throw ImportException(failure);
    }
  }

  /// 导入消息
  Future<void> _importMessage(
    Map<String, dynamic> msg,
    String convId,
    Map<String, String> fileMapping, {
    String? overrideMessageId,
    Map<String, String> blockIdMapping = const {},
  }) async {
    final originalMsgId = msg['id'] as String;
    final msgId = overrideMessageId ?? originalMsgId;
    final nowMs = DateTime.now().millisecondsSinceEpoch;

    if (await _msgRepo.getById(msgId) != null) {
      throw ImportException('消息 ID 与本地记录冲突；已取消整批导入，请选择新建副本');
    }
    await _msgRepo.upsert(MessagesCompanion.insert(
      id: msgId,
      conversationId: convId,
      role: msg['role'] as String? ?? 'user',
      content: msg['content'] as String? ?? '',
      status: Value(msg['status'] as String? ?? 'sent'),
      createdAt: msg['created_at'] as int? ?? nowMs,
      sourceMessageId:
          Value(_sourceId(msg['source_message_id'], originalMsgId)),
    ));

    // 导入 blocks
    final blocks = msg['blocks'] as List<dynamic>?;
    if (blocks != null) {
      for (var i = 0; i < blocks.length; i++) {
        final block = blocks[i];
        final blockId =
            blockIdMapping[block['id'] as String?] ?? block['id'] as String;
        final data = block['data'] as Map<String, dynamic>?;
        final declaredType =
            block['type'] as String? ?? data?['type'] as String? ?? 'unknown';
        final type = declaredType == 'text' ? 'mainText' : declaredType;
        final status = block['status'] as String? ??
            data?['status'] as String? ??
            'success';
        final innerType = data?['type'];
        if (innerType != null &&
            (innerType == 'text' ? 'mainText' : innerType) != type) {
          throw ImportException('聊天内容块的内外类型不一致，已取消整批导入');
        }
        // v1 旧包可只在外层提供身份字段；内层身份始终归属于实际目标行。
        final updatedData = <String, dynamic>{
          ...?data,
          'id': blockId,
          'messageId': msgId,
          'type': type,
          'status': status,
        };
        for (final key in ['localPath', 'url', 'filePath', 'path']) {
          if (updatedData[key] != null &&
              fileMapping.containsKey(updatedData[key])) {
            updatedData[key] = fileMapping[updatedData[key]];
          }
        }
        _validateReadableChatBlock(type, updatedData);

        if (await _blockRepo.getById(blockId) != null) {
          throw ImportException('附件 ID 与本地记录冲突；已取消整批导入，请选择新建副本');
        }
        await _blockRepo.upsert(MessageBlocksCompanion.insert(
          id: blockId,
          messageId: msgId,
          sourceBlockId:
              Value(_sourceId(block['source_block_id'], block['id'] as String)),
          type: type,
          status: Value(status),
          sortOrder: Value(block['sort_order'] as int? ?? i),
          data: jsonEncode(updatedData),
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

/// 备份已加密但未提供密码或密码错误；界面据此弹出密码输入框。
class BackupPasswordRequiredException extends ImportException {
  BackupPasswordRequiredException(super.message);
}
