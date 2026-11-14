import 'package:aicove_flutter/src/features/agent_plugins/aicove_plugin.dart';
import 'package:aicove_flutter/src/features/agent_plugins/plugin_request_context.dart';
import 'package:aicove_flutter/src/features/agent_plugins/plugin_request_scope.dart';
import 'package:aicove_flutter/src/features/plugins/domain/base_plugin.dart';
import 'package:aicove_flutter/src/features/plugins/domain/handlers/ai_tool.dart';
import 'package:aicove_flutter/src/features/plugins/domain/plugin_metadata.dart';
import 'package:aicove_flutter/src/features/task_agent/task_agent_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../agent_plugins/plugin_request_test_support.dart';

class _Plugin extends BasePlugin {
  _Plugin(
    String id,
    this.events, {
    this.fail = '',
    this.on = true,
    this.usable = true,
    this.exposure = PluginExposure.roleExplicit,
  }) : super(
         metadata: PluginMetadata(
           id: id,
           name: id,
           description: '',
           version: '1',
           author: 'test',
           icon: Icons.extension,
         ),
       );

  final List<String> events;
  final String fail;
  final bool on;
  final bool usable;
  final PluginExposure exposure;

  @override
  bool get enabled => on;

  @override
  AicovePlugin get agentPlugin => AicovePlugin(
    id: id,
    name: name,
    exposure: exposure,
    capabilities: const {AppCapability.request},
    setup: (r) => r.add(AppContributions.requestScope, (inputs) {
      events.add('$id:factory');
      if (fail == 'factory') throw StateError('factory');
      return _Scope(this);
    }),
  );
}

class _Scope extends PluginRequestScope {
  _Scope(this.plugin);
  final _Plugin plugin;
  bool prepared = false;
  @override
  String get pluginId => plugin.id;
  @override
  String get pluginName => plugin.name;
  @override
  bool get active => plugin.usable;
  @override
  Future<String?> prompt(PluginRequestContext ctx) async {
    plugin.events.add('$pluginId:prompt:${ctx.conversationId}');
    if (plugin.fail == 'prompt') throw StateError('prompt');
    prepared = true;
    return '$pluginId prompt';
  }

  @override
  List<AITool> tools() {
    expect(prepared, isTrue);
    plugin.events.add('$pluginId:tools');
    if (plugin.fail == 'tools') throw StateError('tools');
    return [
      AITool(
        name: pluginId.replaceAll(':', '_'),
        description: '',
        parameters: const {},
        handler: (_) async => pluginId,
      ),
    ];
  }

  @override
  Future<void> dispose() async => plugin.events.add('$pluginId:dispose');
}

void main() {
  test(
    'task capabilities come from v2 scopes, with preparation and cleanup',
    () async {
      final events = <String>[];
      final result = await resolveTaskPluginCapabilities(
        [
          _Plugin('web_search', events, exposure: PluginExposure.roleDefault),
          _Plugin('mcp:work', events),
          _Plugin('pkg:work', events),
          _Plugin('trigger', events),
        ],
        {'web_search', 'mcp:work', 'pkg:work', 'trigger'},
        inputs: createPluginRequestInputs(),
      );
      expect(result.toolOwners, {
        'web_search': 'web_search',
        'mcp_work': 'mcp:work',
        'pkg_work': 'pkg:work',
      });
      expect(events, [
        for (final id in ['web_search', 'mcp:work', 'pkg:work']) ...[
          '$id:factory',
          '$id:prompt:null',
          '$id:tools',
          '$id:dispose',
        ],
      ]);
      expect(result.prompts.keys, [
        'web_search',
        'mcp:work',
        'pkg:work',
      ]);
      expect(
        (await result.tools.firstWhere((t) => t.name == 'pkg_work').invoke({}))
            .text,
        'pkg:work',
      );
    },
  );
  test(
    'role selection and task whitelist run before scope factories',
    () async {
      final events = <String>[];
      final plugins = [
        _Plugin('web_search', events, exposure: PluginExposure.roleDefault),
        _Plugin('mcp:work', events),
        _Plugin('pkg:work', events),
        _Plugin('mcp:off', events, on: false, fail: 'factory'),
        for (final id in ['memory', 'image', 'trigger', 'tts', 'other'])
          _Plugin(
            id,
            events,
            fail: 'factory',
            exposure: PluginExposure.roleDefault,
          ),
      ];
      Future<List<String>> names(Set<String>? ids) async =>
          (await resolveTaskPluginCapabilities(
            plugins,
            ids,
            inputs: createPluginRequestInputs(),
          )).tools.map((t) => t.name).toList();
      expect(await names(null), ['web_search']);
      expect(await names({}), isEmpty);
      expect(
        await names({
          'mcp:work',
          'pkg:work',
          'mcp:off',
          'memory',
          'image',
          'trigger',
          'tts',
          'other',
          'missing',
        }),
        ['mcp_work', 'pkg_work'],
      );
      expect(events.where((e) => e.endsWith(':factory')), [
        'web_search:factory',
        'mcp:work:factory',
        'pkg:work:factory',
      ]);
    },
  );

  test('active discovery never prepares prompts or constructs tools', () async {
    final events = <String>[];
    final ids = await resolveActiveTaskPluginIds(
      [
        _Plugin('web_search', events),
        _Plugin('mcp:ready', events),
        _Plugin('mcp:unusable', events, usable: false),
        _Plugin('pkg:ready', events),
        _Plugin('trigger', events),
        _Plugin('mcp:disabled', events, on: false, fail: 'factory'),
        _Plugin('image', events, fail: 'factory'),
      ],
      {
        'web_search',
        'mcp:ready',
        'mcp:unusable',
        'pkg:ready',
        'trigger',
        'mcp:disabled',
        'image',
      },
      inputs: createPluginRequestInputs(),
    );
    expect(ids, {'web_search', 'mcp:ready', 'pkg:ready'});
    expect(events, [
      for (final id in [
        'web_search',
        'mcp:ready',
        'mcp:unusable',
        'pkg:ready',
      ]) ...['$id:factory', '$id:dispose'],
    ]);
  });

  test('inactive capabilities construct neither tools nor prompts', () async {
    final events = <String>[];
    final result = await resolveTaskPluginCapabilities(
      [_Plugin('mcp:unusable', events, usable: false, fail: 'prompt')],
      {'mcp:unusable'},
      inputs: createPluginRequestInputs(),
    );
    expect(result.isEmpty, isTrue);
    expect(events, ['mcp:unusable:factory', 'mcp:unusable:dispose']);
  });

  for (final failure in ['prompt', 'tools', 'factory']) {
    test('scope resources close when $failure fails', () async {
      final events = <String>[];
      await expectLater(
        resolveTaskPluginCapabilities(
          [
            _Plugin('pkg:first', events),
            _Plugin('pkg:bad', events, fail: failure),
            _Plugin('pkg:never', events),
          ],
          {'pkg:first', 'pkg:bad', 'pkg:never'},
          inputs: createPluginRequestInputs(conversationId: 'owner'),
        ),
        throwsStateError,
      );
      expect(events, contains('pkg:first:dispose'));
      expect(
        events.indexOf('pkg:first:dispose'),
        lessThan(events.indexOf('pkg:bad:factory')),
      );
      expect(events, isNot(contains('pkg:never:factory')));
      expect(
        events.where((e) => e == 'pkg:bad:dispose').length,
        failure == 'factory' ? 0 : 1,
      );
      expect(events, contains('pkg:first:prompt:owner'));
    });
  }
}
