import '../../../core/sync/cloud_local_write.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../../core/utils/token_estimator.dart';
import '../domain/contact_memory_port.dart';

/// Markdown 是新模式的唯一记忆真相源；不双写旧 Memories 表，不触发 Embedding。
/// 根目录由应用注入。目录名哈希化，角色改名、同名、路径字符均不改变隔离边界。
class MarkdownContactMemoryStore implements ContactMemoryPort {
  MarkdownContactMemoryStore(this._root);
  final Future<Directory> Function() _root;
  static final Map<String, Future<void>> _writes = {};
  static const _maxBytes = 8 * 1024 * 1024;
  static const _coreStart = '<!-- aicove-core -->\n';
  static const _coreEnd = '\n<!-- /aicove-core -->';
  static const _eventEnd = '\n<!-- /aicove-event -->';

  Future<File> _file(String ownerId) async {
    if (ownerId.trim().isEmpty || ownerId.length > 512) {
      throw ArgumentError.value(ownerId, 'ownerId');
    }
    final root = await _root();
    final directory = Directory(
      p.join(
        root.absolute.path,
        sha256.convert(utf8.encode(ownerId)).toString(),
      ),
    );
    if (await FileSystemEntity.type(directory.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const FileSystemException('记忆目录不能是符号链接');
    }
    final file = File(p.join(directory.path, 'MEMORY.md'));
    if (await FileSystemEntity.type(file.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const FileSystemException('记忆文档不能是符号链接');
    }
    return file;
  }

  @override
  Future<ContactMemoryNotebook> load(String ownerId) async {
    final file = await _file(ownerId);
    if (!await file.exists()) return ContactMemoryNotebook(ownerId: ownerId);
    if (await file.length() > _maxBytes) {
      throw const FormatException('记忆文档过大，请先导出整理');
    }
    final text = await file.readAsString();
    return _decode(ownerId, text);
  }

  @override
  Future<ContactMemoryNotebook> save(ContactMemoryNotebook notebook) async {
    final file = await _file(notebook.ownerId);
    final text = _encode(notebook);
    final previous = _writes[file.path] ?? Future<void>.value();
    final operation = previous
        .catchError((Object _) {})
        .then(
          (_) => cloudLocalWrite(() async {
            await file.parent.create(recursive: true);
            final lockFile = File(p.join(file.parent.path, '.write.lock'));
            if (await FileSystemEntity.type(
                  lockFile.path,
                  followLinks: false,
                ) ==
                FileSystemEntityType.link) {
              throw const FileSystemException('记忆锁不能是符号链接');
            }
            final lock = await lockFile.open(mode: FileMode.append);
            File? temporary;
            try {
              await lock.lock(FileLock.exclusive);
              final current = await load(notebook.ownerId);
              if (current.revision != notebook.revision) {
                throw const ContactMemoryConflict();
              }
              temporary = File('${file.path}.${const Uuid().v4()}.tmp');
              await temporary.writeAsString(text, flush: true);
              await cloudLocalWrite(() => temporary!.rename(file.path));
            } finally {
              await lock.close();
              if (temporary != null && await temporary.exists()) {
                await temporary.delete();
              }
            }
          }),
        );
    // 完成信号不传播错误，实际调用方仍通过 operation 收到错误。
    final done = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    _writes[file.path] = done;
    try {
      await operation;
      return _decode(notebook.ownerId, text);
    } finally {
      if (identical(_writes[file.path], done)) _writes.remove(file.path);
    }
  }

  String _encode(ContactMemoryNotebook notebook) {
    _validateText(notebook.core);
    if (estimateTokenCount(notebook.core) > 2000) {
      throw const FormatException('常驻记忆超过约 2000 tokens，请把事件细节移到往事');
    }
    final ids = <String>{};
    final buffer = StringBuffer(
      '<!-- aicove-notebook ${jsonEncode({'version': 1, 'ownerId': notebook.ownerId, 'enabled': notebook.enabled, if (notebook.appliedCompactions.isNotEmpty) 'appliedCompactions': notebook.appliedCompactions})} -->\n\n',
    );
    buffer.write('# 常驻记忆\n$_coreStart${notebook.core}$_coreEnd\n\n# 往事\n');
    for (final event in notebook.events) {
      if (!RegExp(r'^[a-zA-Z0-9_-]{1,80}$').hasMatch(event.id) ||
          !ids.add(event.id)) {
        throw const FormatException('事件 ID 非法或重复');
      }
      if (event.title.trim().isEmpty ||
          event.title.length > 120 ||
          event.title.contains('\n')) {
        throw const FormatException('事件标题须为 1–120 字的单行文字');
      }
      _validateText(event.title);
      _validateText(event.body);
      if (event.body.trim().isEmpty || event.body.length > 20000) {
        throw const FormatException('事件正文须为 1–20000 字');
      }
      buffer.write(
        '\n<!-- aicove-event ${jsonEncode({'id': event.id, 'title': event.title, 'occurredAt': event.occurredAt.toIso8601String(), if (event.generatedKey != null) 'generatedKey': event.generatedKey, if (event.generatedDigest != null) 'generatedDigest': event.generatedDigest, if (event.memoryKind != null) 'memoryKind': event.memoryKind})} -->\n${event.body}$_eventEnd\n',
      );
    }
    final text = buffer.toString();
    if (utf8.encode(text).length > _maxBytes) {
      throw const FormatException('记忆文档过大，请先导出整理');
    }
    return text;
  }

  void _validateText(String value) {
    if (value.contains('<!-- aicove-') || value.contains('<!-- /aicove-')) {
      throw const FormatException('正文不能包含保留的记忆结构标记');
    }
  }

  ContactMemoryNotebook _decode(String ownerId, String text) {
    try {
      final header = RegExp(
        r'^<!-- aicove-notebook (.+) -->\n',
      ).firstMatch(text);
      if (header == null) throw const FormatException('缺少文档头');
      final meta = jsonDecode(header.group(1)!) as Map<String, dynamic>;
      if (meta['version'] != 1 ||
          meta['ownerId'] != ownerId ||
          meta['enabled'] is! bool) {
        throw const FormatException('记忆版本或所属角色不匹配');
      }
      final start = text.indexOf(_coreStart, header.end);
      final end = text.indexOf(_coreEnd, start + _coreStart.length);
      if (start < 0 || end < start) throw const FormatException('常驻记忆结构损坏');
      final core = text.substring(start + _coreStart.length, end);
      final events = <ContactMemoryEvent>[];
      var cursor = end + _coreEnd.length;
      final pattern = RegExp(r'<!-- aicove-event (.+) -->\n');
      for (final match in pattern.allMatches(text, cursor)) {
        if (match.start < cursor) throw const FormatException('事件嵌套');
        final eventEnd = text.indexOf(_eventEnd, match.end);
        if (eventEnd < 0) throw const FormatException('事件结构损坏');
        final info = jsonDecode(match.group(1)!) as Map<String, dynamic>;
        events.add(
          ContactMemoryEvent(
            id: info['id'] as String,
            title: info['title'] as String,
            occurredAt: DateTime.parse(info['occurredAt'] as String),
            body: text.substring(match.end, eventEnd),
            generatedKey: info['generatedKey'] as String?,
            generatedDigest: info['generatedDigest'] as String?,
            memoryKind: info['memoryKind'] as String?,
          ),
        );
        cursor = eventEnd + _eventEnd.length;
      }
      final notebook = ContactMemoryNotebook(
        ownerId: ownerId,
        revision: sha256.convert(utf8.encode(text)).toString(),
        enabled: meta['enabled'] as bool,
        appliedCompactions: (meta['appliedCompactions'] as List? ?? const [])
            .cast<String>(),
        core: core,
        events: events,
      );
      // 不接受被部分解析而悄悄丢失的内容。手工编辑保留结构即可。
      if (_encode(notebook).trim() != text.trim()) {
        throw const FormatException('记忆结构被修改，请保留文档标记');
      }
      return notebook;
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('记忆文档损坏');
    }
  }
}
