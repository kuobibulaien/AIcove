import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/features/observability/trace_models.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/trace_payload_panel.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/trace_timeline_panel.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: ThemeData(
      extensions: <ThemeExtension<dynamic>>[
        MoeColors.light(),
      ],
    ),
    home: Scaffold(body: child),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Trace panels', () {
    testWidgets(
        'TraceTimelinePanel should hide empty nodes and keep key events',
        (tester) async {
      final events = <TraceEvent>[
        TraceEvent(
          traceId: 'tr_1',
          sessionId: 's1',
          turnId: 't1',
          roundIndex: 0,
          eventSeq: 1,
          stage: TraceStage.turnStarted.value,
          status: TraceEventStatus.success.value,
          source: 'test',
          startedAt: DateTime(2026, 3, 2, 12, 0, 0),
          endedAt: DateTime(2026, 3, 2, 12, 0, 0),
          durationMs: 0,
        ),
        TraceEvent(
          traceId: 'tr_1',
          sessionId: 's1',
          turnId: 't1',
          roundIndex: 1,
          eventSeq: 2,
          stage: TraceStage.modelResponseReceived.value,
          status: TraceEventStatus.success.value,
          source: 'test',
          startedAt: DateTime(2026, 3, 2, 12, 0, 1),
          endedAt: DateTime(2026, 3, 2, 12, 0, 1),
          durationMs: 50,
        ),
        TraceEvent(
          traceId: 'tr_1',
          sessionId: 's1',
          turnId: 't1',
          roundIndex: 1,
          eventSeq: 3,
          stage: TraceStage.toolExecFinished.value,
          status: TraceEventStatus.success.value,
          source: 'test',
          startedAt: DateTime(2026, 3, 2, 12, 0, 2),
          endedAt: DateTime(2026, 3, 2, 12, 0, 3),
          durationMs: 1000,
          meta: const {'name': 'draw_image'},
        ),
        TraceEvent(
          traceId: 'tr_1',
          sessionId: 's1',
          turnId: 't1',
          roundIndex: 1,
          eventSeq: 4,
          stage: TraceStage.toolExecFinished.value,
          status: TraceEventStatus.success.value,
          source: 'test',
          startedAt: DateTime(2026, 3, 2, 12, 0, 3),
          endedAt: DateTime(2026, 3, 2, 12, 0, 3),
          durationMs: 0,
          payloadRef: const {
            'tracePayload': {'path': 'payload/test.json'}
          },
          meta: const {'aggregated': true, 'toolCalls': 1, 'toolResults': 1},
        ),
      ];
      TraceEvent? selected;

      await tester.pumpWidget(
        _wrap(
          SizedBox(
            height: 360,
            child: TraceTimelinePanel(
              events: events,
              selectedEvent: events.last,
              onSelect: (event) {
                selected = event;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('开始处理'), findsNothing);
      expect(find.text('AI回复收到'), findsOneWidget);
      expect(find.text('工具执行完毕'), findsOneWidget);
      expect(find.text('已折叠 2 个空节点'), findsOneWidget);
      expect(find.textContaining('1.00s'), findsOneWidget);

      await tester.tap(find.text('工具执行完毕'));
      await tester.pumpAndSettle();

      expect(selected, isNotNull);
      expect(selected!.eventSeq, 4);
    });

    testWidgets('TracePayloadPanel should switch tabs and render payload text',
        (tester) async {
      final event = TraceEvent(
        traceId: 'tr_1',
        sessionId: 's1',
        turnId: 't1',
        roundIndex: 1,
        eventSeq: 3,
        stage: TraceStage.modelResponseReceived.value,
        status: TraceEventStatus.success.value,
        source: 'test',
        startedAt: DateTime(2026, 3, 2, 12, 1, 0),
        endedAt: DateTime(2026, 3, 2, 12, 1, 0),
        durationMs: 100,
      );

      final payloadEnvelope = <String, dynamic>{
        'payload': {
          'rawContext': '[{"role":"user","content":"你好"}]',
          'rawRequestBody':
              '{"model":"gpt-test","messages":[{"role":"system","content":"你是一个测试助手"}],"tools":[{"type":"function","function":{"name":"draw_image","description":"用于生成图片","parameters":{"type":"object","properties":{"prompt":{"type":"string","description":"图片提示词"}},"required":["prompt"]}}}]}',
          'rawResponseBody': '{"id":"resp_1"}',
          'rawToolCalls': '[{"name":"draw_image"}]',
          'rawToolResults': '[{"ok":true}]',
          'finalReply': '已完成',
        },
      };

      await tester.pumpWidget(
        _wrap(
          SizedBox(
            height: 420,
            child: TracePayloadPanel(
              selectedEvent: event,
              payloadEnvelope: payloadEnvelope,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('错误信息'), findsNothing);
      expect(find.text('详情'), findsNothing);
      expect(find.textContaining('你是一个测试助手'), findsOneWidget);

      await tester.tap(find.text('工具清单'));
      await tester.pumpAndSettle();
      expect(find.textContaining('"name": "draw_image"'), findsOneWidget);
      expect(find.textContaining('"description": "用于生成图片"'), findsOneWidget);

      await tester.tap(find.text('请求体'));
      await tester.pumpAndSettle();
      expect(find.textContaining('"model": "gpt-test"'), findsOneWidget);

      await tester.tap(find.text('最终回复'));
      await tester.pumpAndSettle();
      expect(find.textContaining('已完成'), findsOneWidget);
    });

    testWidgets(
        'TracePayloadPanel should prefer raw AI response and keep delivered reply',
        (tester) async {
      final event = TraceEvent(
        traceId: 'tr_final',
        sessionId: 's1',
        turnId: 't1',
        roundIndex: 1,
        eventSeq: 6,
        stage: TraceStage.finalReplyReady.value,
        status: TraceEventStatus.success.value,
        source: 'test',
        startedAt: DateTime(2026, 3, 18, 21, 14, 41),
        endedAt: DateTime(2026, 3, 18, 21, 14, 41),
        durationMs: 0,
      );

      final payloadEnvelope = <String, dynamic>{
        'payload': {
          'rawAiResponse': '原始回复 <tts>这段要读</tts>\n<image>海边晚霞</image>',
          'finalReply': '处理后文本',
        },
      };

      await tester.pumpWidget(
        _wrap(
          SizedBox(
            height: 420,
            child: TracePayloadPanel(
              selectedEvent: event,
              payloadEnvelope: payloadEnvelope,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('最终回复'), findsOneWidget);
      expect(find.text('最终交付文本'), findsOneWidget);
      expect(find.textContaining('<tts>这段要读</tts>'), findsOneWidget);
      expect(find.textContaining('<image>海边晚霞</image>'), findsOneWidget);

      await tester.tap(find.text('最终交付文本'));
      await tester.pumpAndSettle();
      expect(find.textContaining('处理后文本'), findsOneWidget);
    });

    testWidgets('TracePayloadPanel should render Claude top-level system',
        (tester) async {
      final event = TraceEvent(
        traceId: 'tr_claude',
        sessionId: 's1',
        turnId: 't1',
        roundIndex: 1,
        eventSeq: 4,
        stage: TraceStage.modelResponseReceived.value,
        status: TraceEventStatus.success.value,
        source: 'test',
        startedAt: DateTime(2026, 3, 2, 12, 1, 0),
        endedAt: DateTime(2026, 3, 2, 12, 1, 0),
        durationMs: 100,
      );

      final payloadEnvelope = <String, dynamic>{
        'payload': {
          'rawRequestBody':
              '{"model":"claude-test","system":"你是 Claude 测试助手","messages":[{"role":"user","content":[{"type":"text","text":"你好"}]}]}',
        },
      };

      await tester.pumpWidget(
        _wrap(
          SizedBox(
            height: 420,
            child: TracePayloadPanel(
              selectedEvent: event,
              payloadEnvelope: payloadEnvelope,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Claude 测试助手'), findsOneWidget);
    });

    testWidgets('TracePayloadPanel should render Gemini system instruction',
        (tester) async {
      final event = TraceEvent(
        traceId: 'tr_gemini',
        sessionId: 's1',
        turnId: 't1',
        roundIndex: 1,
        eventSeq: 5,
        stage: TraceStage.modelResponseReceived.value,
        status: TraceEventStatus.success.value,
        source: 'test',
        startedAt: DateTime(2026, 3, 2, 12, 1, 0),
        endedAt: DateTime(2026, 3, 2, 12, 1, 0),
        durationMs: 100,
      );

      final payloadEnvelope = <String, dynamic>{
        'payload': {
          'rawRequestBody':
              '{"contents":[{"role":"user","parts":[{"text":"你好"}]}],"systemInstruction":{"parts":[{"text":"你是 Gemini 测试助手"}]}}',
        },
      };

      await tester.pumpWidget(
        _wrap(
          SizedBox(
            height: 420,
            child: TracePayloadPanel(
              selectedEvent: event,
              payloadEnvelope: payloadEnvelope,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Gemini 测试助手'), findsOneWidget);
    });

    testWidgets('TracePayloadPanel should show failed error details',
        (tester) async {
      final event = TraceEvent(
        traceId: 'tr_err',
        sessionId: 's_err',
        turnId: 't_err',
        roundIndex: 1,
        eventSeq: 9,
        stage: TraceStage.modelResponseReceived.value,
        status: TraceEventStatus.failed.value,
        source: 'test',
        startedAt: DateTime(2026, 3, 2, 12, 2, 0),
        endedAt: DateTime(2026, 3, 2, 12, 2, 1),
        durationMs: 900,
        meta: const {
          'statusCode': 400,
          'error': 'HTTP 400: Improperly formed request',
        },
      );

      final payloadEnvelope = <String, dynamic>{
        'payload': {
          'rawResponseBody':
              '{"error":"messages[0] is invalid","detail":"provider validation failed"}',
        },
      };

      await tester.pumpWidget(
        _wrap(
          SizedBox(
            height: 420,
            child: TracePayloadPanel(
              selectedEvent: event,
              payloadEnvelope: payloadEnvelope,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('错误信息'), findsOneWidget);
      expect(find.textContaining('Improperly formed request'), findsOneWidget);
      expect(find.textContaining('messages[0] is invalid'), findsOneWidget);
      expect(find.text('系统提示词'), findsNothing);
    });

    testWidgets(
        'TracePayloadPanel should copy current section and all sections',
        (tester) async {
      String? copiedText;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        SystemChannels.platform,
        (methodCall) async {
          if (methodCall.method == 'Clipboard.setData') {
            final args =
                (methodCall.arguments as Map?) ?? const <dynamic, dynamic>{};
            copiedText = args['text']?.toString();
            return null;
          }
          if (methodCall.method == 'Clipboard.getData') {
            return <String, dynamic>{'text': copiedText ?? ''};
          }
          return null;
        },
      );
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });

      final event = TraceEvent(
        traceId: 'tr_copy',
        sessionId: 's1',
        turnId: 't1',
        roundIndex: 1,
        eventSeq: 7,
        stage: TraceStage.modelResponseReceived.value,
        status: TraceEventStatus.success.value,
        source: 'test',
        startedAt: DateTime(2026, 3, 2, 12, 3, 0),
        endedAt: DateTime(2026, 3, 2, 12, 3, 0),
        durationMs: 100,
      );

      final payloadEnvelope = <String, dynamic>{
        'payload': {
          'rawContext': '[{"role":"user","content":"hello"}]',
          'finalReply': 'done',
        },
      };

      await tester.pumpWidget(
        _wrap(
          SizedBox(
            height: 420,
            child: TracePayloadPanel(
              selectedEvent: event,
              payloadEnvelope: payloadEnvelope,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('复制当前区块'));
      await tester.pumpAndSettle();
      expect(copiedText, isNotNull);
      expect(copiedText, contains('[上下文]'));

      await tester.tap(find.byTooltip('复制全部区块'));
      await tester.pumpAndSettle();
      expect(copiedText, isNotNull);
      expect(copiedText, contains('[上下文]'));
      expect(copiedText, contains('[最终回复]'));

      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
    });
  });
}
