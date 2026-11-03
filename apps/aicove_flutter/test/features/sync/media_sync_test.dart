import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:aicove_flutter/src/core/media/media_asset.dart';
import 'package:aicove_flutter/src/core/media/media_store.dart';
import 'package:aicove_flutter/src/features/sync/data/cloud_document.dart';
import 'package:aicove_flutter/src/features/sync/data/cloud_media_codec.dart';

import 'package:aicove_flutter/src/core/media/media_resolver.dart';
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart' as chat;
import 'package:aicove_flutter/src/features/chat/services/chat_request_message_builder.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';

class ImageOnlySettings implements AppSettings {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final now = DateTime.utc(2026, 9, 13);
  late Directory temp;
  late MediaStore phone;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('cloud-media-test-');
    phone = MediaStore(Directory('${temp.path}/phone'), 'phone');
  });
  tearDown(() async {
    await phone.close();
    await temp.delete(recursive: true);
  });

  Future<File> picture(String name) async {
    final image = img.Image(width: 800, height: 600);
    img.fill(image, color: img.ColorRgb8(30, 100, 180));
    return File('${temp.path}/$name.png')
      ..writeAsBytesSync(img.encodePng(image));
  }

  test(
    'missing absolute paths heal from files in the asset directory',
    () async {
      final id = 'a' * 64;
      final original = File('${phone.root.path}/assets/$id/original.png');
      final thumbnail = File('${original.parent.path}/thumbnail.jpg');
      await original.parent.create(recursive: true);
      await original.writeAsBytes([1, 2, 3]);
      await thumbnail.writeAsBytes([4, 5]);
      await phone.save(
        LocalMedia(
          MediaAsset(
            id: id,
            mimeType: 'image/png',
            byteLength: 3,
            createdAtMs: 1,
          ),
          originalPath: '${temp.path}/old-container/assets/$id/original.png',
          thumbnailPath: '${temp.path}/old-container/assets/$id/thumbnail.jpg',
        ),
      );
      phone.downloadBlob = (_, _) async => fail('must use the local original');

      expect((await phone.original(id)).path, original.path);
      final healed = (await phone.load(id))!;
      expect(healed.originalPath, original.path);
      expect(healed.thumbnailPath, thumbnail.path);
      await phone.close();
      phone = MediaStore(phone.root, 'phone');
      expect((await phone.load(id))!.originalPath, original.path);
      expect((await phone.load(id))!.thumbnailPath, thumbnail.path);
    },
  );

  test('missing historical images become text without downloading', () async {
    final id = 'b' * 64;
    await phone.save(
      LocalMedia(
        MediaAsset(
          id: id,
          mimeType: 'image/png',
          byteLength: 0,
          createdAtMs: 1,
          originalBlob: 'c' * 64,
        ),
      ),
    );
    var downloads = 0;
    phone.downloadBlob = (_, _) async {
      downloads++;
      throw const CloudSyncFailure('云同步请求未完成（404），本地数据已保留');
    };
    final input = <Map<String, dynamic>>[
      {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': 'before'},
          {
            'type': 'image_url',
            'image_url': {'url': 'aicove-media://$id'},
          },
          {'type': 'text', 'text': 'after'},
        ],
      },
      {'role': 'assistant', 'content': 'reply'},
      {'role': 'user', 'content': 'continue'},
      {'role': 'tool', 'content': 'aicove-media://$id'},
    ];
    final resolved = await resolveModelMedia(input, store: phone);
    expect(resolved.first['content'], [
      {'type': 'text', 'text': 'before'},
      {'type': 'text', 'text': '[图片：原图不在本机]'},
      {'type': 'text', 'text': 'after'},
    ]);
    expect(resolved.last, input.last);
    expect((input.first['content'] as List)[1]['type'], 'image_url');
    expect(downloads, 0);

    // A proactive turn without a reminder ends after a reply: the last user
    // image is history, not the message being sent.
    final proactive = await resolveModelMedia(
      input.take(2).map((m) => Map<String, dynamic>.from(m)).toList(),
      store: phone,
    );
    expect((proactive.first['content'] as List)[1], {
      'type': 'text',
      'text': '[图片：原图不在本机]',
    });
  });

  test(
    'the actual history builder retains local-only image identity until original resolution',
    () async {
      final id = 'e' * 64;
      final reference = 'aicove-media://$id';
      final builder = ChatRequestMessageBuilder(
        readImageAsBase64: (_) async => null,
      );
      for (final base64 in [false, true]) {
        final history = [
          chat.Message(
            id: 'm',
            role: 'user',
            content: 'image',
            createdAt: now,
            blocks: [
              ImageBlock(
                messageId: 'm',
                localPath: base64 ? null : reference,
                base64: base64 ? reference : null,
                prompt: 'description',
              ),
            ],
          ),
        ];
        final request = await builder.buildRequestMessages(
          history,
          settings: ImageOnlySettings(),
        );
        expect(
          (request.single['content'] as List).single['image_url']['url'],
          reference,
        );
        await expectLater(
          resolveModelMedia(request, store: phone),
          throwsA(isA<OriginalMediaUnavailable>()),
        );
        final historical = await resolveModelMedia([
          ...request,
          {'role': 'user', 'content': 'continue'},
        ], store: phone);
        expect((historical.first['content'] as List).single, {
          'type': 'text',
          'text': '[图片：原图不在本机]',
        });
        final textOnly = await builder.buildRequestMessages(
          history,
          settings: ImageOnlySettings(),
          supportsVision: false,
        );
        await resolveModelMedia(textOnly, store: phone);
      }
    },
  );

  test(
    'a settings image receives its existing message date without becoming newly created on later imports',
    () async {
      final file = await picture('dated');
      final initial = await phone.register(file.path, createdAtMs: 0);
      final actualDate = now
          .subtract(const Duration(days: 5))
          .millisecondsSinceEpoch;
      final dated = await phone.register(file.path, createdAtMs: actualDate);
      expect(dated.asset.id, initial.asset.id);
      expect(dated.asset.createdAtMs, actualDate);
      expect(dated.asset.shouldTransferOriginal(now), true);
      expect(
        (await phone.register(
          file.path,
          createdAtMs: now.millisecondsSinceEpoch,
        )).asset.createdAtMs,
        actualDate,
      );
    },
  );

  test('30 day original boundary is based on original history time', () {
    MediaAsset asset(DateTime at) => MediaAsset(
      id: 'a' * 64,
      mimeType: 'image/png',
      byteLength: 1,
      createdAtMs: at.millisecondsSinceEpoch,
    );
    expect(
      asset(now.subtract(const Duration(days: 30))).shouldTransferOriginal(now),
      true,
    );
    expect(
      asset(
        now.subtract(const Duration(days: 30, milliseconds: 1)),
      ).shouldTransferOriginal(now),
      false,
    );
  });

  test(
    'legacy JSON sidecars import once and new assets share one database index',
    () async {
      final original = await picture('legacy');
      final id = sha256.convert(await original.readAsBytes()).toString();
      final record = LocalMedia(
        MediaAsset(
          id: id,
          mimeType: 'image/png',
          byteLength: await original.length(),
          createdAtMs: 1,
        ),
        originalPath: original.path,
      );
      final sidecar = File('${phone.root.path}/assets/$id/record.json');
      await sidecar.parent.create(recursive: true);
      await sidecar.writeAsString(jsonEncode(record.toJson()));
      expect((await phone.load(id))!.originalPath, original.path);
      await phone.noteUsage(id, createdAtMs: 1, originalRequired: true);
      for (var i = 0; i < 100; i++) {
        await phone.unavailable('missing-$i', createdAtMs: 1);
      }
      expect(await phone.records().length, 101);
      expect(
        await phone.root
            .list(recursive: true)
            .where((entry) => entry.path.endsWith('.json'))
            .length,
        1,
      );
      await phone.close();
      phone = MediaStore(phone.root, 'phone');
      expect((await phone.load(id))!.asset.originalRequired, true);
      expect(await phone.records().length, 101);
      expect(await original.exists(), true);
    },
  );

  test('old chat images reused by settings require originals', () async {
    final original = await picture('shared-avatar');
    final old = now.subtract(const Duration(days: 90)).millisecondsSinceEpoch;
    final chat = await phone.register(original.path, createdAtMs: old);
    expect(chat.asset.shouldTransferOriginal(now), false);
    final codec = CloudMediaCodec(phone);
    await codec.encode(
      CloudLocalDocument('conversations', 'role', {
        'row': {
          'id': 'role',
          'created_at': old,
          'avatar_url': chat.asset.reference,
        },
      }),
    );
    expect(
      (await phone.load(chat.asset.id))!.asset.shouldTransferOriginal(now),
      true,
    );
  });

  test(
    'a recent chat reference requires an original even if the image is old',
    () async {
      final original = await picture('reused');
      final old = now.subtract(const Duration(days: 90)).millisecondsSinceEpoch;
      final first = await phone.register(original.path, createdAtMs: old);
      await phone.register(
        original.path,
        createdAtMs: now.millisecondsSinceEpoch,
      );
      final reused = (await phone.load(first.asset.id))!;
      expect(reused.asset.createdAtMs, old);
      expect(reused.asset.shouldTransferOriginal(now), true);
    },
  );

  test(
    'old image gets a small thumbnail and stable identity; original is untouched',
    () async {
      final original = await picture('old');
      final originalBytes = await original.readAsBytes();
      final record = await phone.register(
        original.path,
        createdAtMs: now
            .subtract(const Duration(days: 45))
            .millisecondsSinceEpoch,
      );
      expect(record.asset.originalBlob, isNull);
      expect(record.asset.shouldTransferOriginal(now), false);
      expect(record.asset.width, 800);
      expect(record.asset.height, 600);
      final thumbnail = img.decodeImage(
        await File(record.thumbnailPath!).readAsBytes(),
      )!;
      expect(thumbnail.width, 320);
      expect(thumbnail.height, 240);
      expect(await original.readAsBytes(), originalBytes);
      expect(
        (await phone.register(
          original.path,
          createdAtMs: now.millisecondsSinceEpoch,
        )).asset.id,
        record.asset.id,
      );
      expect(
        (await phone.load(record.asset.id))!.asset.createdAtMs,
        record.asset.createdAtMs,
      );
    },
  );

  test(
    'the current user image fails locally with an actionable media error',
    () async {
      final original = await picture('remote');
      final record = await phone.register(original.path, createdAtMs: 1);
      final thumbnail = await File(record.thumbnailPath!).readAsBytes();
      final asset = MediaAsset.fromJson({
        ...record.asset.toJson(),
        'thumbnail_blob': sha256.convert(thumbnail).toString(),
        'original_blob': sha256
            .convert(await original.readAsBytes())
            .toString(),
      });
      final desktop = MediaStore(Directory('${temp.path}/desktop'), 'mac');
      desktop.downloadBlob = (digest, file) async {
        if (digest != asset.thumbnailBlob) {
          throw const CloudSyncFailure('云同步请求未完成（404），本地数据已保留');
        }
        await file.writeAsBytes(thumbnail);
      };
      await desktop.receive(asset, now: now);
      var downloads = 0;
      desktop.downloadBlob = (_, _) async {
        downloads++;
        throw const CloudSyncFailure('云同步请求未完成（404），本地数据已保留');
      };
      final input = [
        {
          'role': 'user',
          'content': [
            {
              'type': 'image_url',
              'image_url': {'url': asset.reference},
            },
          ],
        },
      ];
      await expectLater(
        resolveModelMedia(input, store: desktop),
        throwsA(
          isA<OriginalMediaUnavailable>().having(
            (error) => error.toString(),
            'message',
            '这条消息里的图片取不到原图，本轮没有发出。请重新选择图片后再发。',
          ),
        ),
      );
      expect(downloads, 0);
      await desktop.close();
    },
  );

  test(
    'another device displays thumbnail but cannot use it as an original',
    () async {
      final original = await picture('old');
      final record = await phone.register(original.path, createdAtMs: 1);
      final desktop = MediaStore(Directory('${temp.path}/desktop'), 'mac');
      final fetched = <String>[];
      desktop.downloadBlob = (digest, file) async {
        fetched.add(digest);
        await file.writeAsBytes(
          await File(record.thumbnailPath!).readAsBytes(),
        );
      };
      await desktop.receive(record.asset, now: now);
      expect(fetched, [record.asset.thumbnailBlob]);
      expect(await desktop.display(record.asset.id), isNotNull);
      await expectLater(
        desktop.original(record.asset.id),
        throwsA(isA<OriginalMediaUnavailable>()),
      );
      expect(await phone.original(record.asset.id), isA<File>());
    },
  );

  test(
    'uploaded original is only automatically downloaded for recent images',
    () async {
      final original = await picture('recent');
      final record = await phone.register(
        original.path,
        createdAtMs: now.millisecondsSinceEpoch,
      );
      final metadata = MediaAsset.fromJson({
        ...record.asset.toJson(),
        'original_blob': record.asset.originalSha256,
      });
      final desktop = MediaStore(Directory('${temp.path}/desktop'), 'windows');
      desktop.downloadBlob = (digest, file) async {
        final source = digest == metadata.thumbnailBlob
            ? File(record.thumbnailPath!)
            : original;
        await file.writeAsBytes(await source.readAsBytes());
      };
      await desktop.receive(metadata, now: now);
      expect(
        await (await desktop.original(metadata.id)).readAsBytes(),
        await original.readAsBytes(),
      );
      // Crossing the age boundary never deletes an already downloaded original.
      await desktop.receive(metadata, now: now.add(const Duration(days: 40)));
      expect(
        await (await desktop.original(
          metadata.id,
          allowDownload: false,
        )).exists(),
        true,
      );
    },
  );

  test(
    'wire conversion preserves tags and generation parameters and changes only image references',
    () async {
      final original = await picture('raw');
      const rawText = '<tts>hello</tts><draw_image>prompt</draw_image>';
      final raw = {
        'role': 'assistant',
        'content': rawText,
        'blocks': [
          {
            'type': 'image',
            'localPath': original.path,
            'generationSnapshot': {'seed': 42, 'prompt': 'original prompt'},
          },
        ],
      };
      final codec = CloudMediaCodec(phone);
      final document = CloudLocalDocument('messages', 'm', {
        'row': {
          'id': 'm',
          'role': 'assistant',
          'created_at': 1,
          'raw_payload': jsonEncode(raw),
        },
      });
      final wire = await codec.encode(document);
      final result = jsonDecode(
        (wire.payload['row'] as Map)['raw_payload'] as String,
      );
      expect(result['content'], rawText);
      expect(
        result['blocks'][0]['generationSnapshot'],
        (raw['blocks'] as List)[0]['generationSnapshot'],
      );
      expect(
        mediaIdFromReference(result['blocks'][0]['localPath']),
        wire.mediaIds.single,
      );
      expect(
        (await phone.load(
          wire.mediaIds.single,
        ))!.asset.shouldTransferOriginal(now),
        false,
      );
    },
  );

  test(
    'thumbnail corruption is rejected before publishing a local file',
    () async {
      final record = await phone.register(
        (await picture('checksum')).path,
        createdAtMs: 1,
      );
      final desktop = MediaStore(Directory('${temp.path}/desktop'), 'mac');
      desktop.downloadBlob = (digest, file) async =>
          file.writeAsBytes([1, 2, 3]);
      await expectLater(
        desktop.receive(record.asset, now: now),
        throwsFormatException,
      );
      expect(await desktop.load(record.asset.id), isNull);
      expect(
        sha256.convert([1, 2, 3]).toString(),
        isNot(record.asset.thumbnailBlob),
      );
    },
  );
  test(
    'pending audio destination keeps the same media identity when edited',
    () async {
      final desktop = MediaStore(Directory('${temp.path}/pending'), 'desktop');
      addTearDown(desktop.close);
      final file = File('${temp.path}/voice.wav')
        ..writeAsBytesSync(List.filled(64, 7));
      final registered = await phone.register(
        file.path,
        createdAtMs: now.millisecondsSinceEpoch,
        mimeType: 'audio/wav',
      );
      await desktop.receive(registered.asset, now: now, download: false);
      final payload = {
        'storage': 'preference',
        'key': 'aicove.plugins.tts.test',
        'json_value': jsonEncode({
          'sampleAudioPath': registered.asset.reference,
        }),
      };
      final codec = CloudMediaCodec(desktop);
      final decoded = await codec.decode('settings', payload);
      final path =
          jsonDecode(decoded['json_value'] as String)['sampleAudioPath']
              as String;
      expect(await File(path).exists(), isFalse);
      final wire = await codec.encode(
        CloudLocalDocument('settings', 'voice', decoded),
      );
      expect(wire.mediaIds, [registered.asset.id]);
      expect(
        jsonDecode(wire.payload['json_value'] as String)['sampleAudioPath'],
        registered.asset.reference,
      );
    },
  );
}
