import 'dart:ui';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../../../core/database/database.dart';
import 'proactive_call_ledger.dart';

/// The Android notification of a proactive call that rang while the app was
/// in the background (plan 12, §13). Shared by the WorkManager isolate that
/// posts it and the isolates that handle its buttons.

/// Payload prefix; the rest is the trigger id.
const String incomingCallPayloadPrefix = 'incoming_call:';
const String incomingCallAcceptAction = 'accept';
const String incomingCallDeclineAction = 'decline';
const String incomingCallChannelId = 'incoming_call_channel';

/// How long the notification rings. Answering it a little later still
/// connects, see [backgroundCallAnswerWindow].
const Duration backgroundCallRingTime = Duration(seconds: 30);

/// A background call counts as missed after this.
const Duration backgroundCallAnswerWindow = Duration(minutes: 1);

/// One notification id per trigger, apart from message notifications.
int incomingCallNotificationId(String triggerId) =>
    0x40000000 | (triggerId.hashCode & 0x0FFFFFFF);

String? incomingCallTriggerIdOf(String? payload) =>
    payload != null && payload.startsWith(incomingCallPayloadPrefix)
    ? payload.substring(incomingCallPayloadPrefix.length)
    : null;

const InitializationSettings incomingCallNotificationSettings =
    InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    );

Future<void> showIncomingCallNotification({
  required String triggerId,
  required String characterName,
}) async {
  final plugin = FlutterLocalNotificationsPlugin();
  await plugin.initialize(incomingCallNotificationSettings);
  await plugin.show(
    incomingCallNotificationId(triggerId),
    characterName,
    '邀请你语音通话…',
    NotificationDetails(
      android: AndroidNotificationDetails(
        incomingCallChannelId,
        '角色来电',
        channelDescription: '角色主动打来的语音电话',
        importance: Importance.max,
        priority: Priority.max,
        category: AndroidNotificationCategory.call,
        timeoutAfter: backgroundCallRingTime.inMilliseconds,
        actions: const [
          AndroidNotificationAction(
            incomingCallDeclineAction,
            '拒绝',
            cancelNotification: true,
          ),
          AndroidNotificationAction(
            incomingCallAcceptAction,
            '接听',
            showsUserInterface: true,
            cancelNotification: true,
          ),
        ],
      ),
    ),
    payload: '$incomingCallPayloadPrefix$triggerId',
  );
}

/// "Decline" without opening the app runs here, in its own isolate: it only
/// marks the call missed; the app writes the missed-call bubble when it next
/// settles calls.
@pragma('vm:entry-point')
Future<void> onIncomingCallBackgroundResponse(
  NotificationResponse response,
) async {
  final triggerId = incomingCallTriggerIdOf(response.payload);
  if (triggerId == null || response.actionId != incomingCallDeclineAction) {
    return;
  }
  DartPluginRegistrant.ensureInitialized();
  final db = AppDatabase();
  try {
    await ProactiveCallLedger(db).miss(triggerId);
  } finally {
    await db.close();
  }
}
