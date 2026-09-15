import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:aicove_flutter/src/core/media/embedded_media_store.dart';
import 'package:aicove_flutter/src/core/media/media_asset.dart';
import 'package:aicove_flutter/src/core/media/media_store.dart';

void main() {
  test(
    'an inline image URL remains renderable through its stable media ID',
    () async {
      final root = await Directory.systemTemp.createTemp('embedded-picture-');
      final media = MediaStore(root, 'fixture');
      try {
        final bytes = img.encodePng(img.Image(width: 8, height: 6));
        final store = EmbeddedMediaStore(store: () async => media);
        final result = jsonDecode(
          await store.compactJson(
            jsonEncode({
              'blocks': [
                {
                  'type': 'image',
                  'url': 'data:image/png;base64,${base64Encode(bytes)}',
                },
              ],
            }),
          ),
        );
        final id = mediaIdFromReference(result['blocks'][0]['url'] as String)!;
        expect(
          await (await media.original(id, allowDownload: false)).readAsBytes(),
          bytes,
        );
      } finally {
        await media.close();
        await root.delete(recursive: true);
      }
    },
  );
  test(
    'legacy inline audio is reused and its old source alias still resolves',
    () async {
      final root = await Directory.systemTemp.createTemp('legacy-inline-');
      final media = MediaStore(root, 'fixture');
      try {
        final bytes = utf8.encode('RIFF0000WAVEfixture');
        final id = sha256.convert(bytes).toString();
        final legacy = File('${root.path}/inline/$id');
        await legacy.parent.create(recursive: true);
        await legacy.writeAsBytes(bytes);
        await media.save(
          LocalMedia(
            MediaAsset(
              id: id,
              mimeType: 'audio/wav',
              byteLength: bytes.length,
              createdAtMs: 1,
              originalSha256: id,
            ),
            originalPath: legacy.path,
          ),
        );
        final store = EmbeddedMediaStore(store: () async => media);
        final compact = jsonDecode(
          await store.compactJson(
            jsonEncode({
              'audioUrl': 'data:audio/wav;base64,${base64Encode(bytes)}',
            }),
          ),
        );
        final path = compact['audioUrl'] as String;
        expect(path, endsWith('.wav'));
        expect(await File(path).readAsBytes(), bytes);
        expect(await legacy.parent.list().length, 1);
        expect(
          (await media.register(legacy.path, createdAtMs: 1)).asset.id,
          id,
        );
      } finally {
        await media.close();
        await root.delete(recursive: true);
      }
    },
  );
  test(
    'three embedded copies become one durable file and keep all raw fields',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'embedded-media-test-',
      );
      final media = MediaStore(root, 'fixture');
      try {
        final store = EmbeddedMediaStore(store: () async => media);
        final bytes = Uint8List.fromList(
          List.generate(128 * 1024, (i) => i % 251),
        );
        final audio = 'data:audio/wav;base64,${base64Encode(bytes)}';
        final raw = jsonEncode({
          'rawReplyText': '<tts>原文</tts>',
          'toolAudioResults': [
            {'audioUrl': audio, 'text': '原文'},
          ],
          'supplementInsertOps': [
            {'audioUrl': audio, 'textCharsBefore': 7},
          ],
          'projectedMessages': [
            {
              'blocks': [
                {'type': 'audio', 'url': audio},
              ],
            },
          ],
          'toolCalls': [
            {
              'arguments': {'prompt': audio},
            },
          ],
          'parameters': {'seed': 42},
        });
        final compact = await store.compactJson(raw);
        final result = jsonDecode(compact);
        final file = result['toolAudioResults'][0]['audioUrl'] as String;
        expect(result['supplementInsertOps'][0]['audioUrl'], file);
        expect(result['projectedMessages'][0]['blocks'][0]['url'], file);
        expect(result['toolCalls'][0]['arguments']['prompt'], audio);
        expect(result['parameters'], {'seed': 42});
        expect(result['rawReplyText'], '<tts>原文</tts>');
        expect(await File(file).readAsBytes(), bytes);
        expect(await Directory('${root.path}/inline').list().length, 1);
        expect(compact.length, lessThan(raw.length ~/ 2));
        expect(await store.compactJson(raw), compact);
        expect(await Directory('${root.path}/inline').list().length, 1);
        expect(await store.compactJson(compact), compact);
      } finally {
        await media.close();
        await root.delete(recursive: true);
      }
    },
  );
}
