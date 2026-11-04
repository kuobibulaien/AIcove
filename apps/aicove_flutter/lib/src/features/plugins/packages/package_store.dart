import 'dart:async';
import 'dart:io';
import 'dart:io' as io show ZLibDecoder;
import 'dart:typed_data';

import 'package:archive/archive.dart' hide ZLibDecoder;
import 'package:path/path.dart' as p;

import 'aicove_package.dart';
import '../../../core/storage/app_data_directory.dart';

/// Installed declarative packages under `Documents/aicove/packages/<id>/`.
/// Local only: packages are not part of cloud or LAN sync in v1.
class PackageStore {
  PackageStore(this.root);

  final Directory root;

  static Future<PackageStore> defaultStore() async {
    final documents = await appDataDirectory();
    return PackageStore(
      Directory(p.join(documents.path, 'aicove', 'packages')),
    );
  }

  /// Legacy size constants retained for source compatibility.
  static const maxPackageBytes = 20 * 1024 * 1024;

  static const maxFileBytes = 8 * 1024 * 1024;


  static const maxArchiveBytes = 24 * 1024 * 1024;


  static const maxPackageFiles = 1000;

  /// Imports and deletes run one at a time per package root, so concurrent
  /// imports never share a staging folder or interleave a replacement.
  static final Map<String, Future<void>> _locks = {};

  /// Validates [files] as a whole package and installs it, replacing an
  /// installed package with the same id. Nothing is written when invalid.
  Future<AicovePackage> importFiles(Map<String, List<int>> files) async {
    _validateNames(files.keys);
    final cleaned = {
      for (final entry in files.entries)
        if (!_isIgnored(entry.key)) entry.key: entry.value,
    };
    final package = AicovePackage.parse(cleaned);
    return _serialized(() => _install(package, cleaned));
  }

  /// Imports a package folder; [directory] is the folder holding the
  /// manifest. Links inside it may only point inside it, so nothing outside
  /// the folder is read.
  Future<AicovePackage> importDirectory(Directory directory) async =>
      importFiles(await _readTree(directory));

  /// Imports whatever [path] names: a package folder, a zip, or a lone
  /// `SKILL.md`/manifest file standing for its folder. The path the user
  /// chose may itself be a link.
  Future<AicovePackage> importPath(String path) async =>
      switch (await FileSystemEntity.type(path)) {
        FileSystemEntityType.directory => importDirectory(
          Directory(await Directory(path).resolveSymbolicLinks()),
        ),
        FileSystemEntityType.file => importFile(File(path)),
        _ => throw PackageFormatException('找不到要安装的包：$path'),
      };

  /// A `SKILL.md` or manifest file imports its folder; any other file is
  /// read as a zip.
  Future<AicovePackage> importFile(File file) async {
    final name = p.basename(file.path);
    if (name == AicovePackage.manifestName || name == 'SKILL.md') {
      return importDirectory(
        Directory(await file.parent.resolveSymbolicLinks()),
      );
    }
    return importZip(await file.readAsBytes());
  }

  /// Imports a zip whose root, or single top-level folder, holds the
  /// manifest. Entries are checked on the raw directory (links, duplicates,
  /// encryption) before anything is inflated.
  Future<AicovePackage> importZip(List<int> bytes) async {
    final ZipDirectory directory;
    try {
      directory = ZipDirectory.read(InputStream(bytes));
    } on Object {
      throw const PackageFormatException('不是有效的 zip 文件');
    }
    final names = <String>{};
    final files = <String, List<int>>{};
    for (final header in directory.fileHeaders) {
      final name = header.filename;
      final path = name.endsWith('/')
          ? name.substring(0, name.length - 1)
          : name;
      _validateNames([path]);
      if (!names.add(AicovePackage.pathKey(path))) {
        throw PackageFormatException('包里有重名文件：$name');
      }
      final mode = (header.externalFileAttributes ?? 0) >> 16;
      if ((mode & 0xF000) == 0xA000) {
        throw PackageFormatException('包里不能有链接：$name');
      }
      if (_isIgnored(name)) continue;
      if (name.endsWith('/')) continue;
      final file = header.file;
      if (file == null) throw PackageFormatException('zip 条目损坏：$name');
      if (file.flags & 1 != 0) {
        throw PackageFormatException('不支持加密的 zip：$name');
      }
      final content = _inflate(file, name);
      files[name] = content;
    }
    final tops = {for (final path in files.keys) path.split('/').first};
    final nested =
        !files.containsKey(AicovePackage.manifestName) &&
        !files.containsKey('SKILL.md') &&
        tops.length == 1 &&
        files.keys.every((path) => path.contains('/'));
    return importFiles(
      nested
          ? {
              for (final entry in files.entries)
                entry.key.substring(entry.key.indexOf('/') + 1): entry.value,
            }
          : files,
    );
  }

  /// Installed packages, sorted by id. A folder that no longer parses is
  /// skipped rather than failing the whole list; a replacement interrupted
  /// after moving the old copy aside is rolled back first.
  Future<List<AicovePackage>> list() async {
    if (!await root.exists()) return const [];
    await _serialized(_recoverInterrupted);
    final packages = <AicovePackage>[];
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory || p.basename(entity.path).startsWith('.')) {
        continue;
      }
      try {
        packages.add(
          AicovePackage.parse(
            await _readTree(entity),
          ).installedAt(entity.absolute.path),
        );
      } on Object {
        continue;
      }
    }
    packages.sort((a, b) => a.id.compareTo(b.id));
    return packages;
  }

  Future<void> delete(String id) async {
    if (!AicovePackage.isValidId(id)) throw ArgumentError.value(id, 'id');
    await _serialized(() async {
      if (!await root.exists()) return;
      final directory = Directory(p.join(root.path, id));
      if (await directory.exists()) await directory.delete(recursive: true);
      // A replacement interrupted earlier may have left this package's copy
      // aside; drop it too so the next list does not bring it back.
      await for (final entity in root.list(followLinks: false)) {
        final match = _transient.firstMatch(p.basename(entity.path));
        if (entity is Directory && match != null && match[1] == id) {
          await entity.delete(recursive: true);
        }
      }
    });
  }

  Future<T> _serialized<T>(Future<T> Function() body) {
    final key = root.absolute.path;
    final previous = _locks[key] ?? Future<void>.value();
    final result = previous.then((_) => body());
    final done = result.then<void>((_) {}, onError: (_) {});
    _locks[key] = done;
    done.whenComplete(() {
      if (identical(_locks[key], done)) _locks.remove(key);
    });
    return result;
  }

  /// Writes to a fresh staging folder, moves the installed copy aside, moves
  /// the new copy in, then drops the old one. A failure puts the old copy
  /// back; a crash in between is undone by [_recoverInterrupted].
  Future<AicovePackage> _install(
    AicovePackage package,
    Map<String, List<int>> files,
  ) async {
    await root.create(recursive: true);
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final target = Directory(p.join(root.path, package.id));
    final staging = Directory(p.join(root.path, '.${package.id}.$stamp.new'));
    final backup = Directory(p.join(root.path, '.${package.id}.$stamp.old'));
    try {
      for (final entry in files.entries) {
        final file = File(p.joinAll([staging.path, ...entry.key.split('/')]));
        await file.parent.create(recursive: true);
        await file.writeAsBytes(entry.value, flush: true);
      }
      final hadOld = await target.exists();
      if (hadOld) await target.rename(backup.path);
      try {
        await staging.rename(target.path);
      } on Object {
        if (hadOld) await backup.rename(target.path);
        rethrow;
      }
      if (hadOld) await backup.delete(recursive: true);
      return package.installedAt(target.absolute.path);
    } finally {
      if (await staging.exists()) await staging.delete(recursive: true);
    }
  }

  /// Folders [_install] creates: `.<id>.<microseconds>.new|old`. Anything
  /// else in the root is left alone.
  static final _transient = RegExp(
    r'^\.([a-z0-9][a-z0-9_-]{0,39})\.(\d+)\.(new|old)$',
  );

  Future<void> _recoverInterrupted() async {
    await for (final entity in root.list(followLinks: false)) {
      final match = _transient.firstMatch(p.basename(entity.path));
      if (entity is! Directory || match == null) continue;
      final target = Directory(p.join(root.path, match[1]));
      if (match[3] == 'old' && !await target.exists()) {
        await entity.rename(target.path);
      } else {
        await entity.delete(recursive: true);
      }
    }
  }

  /// Reads a package folder. Links are followed only when their
  /// real target stays inside the folder; a link back to a folder already
  /// being walked is skipped so cycles cannot loop.
  static Future<Map<String, List<int>>> _readTree(
    Directory directory,
  ) async {
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const PackageFormatException('包目录不能是链接或普通文件');
    }
    final root = await directory.resolveSymbolicLinks();
    final files = <String, List<int>>{};
    Future<void> walk(String real, String prefix, Set<String> ancestors) async {
      await for (final entity in Directory(real).list(followLinks: false)) {
        final name = p.basename(entity.path);
        final relative = prefix.isEmpty ? name : '$prefix/$name';
        _validateNames([relative]);
        if (_isIgnored(relative)) continue;
        var target = entity;
        if (entity is Link) {
          final String resolved;
          try {
            resolved = await entity.resolveSymbolicLinks();
          } on FileSystemException {
            throw PackageFormatException('包里的链接指向不存在的位置：$relative');
          }
          if (!p.equals(root, resolved) && !p.isWithin(root, resolved)) {
            throw const FormatException('包内链接不能指向包目录外部');
          }
          target = switch (await FileSystemEntity.type(
            resolved,
            followLinks: false,
          )) {
            FileSystemEntityType.directory => Directory(resolved),
            FileSystemEntityType.file => File(resolved),
            _ => throw PackageFormatException('包里的链接目标无法读取：$relative'),
          };
        }
        if (target is Directory) {
          final next = await target.resolveSymbolicLinks();
          if (ancestors.contains(next)) continue;
          await walk(next, relative, {...ancestors, next});
          continue;
        }
        if (target is! File) continue;
        final content = await target.readAsBytes();
        files[relative] = content;
      }
    }

    await walk(root, '', {root});
    return files;
  }

  static List<int> _inflate(ZipFile file, String name) {
    final raw = file.rawContent?.toUint8List() ?? Uint8List(0);
    switch (file.compressionMethod) {
      case ZipFile.zipCompressionStore:
        return raw;
      case ZipFile.zipCompressionDeflate:
        return io.ZLibDecoder(raw: true).convert(raw);
      default:
        throw PackageFormatException('不支持的 zip 压缩方式：$name');
    }
  }

  static void _validateNames(Iterable<String> paths) {
    final names = <String>{};
    for (final path in paths) {
      if (!AicovePackage.isSafePath(path)) {
        throw PackageFormatException('包内路径不合法：$path');
      }
      if (!names.add(AicovePackage.pathKey(path))) {
        throw PackageFormatException('包里有重名文件：$path');
      }
    }
  }

  /// Only macOS metadata is omitted; hidden skill resources are retained.
  static bool _isIgnored(String path) => path
      .split('/')
      .any(
        (part) =>
            part == '.DS_Store' || part.startsWith('._') || part == '__MACOSX',
      );
}

