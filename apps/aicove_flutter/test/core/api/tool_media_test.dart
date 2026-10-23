import 'dart:convert';
import 'dart:typed_data';
import 'package:aicove_agent_kernel/aicove_agent_kernel.dart';
import 'package:aicove_flutter/src/core/api/tool_media.dart';
import 'package:aicove_flutter/src/core/api/providers/claude_adapter.dart';
import 'package:aicove_flutter/src/core/api/providers/gemini_adapter.dart';
import 'package:aicove_flutter/src/core/api/providers/openai_adapter.dart';
import 'package:aicove_flutter/src/core/api/providers/provider_adapter.dart';
import 'package:aicove_flutter/src/features/plugins/domain/handlers/ai_tool.dart';
import 'package:aicove_flutter/src/features/workspace/application/workspace_image.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

class _Executor implements ToolBatchExecutor {
  _Executor(this.result);
  final KernelToolResult result;
  @override
  BatchMode modeFor(List<KernelToolCall> calls, TurnContext ctx) =>
      BatchMode.serial;
  @override
  Future<KernelToolResult> executeOne(
    KernelToolCall call,
    TurnContext ctx,
  ) async => result;
}

void main() {
  ToolImage image(String source, {int bytes = 3}) => ToolImage(
    mimeType: 'image/png',
    bytes: Uint8List(bytes),
    source: source,
    width: 1,
    height: 1,
  );
  List<Map<String, dynamic>> messages(List<ToolImage> images) =>
      toolImageMessages(images);
  for (final count in [19, 20, 21]) {
    test(
      'request image count boundary $count, oldest omitted without mutation',
      () {
        final live = messages([
          for (var i = 0; i < count; i++) image('source-$i'),
        ]);
        final sent = ToolMedia.wire(live);
        final text = jsonEncode(sent);
        expect('image_url'.allMatches(text).length, count.clamp(0, 20) * 2);
        expect(text.contains('［图片已省略：source-0］'), count > 20);
        expect(jsonEncode(live), isNot(contains('图片已省略')));
        expect(text, isNot(contains(toolStepMarker)));
        expect(text, isNot(contains(toolImageSource)));
      },
    );
  }
  for (final total in [
    12 * 1024 * 1024 - 1,
    12 * 1024 * 1024,
    12 * 1024 * 1024 + 1,
  ]) {
    test('request image bytes boundary $total', () {
      final live = messages([
        for (var i = 0; i < 5; i++) image('old-$i', bytes: 2 * 1024 * 1024),
        image('small', bytes: 1),
        image('new', bytes: total - 10 * 1024 * 1024 - 1),
      ]);
      final sent = jsonEncode(ToolMedia.wire(live));
      expect(sent.contains('［图片已省略：old-0］'), total > 12 * 1024 * 1024);
      expect(jsonEncode(live), isNot(contains('图片已省略')));
    });
  }
  test(
    'legacy handler remains callable and rich errors/structure survive invoke',
    () async {
      final old = AITool(
        name: 'old',
        description: 'old',
        parameters: const {},
        handler: (_) async => 'old',
      );
      expect((await old.invoke({})).text, 'old');
      final rich = AITool(
        name: 'rich',
        description: 'rich',
        parameters: const {},
        handler: (_) async => 'legacy',
        richHandler: (_) async => ToolOutput(
          images: [image('image-only')],
          isError: true,
          structured: const {'v': 1},
        ),
      );
      final out = await rich.invoke({});
      expect(out.images, hasLength(1));
      expect(out.isError, isTrue);
      expect(out.structured, {'v': 1});
      expect(out.persistentText, '［图片已省略：image-only］');
    },
  );
  test(
    'redaction invalidates image fields without losing delivery payload',
    () async {
      final secret = SecretRedactor()..register('secret-key');
      final raw = KernelToolResult(
        callId: 'c',
        name: 'read',
        content: 'secret-key',
        images: [image('private')],
        payload: const {'secret': 'secret-key'},
      );
      final executor = RedactingToolExecutor(_Executor(raw), secret);
      final ctx = TurnContext(
        round: 1,
        cancellation: KernelCancellation(),
        emit: (_) async {},
      );
      final safe = await executor.executeOne(
        const KernelToolCall(id: 'c', name: 'read'),
        ctx,
      );
      expect(safe.content, isNot(contains('secret-key')));
      expect(safe.images, isEmpty);
      expect(safe.payload, same(raw.payload));
      expect(safe.outputRewritten, isTrue);
      final unchanged = KernelToolResult(
        callId: 'c',
        name: 'read',
        content: 'public',
        images: [image('public')],
      );
      expect(
        await RedactingToolExecutor(
          _Executor(unchanged),
          secret,
        ).executeOne(const KernelToolCall(id: 'c', name: 'read'), ctx),
        same(unchanged),
      );
    },
  );
  test('three provider encoding snapshots, image-only and mixed errors', () {
    final results = [
      ToolResult(
        toolCallId: 'c',
        name: 'read',
        result: '',
        images: [
          ToolImage(
            mimeType: 'image/png',
            bytes: Uint8List.fromList([1, 2, 3]),
            source: 'a',
          ),
        ],
      ),
      const ToolResult(
        toolCallId: 'e',
        name: 'fail',
        result: 'failure',
        isError: true,
      ),
    ];
    final openai = ToolMedia.wire(
      OpenAIAdapter().buildToolResultMessages(
        assistantMessage: {'content': '', 'tool_calls': []},
        toolResults: results,
      ),
    );
    expect(openai, [
      {'role': 'assistant', 'content': '', 'tool_calls': []},
      {'role': 'tool', 'tool_call_id': 'c', 'content': '（图片见下一条消息）'},
      {'role': 'tool', 'tool_call_id': 'e', 'content': 'failure'},
      {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': '以下是工具返回的图片：'},
          {
            'type': 'image_url',
            'image_url': {'url': 'data:image/png;base64,AQID'},
          },
        ],
      },
    ]);
    final claude = ToolMedia.wire(
      ClaudeAdapter().buildToolResultMessages(
        assistantMessage: {'content': []},
        toolResults: results,
      ),
    );
    expect(claude, [
      {'role': 'assistant', 'content': []},
      {
        'role': 'user',
        'content': [
          {
            'type': 'tool_result',
            'tool_use_id': 'c',
            'content': [
              {
                'type': 'image',
                'source': {
                  'type': 'base64',
                  'media_type': 'image/png',
                  'data': 'AQID',
                },
              },
            ],
          },
          {
            'type': 'tool_result',
            'tool_use_id': 'e',
            'content': 'failure',
            'is_error': true,
          },
        ],
      },
    ]);
    final gemini = ToolMedia.wire(
      GeminiAdapter().buildToolResultMessages(
        assistantMessage: {
          'content': {'parts': []},
        },
        toolResults: results,
      ),
    );
    expect(gemini, [
      {'role': 'model', 'parts': []},
      {
        'role': 'user',
        'parts': [
          {
            'functionResponse': {
              'name': 'read',
              'response': {'result': ''},
            },
          },
          {
            'functionResponse': {
              'name': 'fail',
              'response': {'result': 'failure'},
            },
          },
        ],
      },
      {
        'role': 'user',
        'parts': [
          {'text': '以下是工具返回的图片：'},
          {
            'inlineData': {'mimeType': 'image/png', 'data': 'AQID'},
          },
        ],
      },
    ]);
  });
  test('image references keep two 2 MiB images outside the preset input', () {
    final live = messages([
      image('one', bytes: 2 * 1024 * 1024),
      image('two', bytes: 2 * 1024 * 1024),
    ]);
    final refs = PresetImageReferences();
    final hidden = refs.hide(live);
    expect(utf8.encode(jsonEncode(hidden)).length, lessThan(8 * 1024 * 1024));
    expect(jsonEncode(hidden), isNot(contains('base64')));
    expect(refs.restore(hidden), live);
  });
  test(
    'preset reference restoration preserves nested tool argument arrays',
    () {
      final refs = PresetImageReferences();
      final value = <Map<String, dynamic>>[
        {
          'role': 'assistant',
          'tool_calls': [
            {
              'function': {
                'arguments': {
                  'matrix': [
                    [1, 2],
                    [3, 4],
                  ],
                },
              },
            },
          ],
        },
        ...messages([image('one')]),
      ];
      expect(refs.restore(refs.hide(value)), value);
    },
  );
  for (final provider in ['openai', 'claude', 'gemini']) {
    test(
      'log projection removes $provider base64, preserves image metadata',
      () {
        final part = toolImagePart(
          image('source'),
          claude: provider == 'claude',
          gemini: provider == 'gemini',
        );
        final raw = {
          'messages': [
            {
              'role': 'user',
              'content': [part],
            },
          ],
        };
        final safe = ToolMedia.logJson(jsonEncode(raw));
        expect(safe, isNot(contains('base64')));
        expect(safe, isNot(contains('AAAA')));
        expect(safe, contains('"bytes":3'));
        expect(safe, contains('"width":1'));
        expect(safe, contains('image/png'));
        expect(
          jsonEncode(raw),
          contains(provider == 'openai' ? 'base64' : 'AAAA'),
        );
      },
    );
  }
  for (final edge in [1567, 1568, 1569]) {
    test('image long edge boundary $edge', () async {
      final input = Uint8List.fromList(
        img.encodePng(img.Image(width: edge, height: 2)),
      );
      final output = await prepareWorkspaceImage(input, 'image');
      expect(output, isNotNull);
      expect(img.decodeImage(output!.bytes)!.width, edge.clamp(0, 1568));
      expect(output.bytes.length, lessThanOrEqualTo(2 * 1024 * 1024));
    });
  }
  for (final size in [
    2 * 1024 * 1024 - 1,
    2 * 1024 * 1024,
    2 * 1024 * 1024 + 1,
  ]) {
    test('final encoded image bytes boundary $size', () {
      final png = img.encodePng(img.Image(width: 1, height: 1));
      final bytes = Uint8List(size)..setRange(0, png.length, png);
      final result = encodedWorkspaceImage(
        bytes: bytes,
        mimeType: 'image/png',
        source: 'bounded',
        width: 1,
        height: 1,
      );
      expect(result != null, size <= 2 * 1024 * 1024);
      if (result != null) expect(result.bytes.length, size);
    });
  }
  test('bad or unsupported images produce no attachment', () async {
    expect(
      await prepareWorkspaceImage(Uint8List.fromList([0, 255, 1]), 'bad'),
      isNull,
    );
  });
}
