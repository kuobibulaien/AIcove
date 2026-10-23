import '../../../core/app_logger.dart';
import '../../agent_plugins/aicove_plugin.dart';
import '../../agent_plugins/plugin_request_context.dart';
import '../../agent_plugins/plugin_request_scope.dart';
import '../../agent_plugins/plugin_response.dart';
import '../domain/handlers/ai_tool.dart';
import 'draw_image_tool_schema.dart';
import 'image_plugin.dart';

/// Image generation on the v2 registrar. The registered instance only
/// carries availability; each request builds its own snapshot from the
/// request's drawing configuration and settings.
AicovePlugin imageAgentPlugin(ImagePlugin registered) => AicovePlugin(
      id: registered.id,
      name: registered.name,
      capabilities: const {AppCapability.request, AppCapability.responses},
      setup: (registrar) {
        registrar.add(AppContributions.requestScope, ImageRequestScope.new);
        registrar.add(AppContributions.responseProcessor, (inputs) {
          // A request reply records its drawing snapshot in the events; a
          // cached reply has none and uses the registered instance.
          final drawing = inputs.drawingConfig;
          final plugin = drawing == null
              ? registered
              : ImagePlugin(
                  drawing,
                  inputs.ref,
                  requestSettings: inputs.settings,
                  isRequestSnapshot: true,
                );
          return ResponseFunction(
            registered.id,
            (text) async => plugin.convertInlineImageTags(text),
          );
        });
      },
    );

class ImageRequestScope extends PluginRequestScope {
  ImageRequestScope(this.inputs)
      : snapshot = ImagePlugin(
          inputs.imageConfig,
          inputs.ref,
          requestSettings: inputs.settings,
          isRequestSnapshot: true,
          prompts: inputs.imagePrompts,
        ) {
    // Computed once so the prompt and the reminder agree. A failure here
    // drops the reminder (and its prompt hint) instead of blocking the
    // request, like any other reminder.
    try {
      _failure = snapshot.buildImageFailureReminderContent(inputs.history);
    } catch (e) {
      AppLogger.warning('ImagePlugin', '生图失败提醒构建失败，已跳过',
          metadata: {'error': e.toString()});
      _failure = null;
    }
  }

  final ImagePlugin snapshot;
  final PluginRequestInputs inputs;
  late final String? _failure;

  @override
  String get pluginId => snapshot.id;

  @override
  String get pluginName => snapshot.name;

  @override
  bool get active => snapshot.isUsable;

  @override
  Future<String?> prompt(PluginRequestContext ctx) async =>
      snapshot.buildRequestSystemPrompt(
        useFastRoute: inputs.useFastImageRoute,
        hasInternalImageContext: ctx.hasInternalImageContext,
        hasFailureReminder: _failure?.isNotEmpty ?? false,
      );

  /// ADR0063 order 20, after the time reminder.
  @override
  List<PluginReminder> reminders(DateTime requestTime) =>
      _failure == null || _failure.isEmpty
          ? const []
          : [PluginReminder(20, _failure)];

  /// The fast route draws through inline tags, so `draw_image` is not
  /// offered.
  @override
  List<AITool> tools() {
    final tools = snapshot.getTools();
    return inputs.useFastImageRoute
        ? [for (final tool in tools) if (tool.name != 'draw_image') tool]
        : tools;
  }

  /// Applies this request's prompt pack to the `draw_image` schema on the
  /// stable route. Matches by name across all collected schemas.
  @override
  List<Map<String, dynamic>> rewriteToolSchemas(
    List<Map<String, dynamic>> schemas,
  ) {
    if (!inputs.useStableImageRoute) return schemas;
    final drawImage = snapshot
        .getTools()
        .where((tool) => tool.name == 'draw_image')
        .firstOrNull;
    return drawImage == null
        ? schemas
        : applyDrawImageToolText(tools: schemas, drawImage: drawImage);
  }

  @override
  Set<OutputTagHint> get outputTags => !snapshot.enabled
      ? const {}
      : {
          if (inputs.useFastImageRoute) OutputTagHint.imageInline,
          if (inputs.useStableImageRoute && inputs.supportsToolCalling)
            OutputTagHint.imageTool,
        };
}
