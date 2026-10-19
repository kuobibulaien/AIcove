import 'dart:async';
import 'dart:io';

import '../../settings/provider_detail/provider_detail_support.dart';
import '../../settings/settings_models.dart';

/// Fixed id of the built-in AIcove assistant role (ADR0073), identical on
/// every device so its conversation syncs like any other role.
const kAicoveAssistantId = 'aicove_assistant';

/// The provider the script recommends; seeded by the default settings.
const kOnboardingRecommendedProviderId = 'deepseek';

/// Where the scripted onboarding stands on this device.
enum OnboardingStep {
  /// First card: ask about prior experience, or skip everything.
  experience,
  chooseProvider,

  /// Step-by-step guide to create a DeepSeek key (novices only).
  getKey,
  pasteKey,

  /// Another provider added through the regular add-provider sheet.
  otherProvider,
}

enum OnboardingOutcome { pending, skipped, completed }

class OnboardingState {
  const OnboardingState({
    this.step = OnboardingStep.experience,
    this.experienced = false,
    this.outcome = OnboardingOutcome.pending,
    this.autoOpened = false,
  });

  final OnboardingStep step;

  /// Chose "configured an API before": explanations are left out.
  final bool experienced;
  final OnboardingOutcome outcome;

  /// The assistant chat was opened by itself once on first launch.
  final bool autoOpened;

  bool get isPending => outcome == OnboardingOutcome.pending;

  OnboardingState copyWith({
    OnboardingStep? step,
    bool? experienced,
    OnboardingOutcome? outcome,
    bool? autoOpened,
  }) => OnboardingState(
    step: step ?? this.step,
    experienced: experienced ?? this.experienced,
    outcome: outcome ?? this.outcome,
    autoOpened: autoOpened ?? this.autoOpened,
  );

  Map<String, Object?> toJson() => {
    'step': step.name,
    'experienced': experienced,
    'outcome': outcome.name,
    'autoOpened': autoOpened,
  };

  factory OnboardingState.fromJson(Map<String, Object?> json) {
    T byName<T extends Enum>(List<T> values, Object? name, T fallback) =>
        values.firstWhere((v) => v.name == name, orElse: () => fallback);
    return OnboardingState(
      step: byName(
        OnboardingStep.values,
        json['step'],
        OnboardingStep.experience,
      ),
      experienced: json['experienced'] == true,
      outcome: byName(
        OnboardingOutcome.values,
        json['outcome'],
        OnboardingOutcome.pending,
      ),
      autoOpened: json['autoOpened'] == true,
    );
  }
}

/// Why a key or model check failed, in terms the script can explain.
enum KeyCheckFailure { invalidKey, insufficientBalance, network, other }

KeyCheckFailure classifyKeyCheckError(Object error) {
  if (error is TimeoutException ||
      error is SocketException ||
      error is HandshakeException) {
    return KeyCheckFailure.network;
  }
  final text = error.toString();
  if (RegExp(r'HTTP (401|403)\b').hasMatch(text)) {
    return KeyCheckFailure.invalidKey;
  }
  if (RegExp(r'HTTP 402\b').hasMatch(text) ||
      text.contains('Insufficient Balance')) {
    return KeyCheckFailure.insufficientBalance;
  }
  if (text.contains('TimeoutException') ||
      text.contains('SocketException') ||
      text.contains('Failed host lookup') ||
      text.contains('Connection refused')) {
    return KeyCheckFailure.network;
  }
  return KeyCheckFailure.other;
}

bool providerHasApiKey(ProviderAuth provider) {
  if (provider.apiKeys.any((key) => key.trim().isNotEmpty)) return true;
  return isProviderMultiKeyEnabled(provider) &&
      providerMultiKeyItemsFromProvider(
        provider,
      ).any((item) => item.enabled && item.key.trim().isNotEmpty);
}

/// The default chat model sits on an enabled chat provider that has a key.
/// Settings synced from another device count too.
bool hasUsableChatModel(AppSettings settings) {
  final providerId = settings.getModelProviderId(settings.defaultModelName);
  final provider = providerId == null ? null : settings.getProvider(providerId);
  return provider != null &&
      provider.enabled &&
      provider.capabilities.contains('chat') &&
      providerHasApiKey(provider);
}
