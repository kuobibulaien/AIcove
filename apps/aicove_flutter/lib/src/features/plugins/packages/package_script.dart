import 'dart:convert';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart' show ToolEffect;

import '../../../core/app_logger.dart';
import '../../workspace/application/workspace_script.dart';
import '../domain/handlers/ai_tool.dart';
import 'aicove_package.dart';

/// Immutable registration snapshot. Every handler gets a fresh bounded session;
/// no JS state (including failed state) survives a call.
class PackageScript {
  PackageScript(this.package, {this.timeout = const Duration(seconds: 30)});
  final Duration timeout;
  final AicovePackage package;
  List<Map<String, dynamic>> _definitions = const [];
  List<String> prompts = const [];
  String? loadError;
  Future<void>? _loading;

  String toolName(String local) =>
      'pkg_${package.id.length}_${package.id}_$local';
  String get _source => utf8.decode(package.files[package.scriptMain]!);

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    if (package.scriptMain == null) return;
    try {
      String? metadata;
      final output =
          await WorkspaceScript.extension(
            runId: 'load_${package.id}',
            discoveryOnly: true,
          ).run(
            '$_registration\n$_source\nreturn JSON.stringify(__metadata());',
            timeout: timeout,
            captureReturn: (value) => metadata = value,
          );
      if (output.isError || metadata == null) throw StateError(output.text);
      final decoded = jsonDecode(metadata!) as Map;
      final definitions = (decoded['tools'] as List)
          .map((d) => Map<String, dynamic>.from(d as Map))
          .toList();
      final names = <String>{};
      for (final definition in definitions) {
        final name = definition['name'];
        if (name is! String ||
            !RegExp(r'^[a-zA-Z][a-zA-Z0-9_]*$').hasMatch(name) ||
            toolName(name).length > 64 ||
            !names.add(name) ||
            definition['description'] is! String ||
            definition['inputSchema'] is! Map ||
            (definition['inputSchema'] as Map)['type'] != 'object') {
          throw const FormatException(
            'Invalid or duplicate script tool declaration',
          );
        }
      }
      _definitions = definitions;
      prompts = (decoded['prompts'] as List).cast<String>();
    } catch (error) {
      loadError = '$error';
      _definitions = const [];
      prompts = const [];
      AppLogger.warning(
        'PackageScript',
        '脚本插件加载失败，已跳过',
        metadata: {'pluginId': package.pluginId, 'error': loadError},
      );
    }
  }

  List<AITool> tools() => [
    for (final definition in _definitions)
      AITool(
        name: toolName(definition['name'] as String),
        description: definition['description'] as String,
        parameters: const {},
        inputSchema: Map<String, dynamic>.from(
          definition['inputSchema'] as Map,
        ),
        effect: ToolEffect.external,
        executionTimeout: timeout,
        handler: (_) async => null,
        controlledHandler: (args, control) async {
          final context = ToolCallContext.current;
          final access = context?.scriptTools;
          final ownNames = {
            for (final d in _definitions) toolName(d['name'] as String),
          };
          final script = WorkspaceScript.extension(
            runId: context?.turnId ?? 'plugin_${package.id}',
            resources: package.files,
            isCancelled: () =>
                (control.cancellation?.isCancelled ?? false) ||
                (context?.isCancelled?.call() ?? false),
            tools: access == null
                ? null
                : ScriptToolAccess(
                    access.tools
                        .where((t) => !ownNames.contains(t.name))
                        .toList(),
                    access.invoke,
                  ),
          );
          return script.run(
            '$_registration\n$_source\n'
            'const __handler = __handlers.get(${jsonEncode(definition['name'])});\n'
            'if (!__handler) throw new Error("Registered handler unavailable");\n'
            'return await __handler(args);',
            args: args,
            timeout: timeout,
          );
        },
      ),
  ];
}

const _registration = r'''
const __handlers = new Map(), __definitions = [], __prompts = [];
const aicove = Object.freeze({
  registerTool: ({name, description, inputSchema, handler}) => {
    if (typeof handler !== 'function' || __handlers.has(name)) throw new Error('Invalid or duplicate handler');
    __handlers.set(name, handler);
    __definitions.push({name, description, inputSchema});
  },
  appendPrompt: value => {
    if (typeof value !== 'string') throw new Error('Prompt must be text');
    __prompts.push(value);
  },
});
const __metadata = () => ({tools: __definitions, prompts: __prompts});
''';
