import 'package:aicove_agent_kernel/aicove_agent_kernel.dart';
import 'package:aicove_flutter/src/core/services/system_reminder_service.dart';
import 'package:aicove_flutter/src/features/agent_plugins/aicove_plugin.dart';
import 'package:aicove_flutter/src/features/agent_plugins/plugin_request_context.dart';
import 'package:aicove_flutter/src/features/agent_plugins/plugin_request_scope.dart';
import 'package:aicove_flutter/src/features/agent_plugins/plugin_runtime.dart';
import 'package:aicove_flutter/src/features/plugins/domain/base_plugin.dart';
import 'package:aicove_flutter/src/features/plugins/domain/plugin.dart';
import 'package:aicove_flutter/src/features/plugins/domain/plugin_metadata.dart';
import 'package:aicove_flutter/src/features/plugins/image/image_config.dart';
import 'package:aicove_flutter/src/features/plugins/memory/memory_plugin.dart';
import 'package:aicove_flutter/src/features/plugins/prompts/plugin_prompts.dart';
import 'package:aicove_flutter/src/features/plugins/tts/voice_request.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'dart:collection';

import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/plugins/image/image_plugin.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Plugin extends BasePlugin {
  _Plugin(
    String id, {
    bool enabled = true,
    this.exposure = PluginExposure.roleDefault,
  })  : _enabled = enabled,
        super(
          metadata: PluginMetadata(
            id: id,
            name: 'Plugin $id',
            description: '',
            version: '1',
            author: 'test',
            icon: Icons.extension,
          ),
        );

  final bool _enabled;
  final PluginExposure exposure;

  @override
  bool get enabled => _enabled;

  @override
  AicovePlugin get agentPlugin => AicovePlugin(
        id: id,
        name: name,
        exposure: exposure,
        capabilities: const {AppCapability.request},
        setup: (r) => r.add(
          AppContributions.requestScope,
          (_) => _ReminderScope(this, () => const []),
        ),
      );
}

class _SpyMemoryPlugin extends MemoryPlugin {
  _SpyMemoryPlugin(super.ref);

  String? lastConversationId;

  @override
  bool get enabled => true;

  @override
  Future<String?> buildMemoryPrompt({
    String? userMessage,
    String? conversationId,
  }) async {
    lastConversationId = conversationId;
    return 'memory_prompt';
  }
}

/// History that fails as soon as it is read.
class _BrokenHistory extends ListBase<Message> {
  @override
  int get length => throw StateError('history unavailable');

  @override
  set length(int value) => throw UnsupportedError('read only');

  @override
  Message operator [](int index) => throw StateError('history unavailable');

  @override
  void operator []=(int index, Message value) =>
      throw UnsupportedError('read only');
}

class _ReminderScope extends PluginRequestScope {
  _ReminderScope(this.plugin, this.build);

  final Plugin plugin;
  final List<PluginReminder> Function() build;

  @override
  String get pluginId => plugin.id;

  @override
  String get pluginName => plugin.name;

  @override
  bool get active => true;

  @override
  List<PluginReminder> reminders(DateTime requestTime) => build();
}

const _ctx = PluginRequestContext(
  userMessage: 'hi',
  supportsToolCalling: true,
  conversationId: 'conv_target',
);

final _refProvider = Provider<Ref>((ref) => ref);

PluginRequestInputs _inputs(Ref ref) => PluginRequestInputs(
      ref: ref,
      settings: mapUiModelsToAppSettings(const {}),
      imageConfig: const ImageConfig(),
      voiceRequest: VoiceRequest(ownerId: 'test'),
      pluginPrompts: const PluginPrompts(),
      history: const [],
      previousUserMessageTime: null,
      useFastImageRoute: false,
      useStableImageRoute: true,
      supportsToolCalling: true,
      customDrawingPrompt: '',
      reminders: const SystemReminderService(),
    );

void main() {
  late ProviderContainer container;
  late PluginRequestInputs inputs;

  setUp(() {
    container = ProviderContainer();
    inputs = _inputs(container.read(_refProvider));
  });
  tearDown(() => container.dispose());

  List<PluginRequestScope> scopesOf(
    PluginRuntime runtime, {
    Set<String>? role,
  }) =>
      runtime.requestScopes(
        runtime.snapshot(),
        runtime.selectForRole(role),
        inputs,
      );

  test('memory scope passes the target conversation id', () async {
    final memory = _SpyMemoryPlugin(container.read(_refProvider));
    final scope = scopesOf(PluginRuntime.fromPlugins([memory])).single;

    expect(await scope.prompt(_ctx), 'memory_prompt');
    expect(memory.lastConversationId, 'conv_target');
  });

  test('role selection: built-ins follow "all plugins", explicit-only '
      'plugins need the role, globally disabled plugins never run', () {
    final runtime = PluginRuntime.fromPlugins([
      _Plugin('image'),
      _Plugin('mcp:notion', exposure: PluginExposure.roleExplicit),
      _Plugin('off', enabled: false),
    ]);

    expect(runtime.selectForRole(null), ['image']);
    expect(runtime.selectForRole({'mcp:notion', 'off'}), ['mcp:notion']);
    expect(runtime.selectForRole(const {}), isEmpty);
  });

  test('scope order follows installation, not re-enable order; disabled '
      'plugins drop out from the next snapshot', () {
    final runtime = PluginRuntime.fromPlugins(
      [_Plugin('a'), _Plugin('b'), _Plugin('c')],
    );
    List<String> ids() => [for (final s in scopesOf(runtime)) s.pluginId];

    final before = ids();
    runtime.setEnabled('a', false);
    final disabled = ids();
    runtime.setEnabled('a', true);
    final reenabled = ids();

    expect(before, ['a', 'b', 'c']);
    expect(disabled, ['b', 'c']);
    expect(reenabled, ['a', 'b', 'c']);
    expect(
      [for (final s in scopesOf(runtime, role: {'c'})) s.pluginId],
      ['c'],
    );
  });

  test('a v2 plugin without the request capability cannot add a scope', () {
    final runtime = PluginRuntime();
    expect(
      () => runtime.install(AicovePlugin(
        id: 'x',
        name: 'x',
        capabilities: const {KernelCapability.tools},
        setup: (r) => r.add(
          AppContributions.requestScope,
          (_) => throw UnimplementedError(),
        ),
      )),
      throwsStateError,
    );
    expect(runtime.plugin('x'), isNull);
  });

  test('an image failure reminder that throws is skipped; the image scope '
      'still takes part with no failure reminder', () {
    final ref = container.read(_refProvider);
    // The registered instance only carries availability; the request scope
    // builds its own snapshot from the inputs.
    final runtime = PluginRuntime()
      ..install(ImagePlugin(const ImageConfig(), ref).agentPlugin);
    final broken = PluginRequestInputs(
      ref: ref,
      settings: inputs.settings.copyWith(imageGenerationEnabled: true),
      imageConfig: inputs.imageConfig,
      voiceRequest: inputs.voiceRequest,
      pluginPrompts: inputs.pluginPrompts,
      history: _BrokenHistory(),
      previousUserMessageTime: null,
      useFastImageRoute: false,
      useStableImageRoute: true,
      supportsToolCalling: true,
      customDrawingPrompt: '',
      reminders: inputs.reminders,
    );

    final scope = runtime
        .requestScopes(runtime.snapshot(), runtime.selectForRole(null), broken)
        .single;

    expect(scope.active, isTrue);
    expect(scope.reminders(DateTime(2026)), isEmpty);
    expect(collectPluginReminders([scope], DateTime(2026)), isEmpty);
  });

  group('reminders (ADR0063)', () {
    test('sorted by order, ties keep plugin order, empty ones dropped', () {
      final scopes = [
        _ReminderScope(_Plugin('late'), () => const [
              PluginReminder(30, 'late'),
              PluginReminder(10, 'early-from-late'),
            ]),
        _ReminderScope(_Plugin('mid'), () => const [
              PluginReminder(10, 'early-from-mid'),
              PluginReminder(20, ''),
            ]),
      ];
      expect(collectPluginReminders(scopes, DateTime(2026)),
          ['early-from-late', 'early-from-mid', 'late']);
    });

    test('a plugin whose reminders throw is skipped without blocking others',
        () {
      final scopes = [
        _ReminderScope(_Plugin('bad'), () => throw StateError('boom')),
        _ReminderScope(
            _Plugin('good'), () => const [PluginReminder(10, 'ok')]),
      ];
      expect(collectPluginReminders(scopes, DateTime(2026)), ['ok']);
    });
  });
}
