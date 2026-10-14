import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'sticker_library.dart';

/// 表情包库的界面状态：套组列表。每次修改后重新发布，注册表由库自身同步。
final stickerLibraryProvider =
    AsyncNotifierProvider<StickerLibraryNotifier, List<StickerPack>>(
      StickerLibraryNotifier.new,
    );

class StickerLibraryNotifier extends AsyncNotifier<List<StickerPack>> {
  /// 测试可替换为临时目录下的库。
  static Future<StickerLibrary> Function() open = () => StickerLibrary.shared;

  late StickerLibrary _library;

  @override
  Future<List<StickerPack>> build() async {
    _library = await open();
    return _library.packs;
  }

  Future<T> _run<T>(Future<T> Function(StickerLibrary library) action) async {
    await future;
    final result = await action(_library);
    state = AsyncData(_library.packs);
    return result;
  }

  Future<void> setPackEnabled(String packId, bool enabled) =>
      _run((l) => l.setPackEnabled(packId, enabled));

  Future<void> renamePack(String packId, String name) =>
      _run((l) => l.renamePack(packId, name));

  Future<void> deletePack(String packId) => _run((l) => l.deletePack(packId));

  Future<void> deleteStickers(String packId, Set<String> ids) =>
      _run((l) => l.deleteStickers(packId, ids));

  Future<void> updateSticker(
    String stickerId, {
    List<String>? tags,
    String? description,
  }) => _run(
    (l) => l.updateSticker(stickerId, tags: tags, description: description),
  );

  Future<StickerImportResult> importFiles(
    List<StickerImportFile> files, {
    String? packId,
    String packName = '我的表情',
  }) => _run((l) => l.importFiles(files, packId: packId, packName: packName));

  Future<StickerImportResult> importZip(Uint8List bytes, String name) =>
      _run((l) => l.importZip(bytes, name));
}
