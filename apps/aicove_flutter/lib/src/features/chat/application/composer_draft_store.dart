/// 输入框草稿的本地存储：按会话读写 SharedPreferences、迁移旧 key，
/// 并把草稿里的图片附件复制到应用数据目录，避免临时文件被系统回收。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/services/attachment_picker_service.dart';
import 'chat_edit.dart';

@visibleForTesting
const String composerLegacyDraftStorageKey = 'composer_draft_text';

const String _kComposerDraftKeyPrefix = 'composer_draft_v2:';
const int _kComposerDraftVersion = 1;
const String _kComposerDraftMediaDirectoryName = 'composer_drafts';

@visibleForTesting
String composerDraftStorageKey(String conversationId) =>
    '$_kComposerDraftKeyPrefix$conversationId';

@visibleForTesting
SelectedAttachment? composerDecodeDraftAttachment(dynamic rawAttachment) {
  if (rawAttachment is! Map) return null;

  final attachmentMap = Map<String, dynamic>.from(
    rawAttachment.cast<String, dynamic>(),
  );
  final path = (attachmentMap['path'] as String?)?.trim();
  if (path == null || path.isEmpty) return null;

  final typeName = (attachmentMap['type'] as String?)?.trim();
  final attachmentType = AttachmentType.values
      .where((candidate) => candidate.name == typeName)
      .firstOrNull;
  if (attachmentType == null) return null;

  return SelectedAttachment(
    path: path,
    name: attachmentMap['name'] as String?,
    sizeBytes: attachmentMap['sizeBytes'] as int?,
    type: attachmentType,
  );
}

@visibleForTesting
Future<SelectedAttachment?> composerResolveRestorableDraftAttachment(
  SelectedAttachment? attachment,
) => ComposerDraftStore.resolveRestorableAttachment(attachment);

class ComposerDraftSnapshot {
  final String text;
  final SelectedAttachment? attachment;
  final ChatEditDraft? edit;
  final bool invalidEdit;

  const ComposerDraftSnapshot({
    required this.text,
    this.attachment,
    this.edit,
    this.invalidEdit = false,
  });

  bool get isEmpty =>
      text.isEmpty && attachment == null && edit == null && !invalidEdit;

  ComposerDraftSnapshot copyWith({
    String? text,
    SelectedAttachment? attachment,
  }) {
    return ComposerDraftSnapshot(
      text: text ?? this.text,
      attachment: attachment,
      edit: edit,
      invalidEdit: invalidEdit,
    );
  }

  String encode() {
    return jsonEncode(<String, Object?>{
      'version': _kComposerDraftVersion,
      'text': text,
      if (edit != null) 'edit': edit!.toJson(),
      if (invalidEdit) 'invalidEdit': true,
      if (attachment != null)
        'attachment': <String, Object?>{
          'path': attachment!.path,
          'name': attachment!.name,
          'sizeBytes': attachment!.sizeBytes,
          'type': attachment!.type.name,
        },
    });
  }

  static ComposerDraftSnapshot? fromStored(String rawValue) {
    if (rawValue.isEmpty) return null;
    try {
      final decoded = jsonDecode(rawValue);
      if (decoded is! Map) {
        return ComposerDraftSnapshot(text: rawValue);
      }
      final draftMap = Map<String, dynamic>.from(
        decoded.cast<String, dynamic>(),
      );
      final text = (draftMap['text'] as String?) ?? '';
      final attachment = composerDecodeDraftAttachment(draftMap['attachment']);
      ChatEditDraft? edit;
      var invalid = draftMap['invalidEdit'] == true;
      if (draftMap.containsKey('edit')) {
        try {
          edit = ChatEditDraft.fromJson(
            Map<String, dynamic>.from(draftMap['edit'] as Map),
          );
        } catch (_) {
          invalid = true;
        }
      }
      return ComposerDraftSnapshot(
        text: text,
        attachment: attachment,
        edit: edit,
        invalidEdit: invalid,
      );
    } catch (_) {
      // 结构化草稿损坏时禁止将原始JSON降级成普通聊天内容发送。
      return ComposerDraftSnapshot(
        text: rawValue,
        invalidEdit: rawValue.trimLeft().startsWith('{'),
      );
    }
  }
}

/// 草稿按会话 id 分 key 存储；没有会话时落到旧的全局 key。
class ComposerDraftStore {
  const ComposerDraftStore._();

  static String? normalizeScopeId(String? scopeId) {
    final normalized = scopeId?.trim();
    if (normalized == null || normalized.isEmpty) return null;
    return normalized;
  }

  static String storageKey(String? scopeId) {
    final normalizedScopeId = normalizeScopeId(scopeId);
    if (normalizedScopeId == null) {
      return composerLegacyDraftStorageKey;
    }
    return composerDraftStorageKey(normalizedScopeId);
  }

  /// 读取会话草稿；会话 key 为空时把旧全局草稿迁过来并删除旧 key。
  static Future<ComposerDraftSnapshot?> read({required String? scopeId}) async {
    final prefs = await SharedPreferences.getInstance();
    final draftKey = storageKey(scopeId);
    final scopedDraftRaw = prefs.getString(draftKey);
    if (scopedDraftRaw != null && scopedDraftRaw.isNotEmpty) {
      return ComposerDraftSnapshot.fromStored(scopedDraftRaw);
    }

    if (draftKey == composerLegacyDraftStorageKey) {
      return null;
    }

    final legacyDraft = prefs.getString(composerLegacyDraftStorageKey);
    if (legacyDraft == null || legacyDraft.isEmpty) {
      return null;
    }

    final snapshot = ComposerDraftSnapshot.fromStored(legacyDraft);
    if (snapshot == null) {
      await prefs.remove(composerLegacyDraftStorageKey);
      return null;
    }

    await prefs.setString(draftKey, snapshot.encode());
    await prefs.remove(composerLegacyDraftStorageKey);
    return snapshot;
  }

  /// 写入草稿；空草稿直接删除 key。返回底层存储是否成功。
  static Future<bool> write(
    String? scopeId,
    ComposerDraftSnapshot snapshot,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final draftKey = storageKey(scopeId);
    return snapshot.isEmpty
        ? prefs.remove(draftKey)
        : prefs.setString(draftKey, snapshot.encode());
  }

  static Future<bool> clear(String? scopeId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.remove(storageKey(scopeId));
  }

  /// 附件文件已不存在时返回 null，草稿恢复时据此丢弃失效附件。
  static Future<SelectedAttachment?> resolveRestorableAttachment(
    SelectedAttachment? attachment,
  ) async {
    if (attachment == null) return null;
    final path = attachment.path.trim();
    if (path.isEmpty) return null;
    try {
      final exists = await File(path).exists();
      if (!exists) return null;
      return attachment;
    } catch (_) {
      return null;
    }
  }

  /// 把图片附件复制进草稿目录，失败或非图片时原样返回。
  static Future<SelectedAttachment> stabilizeAttachment(
    SelectedAttachment attachment, {
    required String? scopeId,
  }) async {
    if (attachment.type != AttachmentType.image) {
      return attachment;
    }

    final sourcePath = attachment.path.trim();
    if (sourcePath.isEmpty) {
      return attachment;
    }

    final sourceFile = File(sourcePath);
    if (!await sourceFile.exists()) {
      return attachment;
    }

    final rootDirectory = await getApplicationSupportDirectory();
    final draftDirectory = Directory(
      p.join(rootDirectory.path, _kComposerDraftMediaDirectoryName),
    );
    if (!await draftDirectory.exists()) {
      await draftDirectory.create(recursive: true);
    }

    final normalizedSourcePath = p.normalize(sourceFile.path);
    final normalizedDraftRoot = p.normalize(draftDirectory.path);
    if (normalizedSourcePath == normalizedDraftRoot ||
        p.isWithin(normalizedDraftRoot, normalizedSourcePath)) {
      return attachment;
    }

    final normalizedScopeId = normalizeScopeId(scopeId) ?? 'global';
    final safeScopeId = normalizedScopeId.replaceAll(
      RegExp(r'[^a-zA-Z0-9_-]+'),
      '_',
    );
    final extension = p.extension(normalizedSourcePath);
    final targetPath = p.join(
      draftDirectory.path,
      'draft_${safeScopeId}_${DateTime.now().millisecondsSinceEpoch}'
      '${extension.isNotEmpty ? extension : '.jpg'}',
    );

    try {
      await sourceFile.copy(targetPath);
      return SelectedAttachment(
        path: targetPath,
        name: attachment.name,
        sizeBytes: attachment.sizeBytes,
        type: attachment.type,
      );
    } catch (_) {
      return attachment;
    }
  }
}
