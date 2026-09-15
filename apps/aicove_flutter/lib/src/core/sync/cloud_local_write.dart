import 'dart:async';

/// Serializes publication of settings/files with the sync compare-and-apply
/// section. User edits arriving during a cloud write publish afterwards and are
/// picked up by the next scan. Nested writes remain in the same operation.
///
/// The queue is scoped to the calling [Zone]: a continuation registered in a
/// zone that gets torn down before it flushes (e.g. a fake-async test zone)
/// would otherwise strand a process-wide queue for every later caller.
final Object _cloudWriteZone = Object();
final Expando<Future<void>> _cloudWriteTails = Expando<Future<void>>();

Future<T> cloudLocalWrite<T>(Future<T> Function() operation) {
  if (Zone.current[_cloudWriteZone] == true) return operation();
  final zone = Zone.current;
  final tail = _cloudWriteTails[zone] ?? Future<void>.value();
  final result = tail.then(
    (_) => runZoned(operation, zoneValues: {_cloudWriteZone: true}),
  );
  _cloudWriteTails[zone] = result.then<void>(
    (_) {},
    onError: (Object _, StackTrace __) {},
  );
  return result;
}
