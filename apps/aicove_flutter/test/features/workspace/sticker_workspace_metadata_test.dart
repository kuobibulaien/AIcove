import 'dart:io';
import 'dart:typed_data';
import 'package:aicove_flutter/src/features/stickers/sticker_library.dart';
import 'package:aicove_flutter/src/features/stickers/sticker_registry.dart';
import 'package:aicove_flutter/src/features/workspace/application/workspace_toolset.dart';
import 'package:aicove_flutter/src/features/workspace/data/sticker_workspace_mount.dart';
import 'package:aicove_flutter/src/features/workspace/data/workspace_store.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

class _MetadataOnlyFile implements File {
  _MetadataOnlyFile(this.path, this.onRead);
  @override
  final String path;
  final void Function() onRead;
  @override
  Future<FileStat> stat() => FileStat.stat(path);
  @override
  Future<Uint8List> readAsBytes() async {
    onRead();
    throw StateError('Image bytes must stay lazy');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected file operation: ${invocation.memberName}');
}

void main() {
  test(
    'sticker filename revision and stat metadata enumerate without image reads',
    () async {
      final root = await Directory.systemTemp.createTemp('sticker_metadata_');
      final library = StickerLibrary(Directory(p.join(root.path, 'library')));
      final store = await WorkspaceStore.open(
        Directory(p.join(root.path, 'workspaces')),
      );
      try {
        await library.load();
        await store.ensureDefault();
        final bytes = Uint8List.fromList(
          img.encodePng(img.Image(width: 2, height: 3)),
        );
        await library.importFiles([
          StickerImportFile('标签.png', bytes),
        ], packName: 'pack');
        final sticker = library.packs.single.stickers.single;
        final revision = sha256.convert(bytes).toString().substring(0, 32);
        expect(p.basenameWithoutExtension(sticker.path), revision);
        final mount = StickerWorkspaceMount(() async => library);
        store.registerReadOnlyMount(defaultWorkspaceId, 'stickers', mount);
        var reads = 0;
        await IOOverrides.runZoned(() async {
          final entries = await mount.files();
          final image = entries.entries.singleWhere((e) => e.key != 'index.md');
          expect(image.value.revision, revision);
          expect(image.value.size, bytes.length);
          expect(
            (await store.files(
              defaultWorkspaceId,
            )).where((f) => f.path.endsWith('.png')).single.revision,
            revision,
          );
          expect(
            (await store.listDirectory(
              defaultWorkspaceId,
              'stickers/${library.packs.single.id}',
            )).single.file!.size,
            bytes.length,
          );
          expect(
            (await store.stat(
              defaultWorkspaceId,
              'stickers/${image.key}',
            ))!.revision,
            revision,
          );
          expect(await store.stat(defaultWorkspaceId, 'stickers'), isNull);
          final tool = WorkspaceToolset(
            store: store,
            workspaceIds: {defaultWorkspaceId},
            runId: 'test',
          ).tools().firstWhere((t) => t.name == 'workspace_glob');
          expect(
            (await tool.invoke({
              'workspace': defaultWorkspaceId,
              'pattern': 'stickers/**/*.png',
            })).isError,
            isFalse,
          );
          expect(reads, 0);
          await expectLater(image.value.read(), throwsStateError);
          expect(reads, 1);
        }, createFile: (path) => _MetadataOnlyFile(path, () => reads++));
        final relative =
            'stickers/${library.packs.single.id}/${sticker.id}${p.extension(sticker.path)}';
        final read = await store.read(defaultWorkspaceId, relative);
        expect(read.$1, bytes);
        expect(read.$2, revision);
        final before = (await mount.files())['index.md']!.revision;
        await library.updateSticker(sticker.id, tags: ['新标签']);
        final after = await mount.files();
        expect(after['index.md']!.revision, isNot(before));
        expect(
          after.entries.singleWhere((e) => e.key != 'index.md').value.revision,
          revision,
        );
      } finally {
        await store.close();
        StickerRegistry.instance.replaceStickers(const []);
        await root.delete(recursive: true);
      }
    },
  );
}
