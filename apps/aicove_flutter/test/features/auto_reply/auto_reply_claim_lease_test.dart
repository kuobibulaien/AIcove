import 'dart:io';

import 'package:aicove_flutter/src/core/database/database.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/auto_reply_claim_store.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t0 = DateTime(2026, 10, 12, 9);
  final afterLease =
      t0.add(AutoReplyClaimStore.lease + const Duration(seconds: 1));
  const fg = AutoReplyClaimOwner.foreground;
  const bg = AutoReplyClaimOwner.background;

  late AppDatabase db;
  late AutoReplyClaimStore store;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    store = AutoReplyClaimStore(db);
  });
  tearDown(() => db.close());

  test('an in-flight claim blocks others until its lease expires', () async {
    expect(await store.tryClaim(triggerId: 't', claimedBy: bg, now: t0),
        isNotNull);
    expect(
      await store.tryClaim(
        triggerId: 't',
        claimedBy: fg,
        now: t0.add(const Duration(minutes: 9)),
      ),
      isNull,
    );
    expect(await store.stateOf('t', now: t0), isA<AutoReplyClaimHeld>());
    // The holder was killed mid-send: after the lease the next attempt
    // takes over.
    expect(
      await store.tryClaim(triggerId: 't', claimedBy: fg, now: afterLease),
      isNotNull,
    );
  });

  test('a taken-over holder can neither deliver nor release the new claim',
      () async {
    final old = (await store.tryClaim(triggerId: 't', claimedBy: bg, now: t0))!;
    final current =
        (await store.tryClaim(triggerId: 't', claimedBy: fg, now: afterLease))!;

    await store.release('t', old);
    expect(await store.beginDelivery('t', old), isFalse);
    expect(await store.beginDelivery('t', current), isTrue);
    expect(await store.stateOf('t'), isA<AutoReplyClaimDelivered>());
  });

  test('only the current token is current; a delivery records its message',
      () async {
    final old = (await store.tryClaim(triggerId: 't', claimedBy: bg, now: t0))!;
    final current =
        (await store.tryClaim(triggerId: 't', claimedBy: fg, now: afterLease))!;
    expect(await store.isCurrent('t', old), isFalse);
    expect(await store.isCurrent('t', current), isTrue);

    await store.beginDelivery('t', current, messageId: 'm1', now: afterLease);
    expect(await store.isCurrent('t', current), isTrue);
    final state = await store.stateOf('t') as AutoReplyClaimDelivered;
    expect(state.messageId, 'm1');
    // A delivery is only treated as interrupted a full lease after it began.
    expect(state.isStalled(afterLease.add(const Duration(minutes: 9))), isFalse);
    expect(state.isStalled(afterLease.add(AutoReplyClaimStore.lease)), isTrue);
  });

  test('renewing restarts the lease; only an undelivered current claim renews',
      () async {
    final token = (await store.tryClaim(triggerId: 't', claimedBy: fg, now: t0))!;
    expect(await store.renew('t', token, now: afterLease), isTrue);
    // Without the renewal this claim would be free to take over now.
    expect(
      await store.tryClaim(
        triggerId: 't',
        claimedBy: bg,
        now: afterLease.add(const Duration(minutes: 9)),
      ),
      isNull,
    );
    expect(await store.renew('t', 'other'), isFalse);
    await store.beginDelivery('t', token);
    expect(await store.renew('t', token), isFalse);
  });

  test('a delivered claim is never taken over', () async {
    final token = (await store.tryClaim(triggerId: 't', claimedBy: bg, now: t0))!;
    expect(await store.beginDelivery('t', token), isTrue);
    expect(
      await store.tryClaim(
        triggerId: 't',
        claimedBy: fg,
        now: t0.add(const Duration(hours: 3)),
      ),
      isNull,
    );
    // Releasing after delivery started is a no-op.
    await store.release('t', token);
    expect(await store.stateOf('t'), isA<AutoReplyClaimDelivered>());
  });

  test('release and abortDelivery let the next attempt claim at once',
      () async {
    final first = (await store.tryClaim(triggerId: 't', claimedBy: bg, now: t0))!;
    await store.release('t', first);
    final second = (await store.tryClaim(triggerId: 't', claimedBy: fg, now: t0))!;
    await store.beginDelivery('t', second);
    await store.abortDelivery('t', second);
    expect(await store.tryClaim(triggerId: 't', claimedBy: bg, now: t0),
        isNotNull);
  });

  test('cleanup keeps the claims of triggers that are still active',
      () async {
    final token = (await store.tryClaim(triggerId: 'live', claimedBy: bg, now: t0))!;
    await store.beginDelivery('live', token, now: t0);
    await store.tryClaim(triggerId: 'done', claimedBy: bg, now: t0);

    await store.cleanupBefore(
      t0.add(const Duration(days: 1)),
      keepTriggerIds: {'live'},
    );

    expect(await store.stateOf('live'), isA<AutoReplyClaimDelivered>());
    expect(await store.stateOf('done'), isA<AutoReplyClaimFree>());
    // Without the kept record the live trigger could be claimed and sent again.
    expect(await store.tryClaim(triggerId: 'live', claimedBy: fg), isNull);
  });

  test('an old claims table gains completed_at; old claims count as done',
      () async {
    final dir = await Directory.systemTemp.createTemp('claims_');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/old.sqlite');

    final first = AppDatabase.forTesting(NativeDatabase(file));
    await first.customStatement('DROP TABLE auto_reply_trigger_claims');
    await first.customStatement('''
CREATE TABLE auto_reply_trigger_claims (
  trigger_id TEXT NOT NULL PRIMARY KEY,
  claimed_by TEXT NOT NULL,
  claimed_at INTEGER NOT NULL
)''');
    await first.customStatement(
      "INSERT INTO auto_reply_trigger_claims VALUES ('old', 'background', "
      '${t0.millisecondsSinceEpoch})',
    );
    await first.close();

    final reopened = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(reopened.close);
    final claims = AutoReplyClaimStore(reopened);
    expect(
      await claims.tryClaim(
        triggerId: 'old',
        claimedBy: fg,
        now: t0.add(const Duration(hours: 1)),
      ),
      isNull,
    );
    final token = await claims.tryClaim(triggerId: 'new', claimedBy: fg);
    expect(await claims.beginDelivery('new', token!, messageId: 'm'), isTrue);
    expect(
      (await claims.stateOf('new') as AutoReplyClaimDelivered).messageId,
      'm',
    );
  });
}
