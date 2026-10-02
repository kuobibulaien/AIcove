import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_quickjs/aicove_quickjs.dart';

void main() {
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
