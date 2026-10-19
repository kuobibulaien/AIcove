import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../chat/application/chat_page_conversation_actions.dart';
import '../../chat/conversation_providers.dart';
import '../../settings/app_settings.dart';
import '../../settings/provider_detail/provider_detail_actions.dart';
import '../domain/assistant_onboarding.dart';

/// Scripted onboarding of the AIcove assistant (ADR0073, phase one). The
/// progress is a local UI state and never enters the message table; only the
/// closing greeting is written as an ordinary assistant message.
class AssistantOnboardingController extends AsyncNotifier<OnboardingState> {
  static const prefsKey = 'assistant_onboarding_v1';

  /// Opening line written once the key works; the next reply comes from the
  /// real model.
  static const completionGreeting =
      '接好啦！从现在起我就能真正思考和回答了。\n'
      '关于 AIcove 的任何问题都可以直接问我，比如「怎么导入角色卡」「怎么给角色换声音」。';

  @override
  Future<OnboardingState> build() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(prefsKey);
    if (raw == null) return const OnboardingState();
    try {
      return OnboardingState.fromJson(
        (jsonDecode(raw) as Map).cast<String, Object?>(),
      );
    } catch (_) {
      return const OnboardingState();
    }
  }

  Future<void> _set(OnboardingState next) async {
    state = AsyncValue.data(next);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(prefsKey, jsonEncode(next.toJson()));
  }

  Future<OnboardingState> _current() => future;

  Future<void> chooseExperience({required bool experienced}) async {
    final current = await _current();
    await _set(
      current.copyWith(
        experienced: experienced,
        step: OnboardingStep.chooseProvider,
      ),
    );
  }

  Future<void> chooseRecommended() async {
    final current = await _current();
    await _set(
      current.copyWith(
        step: current.experienced
            ? OnboardingStep.pasteKey
            : OnboardingStep.getKey,
      ),
    );
  }

  Future<void> chooseOther() async =>
      _set((await _current()).copyWith(step: OnboardingStep.otherProvider));

  Future<void> goTo(OnboardingStep step) async =>
      _set((await _current()).copyWith(step: step));

  Future<void> skipAll() async =>
      _set((await _current()).copyWith(outcome: OnboardingOutcome.skipped));

  Future<void> markAutoOpened() async =>
      _set((await _current()).copyWith(autoOpened: true));

  /// Starts the script over from the settings page entry.
  Future<void> restart() async => _set(const OnboardingState(autoOpened: true));

  /// Tests [apiKey] against the recommended provider before saving it, so a
  /// wrong key never lands in the settings. Returns null on success.
  Future<KeyCheckFailure?> submitRecommendedKey(String apiKey) async {
    final key = apiKey.trim();
    if (key.isEmpty) return KeyCheckFailure.invalidKey;
    final settings = await ref.read(appSettingsProvider.future);
    final provider = settings.getProvider(kOnboardingRecommendedProviderId);
    if (provider == null) return KeyCheckFailure.other;
    final modelId = provider.visibleModels.isNotEmpty
        ? provider.visibleModels.first
        : provider.models.isNotEmpty
        ? provider.models.first
        : null;
    if (modelId == null) return KeyCheckFailure.other;

    final failure = await _test(provider, key, modelId);
    if (failure != null) return failure;

    final notifier = ref.read(appSettingsProvider.notifier);
    await notifier.editProvider(providerId: provider.id, apiKeys: [key]);
    if (!provider.enabled) {
      await notifier.setProviderEnabled(provider.id, true);
    }
    await _complete(settings, provider.id, modelId);
    return null;
  }

  /// Finishes with a provider the user added through the add-provider sheet.
  Future<KeyCheckFailure?> useProviderModel({
    required String providerId,
    required String modelId,
  }) async {
    final settings = await ref.read(appSettingsProvider.future);
    final provider = settings.getProvider(providerId);
    if (provider == null) return KeyCheckFailure.other;
    final actions = ref.read(providerDetailActionsProvider);
    final failure = await _test(
      provider,
      actions.resolvePrimaryApiKey(provider),
      modelId,
    );
    if (failure != null) return failure;
    // A disabled provider is left out of request assembly; the model the user
    // just tested must actually be usable.
    if (!provider.enabled) {
      await ref
          .read(appSettingsProvider.notifier)
          .setProviderEnabled(providerId, true);
    }
    await _complete(settings, providerId, modelId);
    return null;
  }

  Future<KeyCheckFailure?> _test(
    ProviderAuth provider,
    String apiKey,
    String modelId,
  ) async {
    try {
      await ref
          .read(providerDetailActionsProvider)
          .testModel(provider: provider, apiKey: apiKey, modelId: modelId);
      return null;
    } catch (error) {
      return classifyKeyCheckError(error);
    }
  }

  Future<void> _complete(
    AppSettings settings,
    String providerId,
    String modelId,
  ) async {
    final modelRef = settings.buildModelRef(providerId, modelId);
    await ref.read(appSettingsProvider.notifier).setDefaultChatModels([
      modelRef,
      for (final other in settings.defaultChatModels)
        if (other != modelRef) other,
    ]);
    final assistant = ref
        .read(conversationsProvider)
        .valueOrNull
        ?.where((c) => c.id == kAicoveAssistantId)
        .firstOrNull;
    if (assistant != null) {
      await ref
          .read(chatPageConversationActionsProvider)
          .appendCharacterGreeting(
            kAicoveAssistantId,
            greeting: completionGreeting,
            charName: assistant.displayName,
            recipeId: assistant.recipeId,
          );
    }
    await _set(
      (await _current()).copyWith(outcome: OnboardingOutcome.completed),
    );
  }
}

final assistantOnboardingProvider =
    AsyncNotifierProvider<AssistantOnboardingController, OnboardingState>(
      AssistantOnboardingController.new,
    );

/// Whether the assistant chat shows the script instead of the message list.
final assistantScriptActiveProvider = Provider<bool>((ref) {
  final onboarding = ref.watch(assistantOnboardingProvider).valueOrNull;
  final settings = ref.watch(appSettingsProvider).valueOrNull;
  if (onboarding == null || settings == null) return false;
  return onboarding.isPending && !hasUsableChatModel(settings);
});
