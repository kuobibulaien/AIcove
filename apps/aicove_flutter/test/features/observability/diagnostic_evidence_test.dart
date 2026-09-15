import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/core/app_logger.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_pending_tts_resolver.dart';
import 'package:aicove_flutter/src/features/observability/frontend_diagnostics_port.dart';
import 'package:aicove_flutter/src/features/observability/frontend_diagnostics_provider.dart';
import 'package:aicove_flutter/src/features/observability/frontend_diagnostics_service.dart';
import 'package:aicove_flutter/src/features/plugins/domain/plugin.dart';
import 'package:aicove_flutter/src/features/plugins/tts/tts_player_manager.dart';
import 'package:aicove_flutter/src/features/plugins/tts/voice_request.dart';

class _OfflineTts extends TtsPlayerManager {
  _OfflineTts() : super(() => null);
  final events = StreamController<TtsPlayItem>.broadcast();
  final started = Completer<void>();
  late PluginEvent event;
  @override
  Stream<TtsPlayItem> get processedStream => events.stream;
  @override
  Future<void> addEvents(List<PluginEvent> incoming) async {
    event = incoming.single;
    started.complete();
  }

  void complete() => events.add(TtsPlayItem(
      id: event.id,
      text: 'private text',
      event: event,
      audioUrl: 'https://private.example/secret',
      status: TtsPlayItemStatus.completed));
  @override
  void dispose() {
    unawaited(events.close());
    super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('schema2：运行身份、父子链、单调序号和受控错误细节', () async {
    final entries = <LogEntry>[];
    final service = FrontendDiagnosticsService(sink: entries.add);
    service.setRuntimeIdentity({'buildId': 'fingerprint'});
    final parent =
        service.linkTurn(conversationId: 'c', turnId: 't', traceId: 'tr_1');
    final child =
        service.child(parent, FrontendStage.ttsRequested, messageId: 'm');
    service.record(child, FrontendStage.ttsFailed,
        error: StateError('No element'),
        stackTrace: StackTrace.fromString(
            List.generate(70, (i) => '#$i f (package:app/main.dart:$i:1)')
                .join('\n')),
        facts: const DiagnosticFacts(phase: DiagnosticPhase.error, state: {
          'pending': true,
          'count': 2,
          'secret': 'private body',
          'invalid': double.nan
        }));
    await Future<void>.delayed(Duration.zero);
    final meta = entries.last.metadata!;
    expect(meta['parentOperationId'], parent.operationId);
    expect(meta['traceId'], 'tr_1');
    expect(meta['build'], {'buildId': 'fingerprint'});
    expect(meta['appRunId'], service.appRunId);
    expect(meta['errorSummary'], 'No element');
    expect(meta['codeLocations'], hasLength(64));
    expect(meta['stackTruncated'], true);
    expect(meta['state'], {'pending': true, 'count': 2});
    expect(entries.map((e) => e.metadata!['sequence']), [1, 2, 3, 4]);
    expect(jsonEncode(meta), isNot(contains('private body')));
  });

  for (final reject in [true, false]) {
    test('真实 resolver：合成成功后${reject ? '被 owner 拒绝' : '交给回调'}，重试不串号', () async {
      final entries = <LogEntry>[];
      final diagnostics = FrontendDiagnosticsService(sink: entries.add);
      final parent = diagnostics.linkTurn(
          conversationId: 'c', turnId: 't', traceId: 'old_trace');
      diagnostics.bindMessage('m', parent);
      final manager = _OfflineTts();
      addTearDown(manager.dispose);
      final resolverProvider = Provider((ref) => ChatPendingTtsResolver(
          ref: ref,
          ttsManager: manager,
          enqueueStoreMutation: (action) => action()));
      final container = ProviderContainer(overrides: [
        frontendDiagnosticsProvider.overrideWithValue(diagnostics)
      ]);
      addTearDown(container.dispose);
      final resolver = container.read(resolverProvider);
      final message = resolver.buildPendingPlaceholderMessage('private text',
          messageId: 'm', sourceMessageId: 'raw_1');
      var applied = false;
      final task = VoiceRequest(ownerId: 'c').run(() => resolver.resolveSinglePendingMessage(
          convId: 'c',
          message: message,
          persistResult: false,
          shouldApplyResult: () => !reject,
          onAudioResolved: (_, __) => applied = true));
      await manager.started.future;
      diagnostics.linkTurn(
          conversationId: 'c', turnId: 't', traceId: 'new_trace');
      manager.complete();
      await task;
      await Future<void>.delayed(Duration.zero);
      final chain = entries
          .where((e) => e.metadata?['parentOperationId'] == parent.operationId)
          .toList();
      expect(chain.map((e) => e.metadata!['event']), [
        'ttsRequested',
        'ttsSynthesisStarted',
        'ttsSynthesisResult',
        'ttsApplyDecision'
      ]);
      expect(chain.every((e) => e.traceId == 'old_trace'), true);
      expect(chain.last.metadata!['reason'],
          reject ? 'ownerRejected' : 'callbackOnly');
      expect(chain.last.metadata!['phase'], reject ? 'skip' : 'end');
      expect(applied, !reject);
      expect(jsonEncode(chain.map((e) => e.toJson()).toList()),
          isNot(contains('private')));
    });
  }
}
