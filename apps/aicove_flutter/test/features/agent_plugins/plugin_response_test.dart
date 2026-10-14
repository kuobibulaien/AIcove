import 'dart:io';

import 'package:aicove_flutter/src/features/agent_plugins/plugin_response.dart';
import 'package:aicove_flutter/src/features/agent_plugins/plugin_runtime.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_service.dart';
import 'package:aicove_flutter/src/features/plugins/domain/plugin.dart';
import 'package:aicove_flutter/src/features/plugins/plugin_manager.dart';
import 'package:aicove_flutter/src/features/plugins/plugin_providers.dart';
import 'package:aicove_flutter/src/features/plugins/tts/voice_preset_application.dart';
import 'package:aicove_flutter/src/features/plugins/domain/plugin_metadata.dart';
import 'package:aicove_flutter/src/features/plugins/image/image_config.dart';
import 'package:aicove_flutter/src/features/plugins/image/image_plugin.dart';
import 'package:aicove_flutter/src/features/plugins/tts/tts_config.dart';
import 'package:aicove_flutter/src/features/plugins/tts/tts_plugin.dart';
import 'package:aicove_flutter/src/features/plugins/tts/tts_service.dart';
import 'package:aicove_flutter/src/features/plugins/tts/voice_request.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/services/test_plugin_support.dart';

/// Appends its tag and records the text it saw.
class _TagPlugin extends TestPlugin {
  _TagPlugin(String id, this.seen, {this.fail = false})
      : super(
          metadata: PluginMetadata(
            id: id,
            name: id,
            description: '',
            version: '1',
            author: 'test',
            icon: Icons.extension,
          ),
        );

  final List<String> seen;
  final bool fail;

  @override
  bool get enabled => true;

  @override
  Future<String?> getSystemPrompt({
    String? userMessage,
    bool supportsToolCalling = false,
  }) async =>
      null;

  @override
  Future<PluginProcessResult> processResponse(String text) async {
    seen.add('$id:$text');
    if (fail) throw StateError('boom');
    return PluginProcessResult(processedText: '$text<$id>', events: const []);
  }
}

class _Fixed extends PluginResponseProcessor {
  _Fixed(this.pluginId, this.order, this.log);

  @override
  final String pluginId;
  @override
  final int order;
  final List<String> log;

  @override
  Future<PluginProcessResult> process(String text) async {
    log.add(pluginId);
    return PluginProcessResult(processedText: text, events: const []);
  }
}

PluginResponseProcessor _response(_TagPlugin plugin) =>
    ResponseFunction(plugin.id, plugin.processResponse);

class _Voice implements VoicePresetApplicationPort {
  final owners = <String>[];

  @override
  Future<VoiceRequest> forRole(Conversation owner) async {
    owners.add(owner.id);
    return _voice();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final _refProvider = Provider<Ref>((ref) => ref);

VoiceRequest _voice() => VoiceRequest(
      ownerId: 'role',
      service: TtsService(
        config: TtsConfig(enabled: true),
        requestUrl: 'https://tts.invalid',
        model: 'speech',
      ),
    );

void main() {
  late ProviderContainer container;
  late Ref ref;

  setUp(() {
    container = ProviderContainer();
    ref = container.read(_refProvider);
  });
  tearDown(() => container.dispose());

  test('processors run by order, ties in plugin order; failures are skipped',
      () async {
    final log = <String>[];
    await runResponseProcessors(
      [
        _Fixed('speech', ResponseOrder.afterTagRemoval, log),
        _Fixed('a', ResponseOrder.normal, log),
        _Fixed('b', ResponseOrder.normal, log),
      ],
      'x',
      logTag: 'test',
    );
    expect(log, ['a', 'b', 'speech']);

    final seen = <String>[];
    final result = await runResponseProcessors(
      [
        _response(_TagPlugin('one', seen)),
        _response(_TagPlugin('bad', seen, fail: true)),
        _response(_TagPlugin('two', seen)),
      ],
      'reply',
      logTag: 'test',
    );
    expect(result.processedText, 'reply<one><two>');
    expect(seen, ['one:reply', 'bad:reply<one>', 'two:reply<one>']);
  });

  test('speech always processes text other plugins already cleaned, on both '
      'reply paths', () async {
    final seen = <String>[];
    final runtime = PluginRuntime.fromPlugins([
      TtsPlugin(TtsConfig(enabled: true)), // registered first
      _TagPlugin('sticker', seen),
    ]);
    final processors = runtime.responseProcessors(
      runtime.snapshot(),
      runtime.selectForRole(null),
      PluginResponseInputs(ref: ref, voiceRequest: _voice()),
    );
    expect(
      [for (final p in processors) (p.pluginId, p.order)],
      [('tts', ResponseOrder.afterTagRemoval), ('sticker', ResponseOrder.normal)],
    );
    final result = await runResponseProcessors(
      processors,
      '<tts>hello</tts>',
      logTag: 'test',
    );
    expect(seen, ['sticker:<tts>hello</tts>']);
    expect(result.events.single.data['text'], 'hello');
  });

  test('the cached reply entry uses the role selection, the voice request '
      'of the owner, and runs speech last', () async {
    final seen = <String>[];
    final voice = _Voice();
    final manager = PluginManager()
      ..register(TtsPlugin(TtsConfig(enabled: true))) // registered first
      ..register(_TagPlugin('sticker', seen))
      ..register(_TagPlugin('other', seen));
    final cached = ProviderContainer(overrides: [
      pluginManagerProvider.overrideWithValue(manager),
      voicePresetApplicationProvider.overrideWithValue(voice),
    ]);
    addTearDown(cached.dispose);
    final now = DateTime(2026, 10, 12);

    final result = await cached
        .read(chatSendServiceProvider)
        .processAssistantReplyWithPlugins(
          conv: Conversation(
            id: 'role_1',
            title: 'Role',
            displayName: 'Role',
            createdAt: now,
            updatedAt: now,
            enabledPlugins: const ['tts', 'sticker'],
          ),
          rawReplyText: ' <tts>hello</tts> ',
        );

    expect(voice.owners, ['role_1']);
    // "other" is not enabled for the role; sticker sees speech tags intact.
    expect(seen, ['sticker:<tts>hello</tts>']);
    expect(result.pluginEvents.single.data['text'], 'hello');
    expect(result.processedText, isNot(contains('<tts>')));
    expect(result.rawReplyText, '<tts>hello</tts>');
  });

  test('without a voice request the speech processor passes text through',
      () async {
    final runtime =
        PluginRuntime.fromPlugins([TtsPlugin(TtsConfig(enabled: true))]);
    final processors = runtime.responseProcessors(
      runtime.snapshot(),
      runtime.selectForRole(null),
      PluginResponseInputs(ref: ref, voiceRequest: null),
    );
    final result =
        await runResponseProcessors(processors, '<tts>hi</tts>', logTag: 't');
    expect(result.processedText, '<tts>hi</tts>');
    expect(result.events, isEmpty);
  });

  test('a request reply carries the drawing snapshot; a cached reply uses the '
      'registered plugin', () async {
    final settings = mapUiModelsToAppSettings(const {})
        .copyWith(imageGenerationEnabled: true);
    // The registered instance reads live settings, which are not loaded in
    // this test, so it is off: a cached reply leaves tags in place.
    final runtime = PluginRuntime()
      ..install(ImagePlugin(const ImageConfig(), ref).agentPlugin);

    final requestResult = await runResponseProcessors(
      runtime.responseProcessors(
        runtime.snapshot(),
        runtime.selectForRole(null),
        PluginResponseInputs(
          ref: ref,
          voiceRequest: null,
          drawingConfig: const ImageConfig(defaultWidth: 640),
          settings: settings,
        ),
      ),
      '<image>a cat</image>',
      logTag: 't',
    );
    expect(
      (requestResult.events.single.data['drawingConfig'] as Map)['defaultWidth'],
      640,
    );

    final cachedResult = await runResponseProcessors(
      runtime.responseProcessors(
        runtime.snapshot(),
        runtime.selectForRole(null),
        PluginResponseInputs(ref: ref, voiceRequest: null),
      ),
      '<image>a cat</image>',
      logTag: 't',
    );
    expect(cachedResult.events, isEmpty);
    expect(cachedResult.processedText, '<image>a cat</image>');
  });

  test('the send execution path has no plugin type checks', () {
    final pattern = RegExp(
      r'\bis\s+(Image|Tts|Sticker|TimeAwareness|Memory|WebSearch|Trigger|'
      r'McpConnector)Plugin\b|whereType<\w+Plugin>',
    );
    final offenders = <String>[];
    for (final dir in ['lib/src/features/chat', 'lib/src/features/auto_reply']) {
      for (final file in Directory(dir).listSync(recursive: true)) {
        if (file is! File || !file.path.endsWith('.dart')) continue;
        final lines = file.readAsLinesSync();
        for (final (index, line) in lines.indexed) {
          if (pattern.hasMatch(line)) offenders.add('${file.path}:${index + 1}');
        }
      }
    }
    expect(offenders, isEmpty);
  });
}
