// The assistant changes the interface settings with undo that targets what
// it changed, and resets them to the fresh-install values (chat data is not
// in these settings).
import 'dart:convert';
import 'dart:io';

import 'package:aicove_flutter/src/features/agent_plugins/file_change_journal.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_review.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_settings_tools.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/settings/data/support/ui_models_store_support.dart'
    show kUiModelsStoreKey;
import 'package:aicove_flutter/src/ui/theme/moe_glass_theme.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late ProviderContainer container;
  late AssistantSettingsTools tools;
  late FileChangeJournal journal;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    dir = await Directory.systemTemp.createTemp('assistant_interface_');
    container = ProviderContainer();
    await container.read(appSettingsProvider.future);
    AppSettingsNotifier notifier() =>
        container.read(appSettingsProvider.notifier);
    journal = FileChangeJournal(
      file: () async => File('${dir.path}/journal.json'),
      appliers: {
        assistantSettingChangeKind: AssistantSettingApplier(
          notifier: notifier,
        ),
        assistantInterfaceResetChangeKind: AssistantInterfaceResetApplier(
          notifier: notifier,
        ),
      },
    );
    tools = AssistantSettingsTools(
      current: () => container.read(appSettingsProvider).valueOrNull,
      load: () => container.read(appSettingsProvider.future),
      notifier: notifier,
      journal: journal,
    );
  });

  tearDown(() async {
    container.dispose();
    await dir.delete(recursive: true);
  });

  AppSettingsNotifier notifier() => container.read(appSettingsProvider.notifier);
  AppSettings now() => container.read(appSettingsProvider).requireValue;

  Future<Map<String, dynamic>> run(
    String name, [
    Map<String, dynamic> args = const {},
  ]) async =>
      jsonDecode(
            (await tools
                .tools()
                .singleWhere((t) => t.name == name)
                .handler(args))!,
          )
          as Map<String, dynamic>;

  Future<Map<String, dynamic>> set(String key, Object? value) =>
      run(AssistantSettingsTools.setTool, {'key': key, 'value': value});

  Future<void> undoLatest() async =>
      journal.undo((await journal.recent(limit: 1)).single.id);

  test('message chunking changes the switch the chat splits by', () async {
    expect(now().messageFormatConfig.enableChunking, isTrue);

    expect((await set('chat.message_chunking', false))['ok'], isTrue);
    expect(now().messageFormatConfig.enableChunking, isFalse);

    await undoLatest();
    expect(now().messageFormatConfig.enableChunking, isTrue);
  });

  test('a custom color switches to the custom skin; undo puts both back', () async {
    expect(now().interfaceSkin, isNot(InterfaceSkin.custom));
    final skin = now().interfaceSkin;
    final accent = now().accentColor;

    // The stored custom color itself: still a change, the skin switches.
    final result = await set('appearance.accent_color', '#${accent.toLowerCase()}');
    expect(result['ok'], isTrue);
    expect(result['change'], isNot('没有变化'));
    expect(now().interfaceSkin, InterfaceSkin.custom);

    await set('appearance.chat_background', ChatBackgroundColor.warm.value);
    expect(now().chatBackgroundColor, ChatBackgroundColor.warm);

    // The color change cannot be undone over the later background change.
    final entries = await journal.recent();
    await expectLater(journal.undo(entries[1].id), throwsStateError);

    await journal.undo(entries[0].id);
    expect(now().chatBackgroundColor, ChatBackgroundColor.defaultColor);
    await journal.undo(entries[1].id);
    expect(now().interfaceSkin, skin);
    expect(now().accentColor, accent);
  });

  test('wallpaper mask undo targets the wallpaper it was made on', () async {
    expect(now().globalWallpaper, GlobalWallpaper.catnap);
    final before = now().wallpaperStyleFor('catnap', custom: false).mask;

    expect((await set('appearance.wallpaper_mask', 0.8))['ok'], isTrue);
    expect(now().activeWallpaperStyle.mask, 0.8);

    await set('appearance.wallpaper', GlobalWallpaper.laketown.value);
    final entries = await journal.recent();
    await journal.undo(entries[1].id);

    expect(now().globalWallpaper, GlobalWallpaper.laketown);
    expect(now().wallpaperStyleFor('catnap', custom: false).mask, before);
  });

  test('wallpaper mask is refused without a wallpaper', () async {
    await set('appearance.wallpaper', GlobalWallpaper.none.value);
    final result = await set('appearance.wallpaper_mask', 0.5);
    expect(result['error'], 'invalid');
  });

  test('punctuation undo edits the set it was made on', () async {
    final config = now().messageFormatConfig;
    final first = config.activeChunkPunctuationSetId;
    final original = config.activeChunkPunctuationSet!.punctuations;
    final other = config.chunkPunctuationSets
        .firstWhere((set) => set.id != first)
        .id;
    final otherPunctuations = config.chunkPunctuationSets
        .firstWhere((set) => set.id == other)
        .punctuations;

    expect((await set('chat.chunk_punctuations', '。 ！ ！'))['ok'], isTrue);
    expect(now().messageFormatConfig.chunkPunctuations, ['。', '！']);

    await set('chat.chunk_punctuation_set', other);
    expect(now().messageFormatConfig.chunkPunctuations, otherPunctuations);

    final entries = await journal.recent();
    await journal.undo(entries[1].id);

    final after = now().messageFormatConfig;
    expect(after.activeChunkPunctuationSetId, other);
    expect(after.chunkPunctuations, otherPunctuations);
    expect(
      after.chunkPunctuationSets.firstWhere((set) => set.id == first).punctuations,
      original,
    );
  });

  test('punctuation undo restores the runtime list the chat split by', () async {
    final config = now().messageFormatConfig;
    final id = config.activeChunkPunctuationSetId;
    // A legal state: the runtime list differs from the active set's own.
    await notifier().updateMessageFormatConfig(
      config.withSetPunctuations(id, ['？'])!.copyWith(
        chunkPunctuations: ['。', '！'],
      ),
    );

    expect((await set('chat.chunk_punctuations', '…'))['ok'], isTrue);
    expect(now().messageFormatConfig.chunkPunctuations, ['…']);

    await undoLatest();
    final after = now().messageFormatConfig;
    expect(after.activeChunkPunctuationSet!.punctuations, ['？']);
    expect(after.chunkPunctuations, ['。', '！']);
  });

  test('punctuation undo is refused after the runtime list changed', () async {
    await set('chat.chunk_punctuations', '。 ！');
    await notifier().updateMessageFormatConfig(
      now().messageFormatConfig.copyWith(chunkPunctuations: ['？']),
    );
    await expectLater(undoLatest(), throwsStateError);
    expect(now().messageFormatConfig.chunkPunctuations, ['？']);
  });

  test('an empty punctuation set is allowed', () async {
    expect((await set('chat.chunk_punctuations', ''))['ok'], isTrue);
    expect(now().messageFormatConfig.activeChunkPunctuationSet!.punctuations, isEmpty);
  });

  test('reset needs the user and returns to fresh-install values', () async {
    expect(
      tools.riskOf(AssistantSettingsTools.resetTool, const {}),
      AssistantRisk.major,
    );
    final fresh = now();
    await notifier().setSurfaceMaterial(MoeSurfaceMaterial.solid);
    await notifier().setTextScaleFactor(1.15);
    await notifier().setGlobalWallpaper(GlobalWallpaper.none);
    await notifier().setUserName('小明');
    await notifier().setCustomSkin(accentColor: '123456');

    expect((await run(AssistantSettingsTools.resetTool))['ok'], isTrue);
    expect(now().surfaceMaterial, fresh.surfaceMaterial);
    expect(now().textScaleFactor, 1.0);
    expect(now().globalWallpaper, GlobalWallpaper.catnap);
    expect(now().interfaceSkin, fresh.interfaceSkin);
    // Not an interface setting.
    expect(now().userName, '小明');

    await undoLatest();
    expect(now().surfaceMaterial, MoeSurfaceMaterial.solid);
    expect(now().textScaleFactor, 1.15);
    expect(now().globalWallpaper, GlobalWallpaper.none);
    expect(now().accentColor, '123456');
  });

  test('reset undo is refused after a later interface change', () async {
    await notifier().setTextScaleFactor(1.15);
    await run(AssistantSettingsTools.resetTool);
    await notifier().setHideUserAvatar(false);
    await expectLater(undoLatest(), throwsStateError);
    expect(now().hideUserAvatar, isFalse);
  });

  test('the storage reset recovers settings that no longer load', () async {
    final prefs = await SharedPreferences.getInstance();
    final raw =
        jsonDecode(prefs.getString(kUiModelsStoreKey)!) as Map<String, dynamic>;
    raw['message_format_config'] = 'broken';
    await prefs.setString(kUiModelsStoreKey, jsonEncode(raw));
    container.invalidate(appSettingsProvider);
    await expectLater(
      container.read(appSettingsProvider.future),
      throwsA(anything),
    );

    await resetStoredInterfaceSettings();
    container.invalidate(appSettingsProvider);
    final settings = await container.read(appSettingsProvider.future);
    expect(settings.messageFormatConfig.enableChunking, isTrue);
  });
}
