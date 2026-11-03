import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/core/models/block_status.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_deferred_image_delivery.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_history_store.dart';
import 'package:aicove_flutter/src/features/chat/services/conversation_short_window_store.dart';
import 'package:aicove_flutter/src/features/plugins/image/image_config.dart';
import 'package:aicove_flutter/src/features/plugins/image/image_plugin.dart';
import 'package:aicove_flutter/src/features/plugins/plugin_manager.dart';
import 'package:aicove_flutter/src/features/plugins/plugin_providers.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

class _Settings extends AppSettingsNotifier {
  _Settings(this.value);
  final AppSettings value;
  @override
  Future<AppSettings> build() async => value;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final outcome in ['success', 'deleted', 'invalidated', 'failure']) {
    test(
      'deferred image $outcome preserves the placeholder lifecycle',
      () async {
        SharedPreferences.setMockInitialValues({});
        final directory = await Directory(
          'build',
        ).createTemp('deferred-image-lifecycle');
        addTearDown(() => directory.delete(recursive: true));
        const channel = MethodChannel('plugins.flutter.io/path_provider');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(
          channel,
          (_) async => directory.path,
        );
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        final settings = mapUiModelsToAppSettings({}).copyWith(
          imageGenerationEnabled: true,
          modelTypes: {'local:image': 'image'},
          modelProviderMap: {'local:image': 'local'},
          providers: [
            const ProviderAuth(
              id: 'local',
              apiKeys: ['test'],
              apiBaseUrl: 'https://local.test/v1',
              models: ['image'],
              visibleModels: ['image'],
              capabilities: ['image'],
            ),
          ],
        );
        const config = ImageConfig(
          selectedProviderId: 'local',
          selectedModelId: 'local:image',
        );
        final database = db.AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(database.close);
        final container = ProviderContainer(
          overrides: [
            databaseProvider.overrideWithValue(database),
            appSettingsProvider.overrideWith(() => _Settings(settings)),
            pluginManagerProvider.overrideWith(
              (ref) => PluginManager()
                ..register(ImagePlugin(config, ref, requestSettings: settings)),
            ),
          ],
        );
        addTearDown(container.dispose);
        await container.read(appSettingsProvider.future);
        await database
            .into(database.conversations)
            .insert(
              db.ConversationsCompanion.insert(
                id: 'conv',
                title: 'test',
                displayName: 'test',
                createdAt: 1,
                updatedAt: 1,
              ),
            );
        final store = container.read(chatHistoryStoreProvider);
        final timeline = container.read(conversationTimelineCacheProvider);
        final now = DateTime(2026, 10, 26);
        await store.appendMessage(
          conversationId: 'conv',
          message: Message(
            id: 'raw',
            role: 'assistant',
            content: 'text',
            createdAt: now,
            rawPayload: {
              'displayReplyText': 'text',
              'processedText': 'text',
              'rawReplyText': 'text',
            },
          ),
        );
        final tasks = <Future<void>>[];
        final delivery = container.read(
          Provider(
            (ref) => ChatDeferredImageDelivery(
              ref: ref,
              enqueueStoreMutation: (action) => action(),
              runBackgroundTask: (_, action) => tasks.add(action()),
            ),
          ),
        );
        final placeholder = delivery.buildPendingPlaceholderMessage(
          messageId: 'image',
          prompt: 'cat',
          createdAt: now,
          sourceMessageId: 'raw',
          drawingSnapshot: config.toJson(),
        );
        await store.appendMessage(conversationId: 'conv', message: placeholder);
        final entered = Completer<void>(), release = Completer<void>();
        final client = MockClient((_) async {
          entered.complete();
          await release.future;
          if (outcome == 'failure') {
            return http.Response('{"error":"fixture failed"}', 400);
          }
          return http.Response(
            jsonEncode({
              'data': [
                {
                  'b64_json': base64Encode(
                    img.encodePng(img.Image(width: 23, height: 41)),
                  ),
                },
              ],
            }),
            200,
          );
        });
        addTearDown(client.close);
        var commit = true;
        await http.runWithClient(() async {
          delivery.scheduleJobs(
            convId: 'conv',
            drawingSnapshot: config.toJson(),
            shouldCommit: () => commit,
            jobs: [
              DeferredImageJob(
                messageId: 'image',
                prompt: 'cat',
                createdAt: now,
                sourceMessageId: 'raw',
                hasPlaceholder: true,
              ),
            ],
          );
          await entered.future;
          expect(
            (await store.loadProjectedMessagesFromRawStore(
              'conv',
            )).expand((m) => m.images),
            isEmpty,
          );
          if (outcome == 'deleted') {
            await timeline.replaceMessagesTransient(
              conversationId: 'conv',
              removeMessageIds: ['image'],
            );
          }
          if (outcome == 'invalidated') commit = false;
          release.complete();
          await Future.wait(tasks);
        }, () => client);
        final images = (await timeline.loadCachedMessages(
          'conv',
        )).where((m) => m.images.isNotEmpty).toList();
        if (outcome == 'failure') {
          expect(images, hasLength(1));
          final failed = images.single.images.single;
          expect(failed.id, placeholder.images.single.id);
          expect(failed.status, BlockStatus.error);
          expect(failed.localPath, isNull);
          expect(failed.generationSnapshot!.basePrompt, 'cat');
          final stored = (await store.loadProjectedMessagesFromRawStore(
            'conv',
          )).expand((message) => message.images).single;
          expect(stored.status, BlockStatus.error);
          expect(
            stored.generationSnapshot!.toJson(),
            failed.generationSnapshot!.toJson(),
          );
        } else if (outcome == 'success') {
          expect(images, hasLength(1));
          expect(images.single.id, placeholder.id);
          final image = images.single.images.single;
          expect(image.id, placeholder.images.single.id);
          expect(image.status, BlockStatus.success);
          expect((image.width, image.height), (23, 41));
          final stored = (await store.loadProjectedMessagesFromRawStore(
            'conv',
          )).expand((m) => m.images).single;
          expect((stored.width, stored.height), (23, 41));
        } else {
          expect(images, isEmpty);
          expect(
            (await store.loadProjectedMessagesFromRawStore(
              'conv',
            )).expand((m) => m.images),
            isEmpty,
          );
        }
      },
    );
  }
}
