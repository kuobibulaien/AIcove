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
