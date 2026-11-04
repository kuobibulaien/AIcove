import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_quickjs/aicove_quickjs.dart';

void main() {
  test('persistent session keeps closures and performs host calls', () async {
    final session = await QuickJsSession.open(
      hostCall: (method, arguments, isActive) async {
        expect(isActive(), isTrue);
        expect(method, 'add');
        return (arguments[0] as int) + (arguments[1] as int);
      },
    );
    addTearDown(session.close);
    expect(
      await session.evaluate(
        'globalThis.next = (() => { let n = 0; return () => ++n; })(); next()',
      ),
      '1',
    );
    expect(
      await session.evaluate(
        '(async () => await __aq_host("add", [next(), 40]))()',
      ),
      '42',
    );
    expect(await session.evaluate('next()'), '3');
  });
  test('long microtask chains drain and host waits time out', () async {
    final session = await QuickJsSession.open(
      timeout: const Duration(milliseconds: 100),
      hostCall: (_, __, ___) => Completer<Object?>().future,
    );
    addTearDown(session.close);
    expect(
      await session.evaluate(
        'let p = Promise.resolve(0); for (let i = 0; i < 200; i++) p = p.then(x => x + 1); p',
      ),
      '200',
    );
    await expectLater(
      session.evaluate('__aq_host("wait", [])'),
      throwsA(isA<QuickJsException>()),
    );
    await expectLater(
      session.evaluate('1'),
      throwsA(
        isA<QuickJsException>().having(
          (e) => e.message,
          'message',
          'QuickJS session is closed',
        ),
      ),
    );
  });
  test('one-shot async session wakes on host delivery', () async {
    final session = QuickJsAsyncSession();
    expect(
      await session.run(
        'return await __aq_host("value", []);',
        hostCall: (_, __, ___) async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return 42;
        },
      ),
      '42',
    );
  });
  test('QuickJS runs async JS with isolated state and no host I/O', () async {
    final a = await QuickJsSession.open();
    final b = await QuickJsSession.open();
    addTearDown(a.close);
    addTearDown(b.close);
    expect(
      await a.evaluate(
        'globalThis.value=42; (async()=>await Promise.resolve(value))()',
      ),
      '42',
    );
    expect(await b.evaluate('typeof value'), 'undefined');
    expect(
      await a.evaluate('[typeof fetch,typeof process,typeof require].join()'),
      'undefined,undefined,undefined',
    );
  });
  test('native execution is interrupted, then session fails closed', () async {
    final session = await QuickJsSession.open();
    addTearDown(session.close);
    await expectLater(
      session.evaluate('while(true){}'),
      throwsA(isA<QuickJsException>()),
    );
    await expectLater(session.evaluate('1'), throwsA(isA<QuickJsException>()));
  });
  test(
    'unresolved async operations and native modules are unavailable',
    () async {
      for (final source in ['new Promise(()=>{})', "import('os')"]) {
        final session = await QuickJsSession.open();
        addTearDown(session.close);
        await expectLater(
          session.evaluate(source),
          throwsA(isA<QuickJsException>()),
        );
      }
    },
  );
  test('heap growth is bounded', () async {
    final session = await QuickJsSession.open();
    addTearDown(session.close);
    await expectLater(
      session.evaluate(
        'const a=[]; for(let i=0;i<1000;i++) a.push(new Array(100000).fill(i));',
      ),
      throwsA(isA<QuickJsException>()),
    );
  });
}
