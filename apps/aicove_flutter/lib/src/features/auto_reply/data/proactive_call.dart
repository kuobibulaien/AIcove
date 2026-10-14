import 'package:aicove_agent_kernel/aicove_agent_kernel.dart' show ToolEffect;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/providers/provider_adapter.dart' show ToolCall;
import '../../../core/prompts/prompt_builtin_defaults.g.dart';
import '../../chat/domain/conversation.dart';
import '../../plugins/domain/handlers/ai_tool.dart';
import '../../plugins/domain/handlers/tool_parameter.dart';
import '../../settings/app_settings.dart';
import '../../voice_call/providers/voice_call_providers.dart';
import '../domain/proactive_action.dart';
import 'incoming_call.dart';

/// Why [conversation]'s role may not call right now; null when it may.
typedef ProactiveCallGate = Future<String?> Function(Conversation conversation);

/// Proactive calls ring in the foreground on Android and macOS, and through
/// a notification when the Android app is in the background. iOS cannot wake
/// the app without a push server, so the option is not offered there.
bool proactiveCallsSupported(TargetPlatform platform) =>
    !kIsWeb &&
    (platform == TargetPlatform.android || platform == TargetPlatform.macOS);

/// The conditions of plan 12 §4.8 that hold for a whole call: the user's
/// switch, the platform, the missed-call pause and a voice the role can
/// speak with. Quiet hours and "one call at a time" are checked at ring time.
final proactiveCallGateProvider = Provider<ProactiveCallGate>(
  (ref) => (conversation) async {
    final settings = await ref.read(appSettingsProvider.future);
    if (!settings.autoReplySettings.allowProactiveCalls) return '没有开启主动来电';
    if (!proactiveCallsSupported(defaultTargetPlatform)) {
      return '这个平台不支持主动来电';
    }
    if (await ref
        .read(proactiveCallLedgerProvider)
        .callsPaused(conversation.id)) {
      return '连续没接，暂停主动来电，等用户回消息';
    }
    return ref.read(voiceCallFactoryProvider).unavailableReason(conversation);
  },
);

/// The `call_user` tool offered while writing ahead. Calling it only records
/// the opening line through [onCall]; the call rings at fire time.
AITool buildCallUserTool({required void Function(String line) onCall}) =>
    AITool(
      name: ProactiveAction.callUser.id,
      description: PromptBuiltinDefaults.requireTemplate(
        'auto_reply.tool.call_user',
      ),
      parameters: {
        callUserOpeningLineArg: ToolParameter(
          type: 'string',
          description: PromptBuiltinDefaults.requireTemplate(
            'auto_reply.tool.call_user.opening_line',
          ),
          required: true,
        ),
      },
      effect: ToolEffect.write,
      handler: (args) async {
        final line = openingLineOf(args);
        if (line == null) return '缺少 $callUserOpeningLineArg，没有打出去。';
        onCall(line);
        return '已经记下了，到时间就打过去。';
      },
    );

/// The opening line of the first `call_user` call in [toolCalls], if any.
String? openingLineFromToolCalls(List<ToolCall> toolCalls) {
  for (final call in toolCalls) {
    if (call.name != ProactiveAction.callUser.id) continue;
    final line = openingLineOf(call.arguments);
    if (line != null) return line;
  }
  return null;
}

String? openingLineOf(Map<String, dynamic> args) {
  final raw = args[callUserOpeningLineArg];
  final line = raw is String ? raw.trim() : '';
  return line.isEmpty ? null : line;
}
