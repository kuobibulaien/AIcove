import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_logger.dart';
import '../../../core/database/database_provider.dart';
import '../../chat/domain/conversation.dart';
import '../../voice_call/application/active_voice_call.dart';
import '../../voice_call/providers/voice_call_providers.dart';
import 'incoming_call_notification.dart';
import 'proactive_call_ledger.dart';
import 'proactive_reply_generator.dart';

final proactiveCallLedgerProvider = Provider<ProactiveCallLedger>(
  (ref) => ProactiveCallLedger(ref.watch(databaseProvider)),
);

/// A proactive call shown on the incoming-call screen (plan 12, §13).
class IncomingCall {
  const IncomingCall({
    required this.conversation,
    required this.openingLine,
    required this.triggerId,
    this.answered = false,
  });

  final Conversation conversation;

  /// Spoken by the role as soon as the user picks up.
  final String openingLine;
  final String triggerId;

  /// Already answered from the background notification: the screen connects
  /// right away instead of ringing again.
  final bool answered;
}

/// The call on screen right now. Its lasting state lives in
/// [ProactiveCallLedger]; this only drives the screen.
final incomingCallProvider =
    NotifierProvider<IncomingCallNotifier, IncomingCall?>(
      IncomingCallNotifier.new,
    );

/// How long an in-app call rings before counting as missed; tests shorten it.
final incomingCallRingTimeoutProvider = Provider<Duration>(
  (_) => const Duration(seconds: 30),
);

class IncomingCallNotifier extends Notifier<IncomingCall?> {
  Timer? _timeout;

  @override
  IncomingCall? build() {
    ref.onDispose(() => _timeout?.cancel());
    return null;
  }

  /// Whether a call is on screen or a voice call is in progress.
  bool get busy => state != null || ref.read(activeVoiceCallProvider) != null;

  /// Shows a call already reserved in the ledger; false when busy. It rings
  /// until [until], then counts as missed.
  bool show(IncomingCall call, {required DateTime until}) {
    if (busy) return false;
    state = call;
    _timeout?.cancel();
    final left = until.difference(DateTime.now());
    _timeout = Timer(
      left.isNegative ? Duration.zero : left,
      () => unawaited(_missed(call)),
    );
    AppLogger.info(
      'ProactiveCall',
      '角色来电响铃',
      metadata: {
        'conversationId': call.conversation.id,
        'triggerId': call.triggerId,
      },
    );
    return true;
  }

  /// Picks up: the call connects and the role speaks the opening line.
  /// Null when the call was already missed or handled elsewhere.
  Future<ActiveVoiceCall?> accept() async {
    final call = _take();
    if (call == null) return null;
    if (!await ref.read(proactiveCallLedgerProvider).answer(call.triggerId)) {
      return null;
    }
    return ref
        .read(activeVoiceCallProvider.notifier)
        .start(call.conversation, openingLine: call.openingLine);
  }

  /// Declined: a missed-call bubble, nothing sent in its place.
  Future<void> decline() async {
    final call = _take();
    if (call != null) await _missed(call);
  }

  /// Takes the call off screen without an outcome (its delivery was taken
  /// over, so the caller gives the ledger slot back).
  void dismiss() => _take();

  Future<void> _missed(IncomingCall call) async {
    if (identical(state, call)) _take();
    await ref.read(proactiveCallLedgerProvider).miss(call.triggerId);
    await ref.read(proactiveCallSettlerProvider).settle();
  }

  IncomingCall? _take() {
    _timeout?.cancel();
    _timeout = null;
    final call = state;
    state = null;
    return call;
  }
}

/// Settles proactive calls from every path: writes each missed call's bubble
/// exactly once, shows a call that still rings in the app, and wakes up at the
/// next deadline (plan 12, §13). Runs when the app starts or resumes and after
/// every outcome.
final proactiveCallSettlerProvider = Provider<ProactiveCallSettler>((ref) {
  final settler = ProactiveCallSettler(ref);
  ref.onDispose(settler.dispose);
  return settler;
});

class ProactiveCallSettler {
  ProactiveCallSettler(this._ref);

  final Ref _ref;
  Timer? _wake;
  Future<void>? _running;
  bool _again = false;

  ProactiveCallLedger get _ledger => _ref.read(proactiveCallLedgerProvider);

  /// Concurrent calls share one run; a call during a run runs once more after.
  Future<void> settle() {
    final running = _running;
    if (running != null) {
      _again = true;
      return running;
    }
    return _running = _loop().whenComplete(() => _running = null);
  }

  Future<void> _loop() async {
    do {
      _again = false;
      await _settle();
    } while (_again);
  }

  Future<void> _settle() async {
    try {
      await _ledger.expire();
      for (final call in await _ledger.unsettledMissed()) {
        // Write first, then mark: a crash in between rewrites the same bubble.
        await _ref
            .read(voiceCallArchiverProvider)
            .archiveMissed(
              call.conversationId,
              key: call.triggerId,
              at: call.answerUntil,
            );
        await _ledger.markSettled(call.triggerId);
        await _cancelNotification(call.triggerId);
      }
      await _showStillRinging();
      _scheduleWake(await _ledger.nextDeadline());
      await _ledger.prune();
    } catch (e) {
      AppLogger.warning('ProactiveCall', '来电结算失败：$e');
      _scheduleWake(DateTime.now().add(_retryAfterFailure));
    }
  }

  static const Duration _retryAfterFailure = Duration(seconds: 15);

  /// A call that rang while the app was away and can still be answered.
  Future<void> _showStillRinging() async {
    final notifier = _ref.read(incomingCallProvider.notifier);
    if (notifier.busy) return;
    final call = await _ledger.ringing();
    if (call == null) return;
    final conversation = await _ref
        .read(proactiveReplyGeneratorProvider)
        .loadConversation(call.conversationId);
    if (conversation == null) {
      await _ledger.miss(call.triggerId);
      _again = true;
      return;
    }
    if (notifier.show(
      IncomingCall(
        conversation: conversation,
        openingLine: call.openingLine,
        triggerId: call.triggerId,
      ),
      until: call.answerUntil,
    )) {
      await _cancelNotification(call.triggerId);
    }
  }

  void _scheduleWake(DateTime? at) {
    _wake?.cancel();
    if (at == null) return;
    final left = at.difference(DateTime.now());
    _wake = Timer(
      (left.isNegative ? Duration.zero : left) + const Duration(seconds: 1),
      () => unawaited(settle()),
    );
  }

  Future<void> _cancelNotification(String triggerId) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await FlutterLocalNotificationsPlugin().cancel(
        incomingCallNotificationId(triggerId),
      );
    } catch (_) {}
  }

  void dispose() => _wake?.cancel();
}

/// Taps on the background incoming-call notification (Android): "accept" or
/// the notification itself connects while the call may still be answered;
/// "decline" marks it missed.
final incomingCallNotificationBridgeProvider =
    Provider<IncomingCallNotificationBridge>(
      IncomingCallNotificationBridge.new,
    );

class IncomingCallNotificationBridge {
  IncomingCallNotificationBridge(this._ref);

  final Ref _ref;
  bool _started = false;

  /// Listens for taps and settles what happened while the app was away.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    if (defaultTargetPlatform == TargetPlatform.android) {
      final plugin = FlutterLocalNotificationsPlugin();
      await plugin.initialize(
        incomingCallNotificationSettings,
        onDidReceiveNotificationResponse: (response) =>
            unawaited(handleResponse(response.payload, response.actionId)),
        onDidReceiveBackgroundNotificationResponse:
            onIncomingCallBackgroundResponse,
      );
      final launch = await plugin.getNotificationAppLaunchDetails();
      final response = launch?.notificationResponse;
      if (launch?.didNotificationLaunchApp == true && response != null) {
        await handleResponse(response.payload, response.actionId);
      }
    }
    await _ref.read(proactiveCallSettlerProvider).settle();
  }

  Future<void> handleResponse(String? payload, String? actionId) async {
    final triggerId = incomingCallTriggerIdOf(payload);
    if (triggerId == null) return;
    final ledger = _ref.read(proactiveCallLedgerProvider);
    final settler = _ref.read(proactiveCallSettlerProvider);
    if (actionId == incomingCallDeclineAction) {
      await ledger.miss(triggerId);
      await settler.settle();
      return;
    }
    final notifier = _ref.read(incomingCallProvider.notifier);
    final shown = _ref.read(incomingCallProvider);
    if (shown?.triggerId == triggerId) {
      // Already ringing in the app (it resumed first): answer that one.
      notifier.dismiss();
    }
    final call = await ledger.ringing();
    if (call == null || call.triggerId != triggerId || notifier.busy) {
      await settler.settle();
      return;
    }
    final conversation = await _ref
        .read(proactiveReplyGeneratorProvider)
        .loadConversation(call.conversationId);
    if (conversation == null ||
        !notifier.show(
          IncomingCall(
            conversation: conversation,
            openingLine: call.openingLine,
            triggerId: call.triggerId,
            answered: true,
          ),
          until: call.answerUntil,
        )) {
      await ledger.miss(triggerId);
      await settler.settle();
    }
  }
}
