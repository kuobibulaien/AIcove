import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/features/plugins/domain/plugin.dart';
import 'package:aicove_flutter/src/features/plugins/tts/tts_config.dart';
import 'package:aicove_flutter/src/features/plugins/tts/tts_service.dart';
import 'package:aicove_flutter/src/features/plugins/tts/tts_player_manager.dart';
import 'package:aicove_flutter/src/features/plugins/tts/tts_plugin.dart';
import 'package:aicove_flutter/src/features/plugins/tts/voice_request.dart';

class FakeSpeech extends TtsService {
  FakeSpeech(this.tag)
      : super(
            config: TtsConfig(enabled: true, voiceFrequency: 40),
            requestUrl: 'https://example.invalid',
            apiKey: 'secret-$tag',
            model: tag);
  final String tag;
  final pending = Completer<TtsConvertResult>();
  @override
  Future<TtsConvertResult> convert(String text) => pending.future;
}

void main() {
  test(
      'concurrent A/B events use frozen services, not the latest global getter',
      () async {
    final a = FakeSpeech('a'), b = FakeSpeech('b');
    var globalCalls = 0;
    final manager = TtsPlayerManager(() {
      globalCalls++;
      return null;
    });
    addTearDown(manager.dispose);
    final eventA = PluginEvent(
        pluginId: 'tts', type: 'tts_convert', id: 'a', data: {'text': 'hello'});
    final eventB = PluginEvent(
        pluginId: 'tts', type: 'tts_convert', id: 'b', data: {'text': 'world'});
    VoiceRequest(ownerId: 'role-a', service: a).attach(eventA);
    VoiceRequest(ownerId: 'role-b', service: b).attach(eventB);
    final results = manager.processedStream.take(2).toList();
    await manager.addEvents([eventA, eventB]);
    b.pending.complete(
        TtsConvertResult(success: true, text: 'world', audioUrl: 'b-audio'));
    a.pending.complete(
        TtsConvertResult(success: true, text: 'hello', audioUrl: 'a-audio'));
    final items = await results;
    expect({for (final item in items) item.id: item.audioUrl},
        {'a': 'a-audio', 'b': 'b-audio'});
    expect(globalCalls, 0);
    expect(jsonEncode(eventA.toJson()), isNot(contains('secret')));
  });

  test('request scope crosses async work but does not leak to another request',
      () async {
    final a = VoiceRequest(ownerId: 'a', error: 'pending');
    final b = VoiceRequest(ownerId: 'b', error: 'pending');
    Future<String> capture(VoiceRequest request) => request.run(() async {
          await Future<void>.delayed(Duration.zero);
          return VoiceRequest.current!.ownerId;
        });
    expect(await Future.wait([capture(a), capture(b)]), ['a', 'b']);
    expect(VoiceRequest.current, isNull);
  });

  test(
      'plugin-generated events retain the owner snapshot without serializing credentials',
      () async {
    final request = VoiceRequest(ownerId: 'a', service: FakeSpeech('minimax'));
    final plugin = TtsPlugin.forRequest(request);
    final processed = await plugin.processResponse('<tts>你好呀</tts>');
    expect(processed.events, isNotEmpty);
    expect(VoiceRequest.forEvents(processed.events), same(request));
    expect(jsonEncode(processed.events.map((e) => e.toJson()).toList()),
        isNot(contains('secret-minimax')));
  });

  test('voice creation caches are scoped by provider, URL and credential', () {
    TtsService service(String provider, String url, String key) => TtsService(
        config: TtsConfig(selectedProviderId: provider),
        requestUrl: url,
        apiKey: key);
    final scopes = [
      service('a', 'url', 'key'),
      service('b', 'url', 'key'),
      service('a', 'other', 'key'),
      service('a', 'url', 'other-key')
    ].map((s) => s.voiceCacheScope).toSet();
    expect(scopes, hasLength(4));
    expect(scopes.any((s) => s.contains('key')), isFalse);
  });
}
