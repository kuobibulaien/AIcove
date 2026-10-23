import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import '../../stickers/sticker_library.dart';
import 'workspace_read_only_mount.dart';

class StickerWorkspaceMount implements WorkspaceReadOnlyMount {
  StickerWorkspaceMount(this.library);
  final Future<StickerLibrary> Function() library;
  @override
  Future<Map<String, MountedWorkspaceFile>> files() async {
    final packs = (await library()).packs;
    final index = Uint8List.fromList(
      utf8.encode(
        [
          '# 表情库',
          for (final pack in packs) ...[
            '## ${pack.name} (${pack.id})',
            for (final sticker in pack.stickers)
              '- ${sticker.id}: ${sticker.tags.join('、')}',
          ],
        ].join('\n'),
      ),
    );
    final result = {
      'index.md': MountedWorkspaceFile(
        size: index.length,
        revision: sha256.convert(index).toString(),
        updatedAt: DateTime.now(),
        read: () async => index,
      ),
    };
    for (final pack in packs) {
      for (final sticker in pack.stickers) {
        // StickerLibrary.importFiles names immutable files with the first
        // 32 hex characters of SHA-256; labels only modify the catalogue.
        final revision = p.basenameWithoutExtension(sticker.path);
        if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(revision)) {
          throw StateError('Invalid content-addressed sticker filename');
        }
        final file = File(sticker.path);
        final stat = await file.stat();
        if (stat.type != FileSystemEntityType.file) continue;
        result['${pack.id}/${sticker.id}${p.extension(sticker.path)}'] =
            MountedWorkspaceFile(
              size: stat.size,
              revision: revision,
              updatedAt: stat.modified,
              read: file.readAsBytes,
            );
      }
    }
    return result;
  }
}
