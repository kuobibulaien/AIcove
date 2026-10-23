import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_logger.dart';
import '../../core/services/system_reminder_service.dart';
import '../agent_context/domain/silly_tavern_preset.dart';
import '../chat/domain/message.dart';
import '../plugins/domain/handlers/ai_tool.dart';
import '../plugins/image/image_config.dart';
import '../plugins/prompts/plugin_prompts.dart';
import '../plugins/prompts/prompt_pack.dart';
import '../plugins/tts/voice_request.dart';
import '../settings/app_settings.dart';
import 'plugin_request_context.dart';

/// Inputs fixed at the start of one request, before any contribution is
/// collected. A plugin builds its [PluginRequestScope] from these.
class PluginRequestInputs {
  const PluginRequestInputs({
    required this.ref,
    required this.settings,
    required this.imageConfig,
    required this.voiceRequest,
    required this.pluginPrompts,
    required this.history,
    required this.previousUserMessageTime,
    required this.useFastImageRoute,
    required this.useStableImageRoute,
    required this.supportsToolCalling,
    required this.reminders,
    this.boundPreset,
    this.voicePrompts,
    this.imagePrompts,
    this.rolePluginIds,
  });

  final Ref ref;
  final AppSettings settings;
  final ImageConfig imageConfig;
  final VoiceRequest voiceRequest;
  final PluginPrompts pluginPrompts;

  /// Raw-derived history for this request (read only).
  final List<Message> history;
  final DateTime? previousUserMessageTime;
  final bool useFastImageRoute;
  final bool useStableImageRoute;
  final bool supportsToolCalling;
  final SystemReminderService reminders;

  /// Prompt packs resolved from this request's voice and drawing presets
  /// (ADR0092); null when the plugin is off or its bound pack is missing.
  final ResolvedPromptPack? voicePrompts;
  final ResolvedPromptPack? imagePrompts;

  /// The preset bound for this request's owner, resolved once (ADR0042).
  final SillyTavernPreset? boundPreset;

  /// The request owner's raw plugin list (null = all plugins), for plugins
  /// that read per-role grants from it.
  final Set<String>? rolePluginIds;
}

/// Output tag reminders the core knows how to phrase. Plugins declare which
/// apply; the core keeps one fixed wording and order.
enum OutputTagHint { imageInline, imageTool, tts }

/// Time context facts recorded in the request's runtime-context trace.
class TimeContextTrace {
  const TimeContextTrace({
    required this.pluginName,
    required this.enabled,
    required this.config,
  });

  final String pluginName;
  final bool enabled;
  final Map<String, dynamic> config;
}

/// A pre-request reminder (ADR0063). Lower [order] comes first; ties keep
/// plugin order.
class PluginReminder {
  const PluginReminder(this.order, this.content);
  final int order;
  final String content;
}

/// What one plugin contributes to one request. Created per request from the
/// [PluginRequestInputs]; a plugin fixes its configuration snapshot here.
abstract class PluginRequestScope {
  String get pluginId;
  String get pluginName;

  /// False when the plugin is off for this request; its context is then
  /// filtered out (ADR0017).
  bool get active;

  Future<String?> prompt(PluginRequestContext ctx) async => null;

  /// [requestTime] is read after history assembly, as before batch 2b.
  List<PluginReminder> reminders(DateTime requestTime) => const [];

  List<AITool> tools() => const [];

  /// Final adjustment of provider tool schemas (all plugins' tools).
  List<Map<String, dynamic>> rewriteToolSchemas(
    List<Map<String, dynamic>> schemas,
  ) =>
      schemas;

  Set<OutputTagHint> get outputTags => const {};

  /// True when the plugin takes over web search from the model provider.
  bool get disablesBuiltinWebSearch => false;

  /// Set by the plugin that owns time awareness, for the request trace.
  TimeContextTrace? get timeContextTrace => null;

  /// Preset tag names for the output tag reminder, after the core hints.
  List<String> get presetTagNames => const [];

  /// Adjusts the request copy of the history after the context policy;
  /// raw history is never changed.
  List<Map<String, dynamic>> filterRequestMessages(
    List<Map<String, dynamic>> messages,
  ) =>
      messages;
}

typedef PluginRequestScopeFactory = PluginRequestScope Function(
  PluginRequestInputs inputs,
);

/// Collects reminders from [scopes] in ADR0063 order: by [PluginReminder.order],
/// ties in plugin order. A plugin whose reminders throw is skipped and logged;
/// it never blocks the request.
List<String> collectPluginReminders(
  List<PluginRequestScope> scopes,
  DateTime requestTime,
) {
  final reminders = <(int, PluginReminder)>[];
  for (final scope in scopes) {
    try {
      for (final reminder in scope.reminders(requestTime)) {
        if (reminder.content.isEmpty) continue;
        reminders.add((reminders.length, reminder));
      }
    } catch (e) {
      AppLogger.warning('PluginRequestScope', '插件提醒构建失败，已跳过',
          metadata: {'pluginId': scope.pluginId, 'error': e.toString()});
    }
  }
  reminders.sort((a, b) {
    final byOrder = a.$2.order.compareTo(b.$2.order);
    return byOrder != 0 ? byOrder : a.$1.compareTo(b.$1);
  });
  return [for (final (_, reminder) in reminders) reminder.content];
}
