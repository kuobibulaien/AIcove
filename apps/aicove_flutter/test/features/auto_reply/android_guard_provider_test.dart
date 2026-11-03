import 'package:aicove_flutter/src/features/auto_reply/data/auto_reply_service.dart';
import 'package:aicove_flutter/src/features/sync/providers/lan_sync_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final proactiveCareInUse in [false, true]) {
    test('guard follows proactive care ($proactiveCareInUse) without LAN', () {
      var lanReads = 0;
      final container = ProviderContainer(
        overrides: [
          proactiveCareInUseProvider.overrideWithValue(proactiveCareInUse),
          lanSyncStateProvider.overrideWith((ref) {
            lanReads++;
            throw StateError('Guard must not read LAN state');
          }),
          lanSyncPortProvider.overrideWith((ref) {
            lanReads++;
            throw StateError('Guard must not initialize LAN');
          }),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(androidGuardNeededProvider), proactiveCareInUse);
      expect(lanReads, 0);
    });
  }

  test('guard updates when proactive care is enabled and disabled', () {
    final proactiveCare = StateProvider<bool>((ref) => false);
    final container = ProviderContainer(
      overrides: [
        proactiveCareInUseProvider.overrideWith(
          (ref) => ref.watch(proactiveCare),
        ),
      ],
    );
    addTearDown(container.dispose);
    final subscription = container.listen(
      androidGuardNeededProvider,
      (_, __) {},
    );
    addTearDown(subscription.close);

    expect(container.read(androidGuardNeededProvider), isFalse);
    container.read(proactiveCare.notifier).state = true;
    expect(container.read(androidGuardNeededProvider), isTrue);
    container.read(proactiveCare.notifier).state = false;
    expect(container.read(androidGuardNeededProvider), isFalse);
  });
}
