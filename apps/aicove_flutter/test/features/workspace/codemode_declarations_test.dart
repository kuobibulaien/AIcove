import 'package:aicove_flutter/src/features/plugins/domain/handlers/ai_tool.dart';
import 'package:aicove_flutter/src/features/workspace/application/codemode_declarations.dart';
import 'package:flutter_test/flutter_test.dart';

AITool tool(
  String name, {
  ToolExposure exposure = ToolExposure.direct,
  String description = 'Example',
  Map<String, dynamic>? input,
  Map<String, dynamic>? output,
}) => AITool(
  name: name,
  description: description,
  parameters: const {},
  inputSchema: input,
  outputSchema: output,
  exposure: exposure,
  handler: (_) async => 'ok',
);
void main() {
  test('direct remains default and metadata survives copies', () {
    final t = tool('read');
    expect(t.exposure, ToolExposure.direct);
    expect(
      t.copyWith(exposure: ToolExposure.codemode).exposure,
      ToolExposure.codemode,
    );
    expect(
      directToolSchemas([
        t,
        tool('nested', exposure: ToolExposure.codemode),
        tool('mcp', exposure: ToolExposure.deferred),
      ]),
      hasLength(1),
    );
  });
  test(
    'schema declarations preserve required, nested types, tags and output types',
    () {
      final t = tool(
        'x-y',
        input: {
          'type': 'object',
          'properties': {
            'path': {'type': 'string'},
            'count': {'type': 'integer', 'minimum': 1, 'default': 20},
            'edits': {
              'type': 'array',
              'items': {
                'type': 'object',
                'properties': {
                  'oldText': {'type': 'string'},
                },
                'required': ['oldText'],
              },
            },
          },
          'required': ['path'],
        },
        output: {
          'type': 'object',
          'properties': {
            'ok': {'type': 'boolean'},
          },
          'required': ['ok'],
        },
      );
      final signature = renderToolSignature(t);
      expect(signature, contains('x_y(args:'));
      expect(signature, contains('path: string'));
      expect(signature, contains('count?: number'));
      expect(signature, contains('@minimum 1'));
      expect(signature, contains('Array<'));
      expect(signature, contains('Promise<{ ok: boolean; }>'));
    },
  );
  test(
    'nullable property tags retain branch bounds and legacy exclusivity',
    () {
      final signature = renderToolSignature(
        tool(
          'bounded',
          input: {
            'type': 'object',
            'properties': {
              'n': {
                'minimum': 1,
                'anyOf': [
                  {'type': 'integer', 'minimum': 2, 'maximum': 10},
                  {'type': 'null'},
                ],
              },
              'x': {
                'type': ['integer', 'null'],
                'minimum': 3,
                'exclusiveMinimum': true,
              },
            },
          },
        ),
      );
      expect(signature, contains('@integer @minimum 2 @maximum 10'));
      expect(signature, contains('@exclusiveMinimum 3'));
      expect(signature, isNot(contains('@exclusiveMinimum true')));
    },
  );
  test(
    'oversized inputs render unknown, local references resolve and recursive refs stop',
    () {
      expect(
        schemaToType({
          'type': 'object',
          'properties': {
            for (var i = 0; i < 4000; i++) 'key$i': {'type': 'string'},
          },
        }, maxChars: 16000),
        'unknown',
      );
      expect(
        schemaToType({
          r'$ref': r'#/$defs/x',
          r'$defs': {
            'x': {'type': 'string'},
          },
        }),
        'string',
      );
      expect(schemaToType({r'$ref': '#'}), 'unknown');
    },
  );
  test('catalog is namespace-fair, bounded, and excludes deferred tools', () {
    final tools = [
      for (var i = 0; i < 70; i++)
        tool(
          'aicove_test_$i',
          exposure: ToolExposure.codemode,
          description: 'description ' * 100,
        ),
      tool('workspace_list', exposure: ToolExposure.codemode),
      tool('mcp__s__lookup', exposure: ToolExposure.deferred),
    ];
    final text = createCodemodeDescription(tools);
    expect(text, contains('## aicove'));
    expect(text, contains('workspace_list(args:'));
    expect(text, contains('(some tools not listed)'));
    expect(text, isNot(contains('mcp__s__lookup')));
    expect(text.length, lessThanOrEqualTo(12000));
  });
}
