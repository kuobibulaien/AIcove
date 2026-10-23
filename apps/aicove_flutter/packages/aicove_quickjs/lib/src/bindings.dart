import 'dart:ffi';

@Native<Pointer<Void> Function()>(symbol: 'aqjs_create')
external Pointer<Void> create();
@Native<Pointer<Char> Function(Pointer<Void>, Pointer<Char>, IntPtr)>(
  symbol: 'aqjs_eval',
)
external Pointer<Char> evaluate(
  Pointer<Void> runtime,
  Pointer<Char> source,
  int length,
);
@Native<Int32 Function(Pointer<Void>)>(symbol: 'aqjs_failed')
external int failed(Pointer<Void> runtime);
@Native<Void Function(Pointer<Char>)>(symbol: 'aqjs_free_text')
external void freeText(Pointer<Char> text);
@Native<Void Function(Pointer<Void>)>(symbol: 'aqjs_destroy')
external void destroy(Pointer<Void> runtime);

@Native<Pointer<Void> Function()>(symbol: 'aqjs_cancel_new')
external Pointer<Void> cancelNew();
@Native<Void Function(Pointer<Void>)>(symbol: 'aqjs_cancel_set')
external void cancelSet(Pointer<Void> flag);
@Native<Void Function(Pointer<Void>)>(symbol: 'aqjs_cancel_free')
external void cancelFree(Pointer<Void> flag);
@Native<Pointer<Void> Function(Pointer<Void>, IntPtr, Int64)>(
  symbol: 'aqjs_async_create',
)
external Pointer<Void> asyncCreate(
  Pointer<Void> flag,
  int heap,
  int milliseconds,
);
@Native<Void Function(Pointer<Void>, Pointer<Char>, IntPtr)>(
  symbol: 'aqjs_async_begin',
)
external void asyncBegin(
  Pointer<Void> runtime,
  Pointer<Char> source,
  int length,
);
@Native<Int32 Function(Pointer<Void>)>(symbol: 'aqjs_async_step')
external int asyncStep(Pointer<Void> runtime);
@Native<Pointer<Char> Function(Pointer<Void>)>(symbol: 'aqjs_async_result')
external Pointer<Char> asyncResult(Pointer<Void> runtime);
@Native<Pointer<Char> Function(Pointer<Void>)>(symbol: 'aqjs_async_take')
external Pointer<Char> asyncTake(Pointer<Void> runtime);
@Native<Void Function(Pointer<Void>, Pointer<Char>, IntPtr)>(
  symbol: 'aqjs_async_deliver',
)
external void asyncDeliver(
  Pointer<Void> runtime,
  Pointer<Char> json,
  int length,
);
@Native<Void Function(Pointer<Void>)>(symbol: 'aqjs_async_destroy')
external void asyncDestroy(Pointer<Void> runtime);

@Native<Pointer<Void> Function(Pointer<Char>, Pointer<Char>, Pointer<Int32>)>(
  symbol: 'ap_start',
)
external Pointer<Void> processStart(
  Pointer<Char> cwd,
  Pointer<Char> command,
  Pointer<Int32> error,
);
@Native<Int32 Function(Pointer<Void>)>(symbol: 'ap_pid')
external int processPid(Pointer<Void> job);
@Native<Int32 Function(Pointer<Void>, Pointer<Uint8>, Int32)>(symbol: 'ap_read')
external int processRead(Pointer<Void> job, Pointer<Uint8> buffer, int size);
@Native<Int64 Function(Pointer<Void>)>(symbol: 'ap_status')
external int processStatus(Pointer<Void> job);
@Native<Void Function(Pointer<Void>)>(symbol: 'ap_kill')
external void processKill(Pointer<Void> job);
@Native<Void Function(Pointer<Void>)>(symbol: 'ap_free')
external void processFree(Pointer<Void> job);

@Native<Pointer<Void> Function(Pointer<Char>)>(symbol: 'ap_lock')
external Pointer<Void> processLock(Pointer<Char> path);
@Native<Void Function(Pointer<Void>)>(symbol: 'ap_unlock')
external void processUnlock(Pointer<Void> lock);
