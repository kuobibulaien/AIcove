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

  /// Uncompressed size limit for one package. Checked while reading,
  /// before anything larger is loaded into memory.
  static const maxPackageBytes = 20 * 1024 * 1024;

  static const maxFileBytes = 8 * 1024 * 1024;

  /// Entry limit for one package.
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
    final budget = _Budget();
    for (final bytes in cleaned.values) {
      budget.add(bytes.length);
    }
    final package = AicovePackage.parse(cleaned);
    return _serialized(() => _install(package, cleaned));
  }

  /// Imports a package folder; [directory] is the folder holding the
  /// manifest. Links are rejected so nothing outside the folder is read.
  Future<AicovePackage> importDirectory(Directory directory) async =>
      importFiles(await _readTree(directory));

  /// Imports a zip whose root, or single top-level folder, holds the
  /// manifest. Entries are checked on the raw directory (links, duplicates,
  /// encryption) before anything is inflated, and inflating stops as soon as
  /// the real output passes the budget; declared sizes are never trusted.
  Future<AicovePackage> importZip(List<int> bytes) async {
    final ZipDirectory directory;
    try {
      directory = ZipDirectory.read(InputStream(bytes));
    } on Object {
      throw const PackageFormatException('不是有效的 zip 文件');
    }
    final budget = _Budget();
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
      final content = _inflate(
        file,
        name,
        budget.remainingBytes.clamp(0, maxFileBytes),
      );
      budget.add(content.length);
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

  /// Reads a bounded package folder; links are always rejected.
  static Future<Map<String, List<int>>> _readTree(
    Directory directory,
  ) async {
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const PackageFormatException('包目录不能是链接或普通文件');
    }
    final files = <String, List<int>>{};
    final budget = _Budget();
    await for (final entity in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      final relative = p
          .relative(entity.path, from: directory.path)
          .split(p.separator)
          .join('/');
      _validateNames([relative]);
      if (entity is Link) {
        throw PackageFormatException('包里不能有链接：$relative');
      }
      if (_isIgnored(relative) || entity is! File) continue;
      budget.checkNext(await entity.length());
      // A streaming cap also covers growth between stat and read.
      final sink = _CappedSink(
        budget.remainingBytes.clamp(0, maxFileBytes),
        const PackageFormatException('读取内容超过 20 MiB 总量或 8 MiB 单文件限制'),
      );
      await for (final chunk in entity.openRead()) {
        sink.add(chunk);
      }
      final content = sink.bytes.takeBytes();
      budget.add(content.length);
      files[relative] = content;
    }
    return files;
  }

  /// Inflates one zip entry, failing as soon as the output passes [limit].
  static List<int> _inflate(ZipFile file, String name, int limit) {
    final raw = file.rawContent?.toUint8List() ?? Uint8List(0);
    final tooBig = PackageFormatException(
      '解压内容超过 20 MiB 总量或 8 MiB 单文件限制（$name）',
    );
    switch (file.compressionMethod) {
      case ZipFile.zipCompressionStore:
        if (raw.length > limit) throw tooBig;
        return raw;
      case ZipFile.zipCompressionDeflate:
        final out = _CappedSink(limit, tooBig);
        final sink = io.ZLibDecoder(raw: true).startChunkedConversion(out);
        const chunk = 64 * 1024;
        for (var i = 0; i < raw.length; i += chunk) {
          sink.add(
            raw.sublist(i, i + chunk > raw.length ? raw.length : i + chunk),
          );
        }
        sink.close();
        return out.bytes.takeBytes();
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

class _CappedSink implements Sink<List<int>> {
  _CappedSink(this.limit, this.error);

  final int limit;
  final PackageFormatException error;
  final BytesBuilder bytes = BytesBuilder(copy: false);

  @override
  void add(List<int> data) {
    if (bytes.length + data.length > limit) throw error;
    bytes.add(data);
  }

  @override
  void close() {}
}

class _Budget {
  int _bytes = 0;
  int _files = 0;

  int get remainingBytes => PackageStore.maxPackageBytes - _bytes;

  void checkNext(int bytes) {
    if (bytes > PackageStore.maxFileBytes) {
      throw const PackageFormatException('单文件超过 8 MiB（单包上限 20 MiB）');
    }
    if (_bytes + bytes > PackageStore.maxPackageBytes) {
      throw const PackageFormatException('包超过 20 MiB');
    }
    if (_files + 1 > PackageStore.maxPackageFiles) {
      throw const PackageFormatException('包里的文件超过 1000 个');
    }
  }

  void add(int bytes) {
    checkNext(bytes);
    _bytes += bytes;
    _files++;
  }
}
