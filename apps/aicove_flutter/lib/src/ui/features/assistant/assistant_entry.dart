import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/assistant/application/assistant_onboarding_controller.dart';
import '../../../features/assistant/domain/assistant_onboarding.dart';
import '../../../features/chat/conversation_providers.dart';
import '../../../features/chat/domain/conversation.dart';
import '../../../features/settings/app_settings.dart';
import '../../shared/widgets/moe_adaptive_shell.dart';

/// Opens the assistant chat the same way tapping its contact does.
Future<void> openAssistantChat(
  BuildContext context,
  WidgetRef ref, {
  Conversation? assistant,
}) async {
  final conv =
      assistant ??
      (await ref.read(
        conversationsProvider.future,
      )).where((c) => c.id == kAicoveAssistantId).firstOrNull;
  if (conv == null || !context.mounted) return;
  ref.read(activeConversationIdProvider.notifier).state = conv.id;
  MoeWorkspace.openLocation(context, '/chat/${conv.id}', extra: conv);
}

/// First launch without a usable model: open the script once by itself.
Future<void> maybeAutoOpenAssistant(BuildContext context, WidgetRef ref) async {
  // `ref` belongs to the calling widget and throws once it is disposed, so
  // check after every wait.
  final onboarding = await ref.read(assistantOnboardingProvider.future);
  if (!onboarding.isPending || onboarding.autoOpened || !context.mounted) {
    return;
  }
  final settings = await ref.read(appSettingsProvider.future);
  if (hasUsableChatModel(settings) || !context.mounted) return;
  await ref.read(assistantOnboardingProvider.notifier).markAutoOpened();
  if (context.mounted) await openAssistantChat(context, ref);
}

