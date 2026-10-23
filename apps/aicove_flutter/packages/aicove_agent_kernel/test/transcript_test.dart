import 'package:aicove_agent_kernel/aicove_agent_kernel.dart';
import 'package:test/test.dart';
import 'fakes.dart';

void main() {
  test(
    'terminal assistant and last tool batch are always in runningMessages',
    () async {
      final terminal = await Harness(steps: [reply('final')]).run();
      expect(terminal.runningMessages.last, {
        'role': 'assistant',
        'content': 'final',
      });
      final stopped = await Harness(
        steps: [
          callTools(['a']),
        ],
        post: FakePost(const TurnVerdict.stop(KernelStopReason.policy)),
      ).run();
      expect(stopped.runningMessages.map((m) => m['role']), [
        'user',
        'assistant',
        'tool',
      ]);
      expect(stopped.runningMessages.last['content'], 'ok:a');
    },
  );
  test(
    'cancelled batch retains completed result and unexecuted placeholders',
    () async {
      final cancellation = KernelCancellation();
      final tools = FakeTools(
        handlers: {
          'a': () async {
            cancellation.cancel();
            return 'already done';
          },
        },
      );
      final h = Harness(
        steps: [
          callTools(['a', 'b']),
        ],
        tools: tools,
      );
      final result = await h.loop.run([
        {'role': 'user', 'content': 'start'},
      ], cancellation: cancellation);
      expect(result.status, LoopStatus.cancelled);
      expect(result.runningMessages.toString(), contains('already done'));
      expect(result.toolResults, hasLength(2));
      expect(result.toolResults.last.isError, true);
      expect(tools.log, isNot(contains('start:b')));
    },
  );
}
