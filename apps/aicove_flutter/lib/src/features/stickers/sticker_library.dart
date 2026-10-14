import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'builtin_stickers.dart';
import 'sticker_registry.dart';

/// 表情包套组（对应 Telegram/Signal 的 sticker pack）。
class StickerPack {
  const StickerPack({
    required this.id,
    required this.name,
    required this.stickers,
    this.enabled = true,
    this.builtin = false,
  });

  final String id;
  final String name;
  final bool enabled;

  /// 内置套组随应用打包：只能启停，不能改名、删除或编辑表情。
  final bool builtin;
  final List<Sticker> stickers;

  int get untaggedCount => stickers.where((s) => s.tags.isEmpty).length;

  StickerPack copyWith({String? name, bool? enabled, List<Sticker>? stickers}) =>
      StickerPack(
        id: id,
        name: name ?? this.name,
        enabled: enabled ?? this.enabled,
        builtin: builtin,
        stickers: stickers ?? this.stickers,
      );
}

/// 一次导入的结果，供界面提示。
class StickerImportResult {
  const StickerImportResult({
    required this.packIds,
    required this.added,
    required this.untagged,
    required this.skipped,
  });

  final List<String> packIds;
  final int added;

  /// 文件名无法推出标签的张数（不会被 AI 使用，需手动补标签）。
  final int untagged;

  /// 非图片、过大或同套组内重复而跳过的张数。
  final int skipped;
}

/// 待导入的一张图片。
class StickerImportFile {
  const StickerImportFile(this.name, this.bytes);
  final String name;
  final Uint8List bytes;
}

/// 用户表情包库：套组清单存在 `stickers/library.json`，图片按内容哈希存在
/// `stickers/files/`。不入数据库、不参与同步；已发出的表情由消息块引用文件，
/// 同步与备份沿用图片块的既有路径处理。
class StickerLibrary {
  StickerLibrary(this.root);

  final Directory root;
  static Future<StickerLibrary>? _shared;

  static Future<StickerLibrary> get shared => _shared ??= () async {
    final support = await getApplicationSupportDirectory();
    final library = StickerLibrary(Directory(p.join(support.path, 'stickers')));
    await library.load();
    return library;
  }();

  /// 读盘失败（如测试环境没有平台目录）时保留内置表情，不阻断聊天。
  static Future<void> ensureLoaded() async {
    try {
      await shared;
    } catch (error) {
      _shared = null;
      debugPrint('[StickerLibrary] 用户表情包库加载失败，仅使用内置表情：$error');
    }
  }

  static Future<void> markUsedIfLoaded(String stickerId) async {
    final library = _shared;
    if (library == null) return;
    try {
      await (await library).markUsed(stickerId);
    } catch (error) {
      debugPrint('[StickerLibrary] 记录表情使用失败：$error');
    }
  }

  /// 单张上限：表情包都是小图，过大多半是误选了照片。
  static const int maxFileBytes = 10 * 1024 * 1024;
  static const Set<String> _imageMimes = {
    'image/png',
    'image/jpeg',
    'image/gif',
    'image/webp',
  };

  List<StickerPack> _packs = const [];
  List<StickerPack> get packs => _packs;

  /// 发出过的用户表情 id：删除表情时保留其文件，历史消息仍能显示。
  Set<String> _usedIds = {};

  File get _manifest => File(p.join(root.path, 'library.json'));
  Directory get _files => Directory(p.join(root.path, 'files'));

  String _absolute(String file) => p.join(_files.path, file);

  Future<void> load() async {
    Map<String, dynamic> json = const {};
    if (await _manifest.exists()) {
      try {
        json = jsonDecode(await _manifest.readAsString()) as Map<String, dynamic>;
      } on FormatException {
        // 清单损坏时不覆盖原文件，保留现场；界面只显示内置套组。
        _packs = [_builtinPack(true)];
        _publish();
        return;
      }
    }
    _usedIds = {...?(json['usedIds'] as List?)?.cast<String>()};
    final packs = <StickerPack>[];
    var builtinEnabled = true;
    for (final raw in (json['packs'] as List? ?? const [])) {
      final pack = raw as Map<String, dynamic>;
      if (pack['builtin'] == true) {
        builtinEnabled = pack['enabled'] as bool? ?? true;
        continue;
      }
      final id = pack['id'] as String;
      packs.add(
        StickerPack(
          id: id,
          name: pack['name'] as String? ?? '未命名',
          enabled: pack['enabled'] as bool? ?? true,
          stickers: [
            for (final s in (pack['stickers'] as List? ?? const []))
              Sticker(
                id: s['id'] as String,
                packId: id,
                path: _absolute(s['file'] as String),
                tags: (s['tags'] as List? ?? const []).cast<String>(),
                description: s['description'] as String? ?? '',
              ),
          ],
        ),
      );
    }
    _packs = [_builtinPack(builtinEnabled), ...packs];
    _publish();
  }

  StickerPack _builtinPack(bool enabled) => StickerPack(
    id: builtinStickerPackId,
    name: builtinStickerPackName,
    enabled: enabled,
    builtin: true,
    stickers: builtinStickers,
  );

  /// 把已启用套组同步给 AI 使用的注册表。
  void _publish() {
    StickerRegistry.instance.replaceStickers([
      for (final pack in _packs)
        if (pack.enabled) ...pack.stickers,
    ]);
  }

  Future<void> _save() async {
    final json = {
      'version': 1,
      'usedIds': _usedIds.toList(),
      'packs': [
        for (final pack in _packs)
          if (pack.builtin)
            {'id': pack.id, 'builtin': true, 'enabled': pack.enabled}
          else
            {
              'id': pack.id,
              'name': pack.name,
              'enabled': pack.enabled,
              'stickers': [
                for (final s in pack.stickers)
                  {
                    'id': s.id,
                    'file': p.basename(s.path),
                    'tags': s.tags,
                    'description': s.description,
                  },
              ],
            },
      ],
    };
    await root.create(recursive: true);
    final temp = File('${_manifest.path}.tmp');
    await temp.writeAsString(jsonEncode(json), flush: true);
    await temp.rename(_manifest.path);
    _publish();
  }

  StickerPack? packById(String id) {
    for (final pack in _packs) {
      if (pack.id == id) return pack;
    }
    return null;
  }

  Future<void> _replacePack(StickerPack pack) async {
    _packs = [for (final old in _packs) old.id == pack.id ? pack : old];
    await _save();
  }

  Future<void> setPackEnabled(String packId, bool enabled) async {
    final pack = packById(packId);
    if (pack == null) return;
    await _replacePack(pack.copyWith(enabled: enabled));
  }

  Future<void> renamePack(String packId, String name) async {
    final pack = packById(packId);
    final trimmed = name.trim();
    if (pack == null || pack.builtin || trimmed.isEmpty) return;
    await _replacePack(pack.copyWith(name: trimmed));
  }

  Future<void> updateSticker(
    String stickerId, {
    List<String>? tags,
    String? description,
  }) async {
    for (final pack in _packs) {
      if (pack.builtin) continue;
      final index = pack.stickers.indexWhere((s) => s.id == stickerId);
      if (index < 0) continue;
      final old = pack.stickers[index];
      final updated = Sticker(
        id: old.id,
        packId: old.packId,
        path: old.path,
        tags: tags == null ? old.tags : normalizeStickerTags(tags),
        description: description?.trim() ?? old.description,
      );
      await _replacePack(
        pack.copyWith(stickers: [...pack.stickers]..[index] = updated),
      );
      return;
    }
  }

  Future<void> deleteStickers(String packId, Set<String> stickerIds) async {
    final pack = packById(packId);
    if (pack == null || pack.builtin) return;
    final removed = pack.stickers.where((s) => stickerIds.contains(s.id));
    await _replacePack(
      pack.copyWith(
        stickers: [
          for (final s in pack.stickers)
            if (!stickerIds.contains(s.id)) s,
        ],
      ),
    );
    await _deleteOrphanFiles(removed);
  }

  Future<void> deletePack(String packId) async {
    final pack = packById(packId);
    if (pack == null || pack.builtin) return;
    _packs = [for (final old in _packs) if (old.id != packId) old];
    await _save();
    await _deleteOrphanFiles(pack.stickers);
  }

  /// 只删除没被发出过、也没被其他表情共用的文件。
  Future<void> _deleteOrphanFiles(Iterable<Sticker> removed) async {
    final inUse = {
      for (final pack in _packs)
        for (final s in pack.stickers) s.path,
    };
    for (final sticker in removed) {
      if (_usedIds.contains(sticker.id) || inUse.contains(sticker.path)) {
        continue;
      }
      final file = File(sticker.path);
      if (await file.exists()) await file.delete();
    }
  }

  /// 记录表情已发出；内置表情是资源文件，不需要记录。
  Future<void> markUsed(String stickerId) async {
    if (_usedIds.contains(stickerId) ||
        !_packs.any((pack) =>
            !pack.builtin && pack.stickers.any((s) => s.id == stickerId))) {
      return;
    }
    _usedIds = {..._usedIds, stickerId};
    await _save();
  }

  /// 导入一组图片。[packId] 为空时新建名为 [packName] 的套组。
  Future<StickerImportResult> importFiles(
    List<StickerImportFile> files, {
    String? packId,
    String packName = '我的表情',
  }) async {
    final target = packId == null ? null : packById(packId);
    if (target != null && target.builtin) {
      throw ArgumentError('内置套组不能添加表情');
    }
    final pack =
        target ??
        StickerPack(id: const Uuid().v4(), name: packName, stickers: const []);
    final stickers = [...pack.stickers];
    final existing = {for (final s in stickers) p.basename(s.path)};
    var added = 0, untagged = 0, skipped = 0;
    await _files.create(recursive: true);
    for (final file in files) {
      final mime = lookupMimeType(file.name, headerBytes: file.bytes);
      if (file.bytes.isEmpty ||
          file.bytes.length > maxFileBytes ||
          !_imageMimes.contains(mime)) {
        skipped++;
        continue;
      }
      final digest = sha256.convert(file.bytes).toString().substring(0, 32);
      final name = '$digest.${mime!.split('/').last}';
      if (!existing.add(name)) {
        skipped++;
        continue;
      }
      final stored = File(_absolute(name));
      if (!await stored.exists()) {
        final temp = File('${stored.path}.tmp');
        await temp.writeAsBytes(file.bytes, flush: true);
        await temp.rename(stored.path);
      }
      final parsed = stickerLabelFromFileName(file.name);
      if (parsed.tags.isEmpty) untagged++;
      stickers.add(
        Sticker(
          id: const Uuid().v4(),
          packId: pack.id,
          path: stored.path,
          tags: parsed.tags,
          description: parsed.description,
        ),
      );
      added++;
    }
    if (added > 0) {
      final updated = pack.copyWith(stickers: stickers);
      _packs = target == null
          ? [..._packs, updated]
          : [for (final old in _packs) old.id == pack.id ? updated : old];
      await _save();
    }
    return StickerImportResult(
      packIds: added > 0 ? [pack.id] : const [],
      added: added,
      untagged: untagged,
      skipped: skipped,
    );
  }

  /// 导入压缩包：每个一级文件夹成为一个套组；图片直接放在根目录时，
  /// 以压缩包名作为套组名。
  Future<StickerImportResult> importZip(Uint8List bytes, String zipName) async {
    final archive = ZipDecoder().decodeBytes(bytes);
    final groups = <String, List<StickerImportFile>>{};
    final fallbackName = p.basenameWithoutExtension(zipName).trim();
    for (final entry in archive) {
      if (!entry.isFile) continue;
      final parts = p.posix.split(entry.name.replaceAll('\\', '/'));
      if (parts.any((part) => part.startsWith('.') || part == '__MACOSX')) {
        continue;
      }
      final group = parts.length > 1 ? parts.first : fallbackName;
      groups
          .putIfAbsent(group.isEmpty ? '我的表情' : group, () => [])
          .add(
            StickerImportFile(
              parts.last,
              Uint8List.fromList(entry.content as List<int>),
            ),
          );
    }
    final packIds = <String>[];
    var added = 0, untagged = 0, skipped = 0;
    for (final group in groups.entries) {
      final result = await importFiles(group.value, packName: group.key);
      packIds.addAll(result.packIds);
      added += result.added;
      untagged += result.untagged;
      skipped += result.skipped;
    }
    return StickerImportResult(
      packIds: packIds,
      added: added,
      untagged: untagged,
      skipped: skipped,
    );
  }
}

/// 标签清洗：去空白、去掉会破坏 [标签] 语法的方括号、限制长度、去重。
List<String> normalizeStickerTags(Iterable<String> tags) {
  final result = <String>[];
  for (final raw in tags) {
    final tag = raw.replaceAll(RegExp(r'[\[\]]'), '').trim();
    if (tag.isEmpty || tag.length > 16 || result.contains(tag)) continue;
    result.add(tag);
  }
  return result;
}

/// 按逗号、顿号、空格等拆分用户输入的标签。
List<String> splitStickerTags(String input) =>
    normalizeStickerTags(input.split(RegExp(r'[,，、;；|#\s]+')));

final RegExp _genericFileName = RegExp(
  r'^(img|image|dsc|pic|photo|screenshot|mmexport|wx_camera|qq图片|微信图片|截图|屏幕截图|sticker|emoji)?[\d_\-. ]*$',
  caseSensitive: false,
);

/// 从文件名推出描述与标签（SillyTavern 式约定）：
/// `开心-2.png` → 开心；`猫猫 摇尾巴.gif` → 猫猫、摇尾巴；
/// `IMG_1234.jpg` 这类无意义名称不出标签，导入后标为「未标注」。
({String description, List<String> tags}) stickerLabelFromFileName(
  String fileName,
) {
  var base = p.basenameWithoutExtension(fileName).trim();
  base = base.replaceFirst(RegExp(r'[\s_\-.]*[(（]?\d+[)）]?$'), '').trim();
  if (base.isEmpty || _genericFileName.hasMatch(base)) {
    return (description: '', tags: const <String>[]);
  }
  final tags = normalizeStickerTags(base.split(RegExp(r'[,，、;；|#\s_\-.]+')));
  return (description: base, tags: tags);
}
