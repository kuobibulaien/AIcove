import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'sticker_registry.dart';

/// 表情包套组（对应 Telegram/Signal 的 sticker pack）。
class StickerPack {
  const StickerPack({
    required this.id,
    required this.name,
    required this.stickers,
    this.enabled = true,
    this.author = '',
  });

  final String id;
  final String name;
  final bool enabled;

  /// 原作者（来源公众号等），空表示未知。
  final String author;

  final List<Sticker> stickers;

  int get untaggedCount => stickers.where((s) => s.tags.isEmpty).length;

  StickerPack copyWith({String? name, bool? enabled, List<Sticker>? stickers}) =>
      StickerPack(
        id: id,
        name: name ?? this.name,
        enabled: enabled ?? this.enabled,
        stickers: stickers ?? this.stickers,
        author: author,
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

/// 待导入的一张图片。[tags] 为空时从文件名推出标签与描述。
class StickerImportFile {
  const StickerImportFile(this.name, this.bytes, {this.tags, this.description});
  final String name;
  final Uint8List bytes;
  final List<String>? tags;
  final String? description;
}

/// 套组文件夹里的标注清单：
/// `{"name": 套组名, "author": 原作者, "stickers": {文件名: {"tags", "description"}}}`。
const String stickerLabelsFileName = 'labels.json';

/// 随应用内置的套组：`assets/stickers/builtin/index.json` 列出子目录，
/// 每个子目录是一个套组，带 [stickerLabelsFileName]。
const String builtinStickerRoot = 'assets/stickers/builtin';

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
    try {
      await library.seedBuiltin(rootBundle);
    } catch (error) {
      debugPrint('[StickerLibrary] 内置表情导入失败：$error');
    }
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

  /// 内置套组已导入过：之后用户删改都不再重新放回。
  bool _builtinSeeded = false;

  File get _manifest => File(p.join(root.path, 'library.json'));
  Directory get _files => Directory(p.join(root.path, 'files'));

  String _absolute(String file) => p.join(_files.path, file);

  Future<void> load() async {
    Map<String, dynamic> json = const {};
    if (await _manifest.exists()) {
      try {
        json = jsonDecode(await _manifest.readAsString()) as Map<String, dynamic>;
      } on FormatException {
        // 清单损坏时不覆盖原文件，保留现场；界面显示空库，也不自动导入内置套组。
        _packs = const [];
        _builtinSeeded = true;
        _publish();
        return;
      }
    }
    _usedIds = {...?(json['usedIds'] as List?)?.cast<String>()};
    _builtinSeeded = json['builtinSeeded'] as bool? ?? false;
    final packs = <StickerPack>[];
    for (final raw in (json['packs'] as List? ?? const [])) {
      final pack = raw as Map<String, dynamic>;
      // 旧版清单里的内置套组已移除，遇到直接忽略
      if (pack['builtin'] == true) continue;
      final id = pack['id'] as String;
      packs.add(
        StickerPack(
          id: id,
          name: pack['name'] as String? ?? '未命名',
          enabled: pack['enabled'] as bool? ?? true,
          author: pack['author'] as String? ?? '',
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
    _packs = packs;
    _publish();
  }

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
      'builtinSeeded': _builtinSeeded,
      'packs': [
        for (final pack in _packs)
          {
            'id': pack.id,
            'name': pack.name,
            'enabled': pack.enabled,
            if (pack.author.isNotEmpty) 'author': pack.author,
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
    if (pack == null || trimmed.isEmpty) return;
    await _replacePack(pack.copyWith(name: trimmed));
  }

  Future<void> updateSticker(
    String stickerId, {
    List<String>? tags,
    String? description,
  }) async {
    for (final pack in _packs) {
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
    if (pack == null) return;
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
    if (pack == null) return;
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

  /// 记录表情已发出。
  Future<void> markUsed(String stickerId) async {
    if (_usedIds.contains(stickerId) ||
        !_packs.any((pack) => pack.stickers.any((s) => s.id == stickerId))) {
      return;
    }
    _usedIds = {..._usedIds, stickerId};
    await _save();
  }

  /// 导入一组图片。[packId] 为空时新建名为 [packName]、作者为 [author] 的套组。
  Future<StickerImportResult> importFiles(
    List<StickerImportFile> files, {
    String? packId,
    String packName = '我的表情',
    String author = '',
  }) async {
    final target = packId == null ? null : packById(packId);
    final pack =
        target ??
        StickerPack(
          id: const Uuid().v4(),
          name: packName,
          author: author,
          stickers: const [],
        );
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
      final parsed = file.tags == null
          ? stickerLabelFromFileName(file.name)
          : (
              description: file.description?.trim() ?? '',
              tags: normalizeStickerTags(file.tags!),
            );
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

  /// 首次加载时把内置套组导入成普通套组，用户可以照常改名、停用、删除。
  Future<void> seedBuiltin(AssetBundle bundle) async {
    if (_builtinSeeded) return;
    final index =
        jsonDecode(await bundle.loadString('$builtinStickerRoot/index.json'))
            as Map<String, dynamic>;
    for (final dir in (index['packs'] as List).cast<String>()) {
      final base = '$builtinStickerRoot/$dir';
      final labels =
          jsonDecode(await bundle.loadString('$base/$stickerLabelsFileName'))
              as Map<String, dynamic>;
      final files = <StickerImportFile>[];
      for (final name in (labels['stickers'] as Map).keys.cast<String>()) {
        final data = await bundle.load('$base/$name');
        files.add(StickerImportFile(name, data.buffer.asUint8List()));
      }
      await importFiles(
        applyStickerLabels(files, labels),
        packName: labels['name'] as String? ?? dir,
        author: labels['author'] as String? ?? '',
      );
    }
    _builtinSeeded = true;
    await _save();
  }

  /// 导入压缩包：每个一级文件夹成为一个套组；图片直接放在根目录时，
  /// 以压缩包名作为套组名。文件夹里有 [stickerLabelsFileName] 时按它标注。
  Future<StickerImportResult> importZip(Uint8List bytes, String zipName) async {
    final archive = ZipDecoder().decodeBytes(bytes);
    final groups = <String, List<StickerImportFile>>{};
    final labels = <String, Map<String, dynamic>>{};
    final fallbackName = p.basenameWithoutExtension(zipName).trim();
    for (final entry in archive) {
      if (!entry.isFile) continue;
      final parts = p.posix.split(entry.name.replaceAll('\\', '/'));
      if (parts.any((part) => part.startsWith('.') || part == '__MACOSX')) {
        continue;
      }
      final group = parts.length > 1 ? parts.first : fallbackName;
      if (parts.last == stickerLabelsFileName) {
        labels[group] =
            jsonDecode(utf8.decode(entry.content as List<int>))
                as Map<String, dynamic>;
        continue;
      }
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
      final groupLabels = labels[group.key];
      final result = await importFiles(
        groupLabels == null
            ? group.value
            : applyStickerLabels(group.value, groupLabels),
        packName: groupLabels?['name'] as String? ?? group.key,
        author: groupLabels?['author'] as String? ?? '',
      );
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

/// 按标注清单给图片带上标签与描述；清单里没有的图片仍按文件名推断。
List<StickerImportFile> applyStickerLabels(
  List<StickerImportFile> files,
  Map<String, dynamic> labels,
) {
  final entries = labels['stickers'] as Map? ?? const {};
  return [
    for (final file in files)
      if (entries[file.name] case final Map entry)
        StickerImportFile(
          file.name,
          file.bytes,
          tags: (entry['tags'] as List? ?? const []).cast<String>(),
          description: entry['description'] as String?,
        )
      else
        file,
  ];
}

/// 标签清洗：去空白、去掉会破坏 `<sticker tag="…"/>` 语法的符号、限制长度、去重。
List<String> normalizeStickerTags(Iterable<String> tags) {
  final result = <String>[];
  for (final raw in tags) {
    final tag = raw.replaceAll(RegExp(r'[<>"\[\]]'), '').trim();
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
