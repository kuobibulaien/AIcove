import 'package:aicove_agent_kernel/aicove_agent_kernel.dart';
import 'package:aicove_flutter/src/features/chat/chat_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('only the last presenter detaching resolves the request', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(modelFailoverPromptProvider.notifier);
    final first = controller.attachPresenter('a');
    final second = controller.attachPresenter('a');
    final pending = controller.request(
      conversationId: 'a',
      failedModelName: 'one',
      nextModelName: 'two',
      errorMessage: 'failed',
    );
    first();
    first();
    expect(container.read(modelFailoverPromptForProvider('a')), isNotNull);
    second();
    expect(await pending, ModelFailoverDecision.tryNext);
    expect(container.read(modelFailoverPromptForProvider('a')), isNull);
  });

  test(
    'prompts belong to a conversation and end with their presenters or cancellation',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(modelFailoverPromptProvider.notifier);
      Future<ModelFailoverDecision> ask(
        String id, [
        KernelCancellation? cancellation,
      ]) => controller.request(
        conversationId: id,
        failedModelName: 'one',
        nextModelName: 'two',
        errorMessage: 'failed',
        cancellation: cancellation,
      );
      expect(await ask('unseen'), ModelFailoverDecision.tryNext);
      final detachA = controller.attachPresenter('a');
      final detachB = controller.attachPresenter('b');
      final firstA = ask('a');
      final b = ask('b');
      final oldId = container
          .read(modelFailoverPromptForProvider('a'))!
          .requestId;
      final secondA = ask('a');
      expect(await firstA, ModelFailoverDecision.tryNext);
      controller.resolve('a', oldId, ModelFailoverDecision.cancel);
      expect(container.read(modelFailoverPromptForProvider('a')), isNotNull);
      expect(container.read(modelFailoverPromptForProvider('b')), isNotNull);
      detachA();
      expect(await secondA, ModelFailoverDecision.tryNext);
      final cancellation = KernelCancellation();
      final cancelled = ask('b', cancellation);
      expect(await b, ModelFailoverDecision.tryNext);
      cancellation.cancel();
      expect(await cancelled, ModelFailoverDecision.cancel);
      expect(container.read(modelFailoverPromptForProvider('b')), isNull);
      detachB();
    },
  );
}
