# aicove_quickjs

Thin source-only QuickJS 2026-06-04 binding for AIcove. Engine provenance and archive SHA-256: `src/quickjs/SOURCE.json`; upstream MIT license: `src/quickjs/LICENSE`. Vendored engine files are unchanged. Build hooks compile the engine together with `src/bridge.c`; there is no downloaded executable or external bytecode.

`QuickJsSession` owns one native runtime in a Dart worker isolate. Call `close()` in `finally`. Evaluation supports resolved Promises and bounded microtasks; there is no event loop for host I/O. JSON is the application boundary. Limits: 64 MiB JS heap, 512 KiB JS stack, 1 second per evaluation, 10,000 jobs and 8 MiB input/output. Native `JS_UpdateStackTop` handles Dart worker thread migration between calls.

No QuickJS libc/module loader, network, filesystem, process, timer or Dart object bridge is registered. An isolate prevents UI-thread blocking and separates script state; it is **not OS isolation against native engine bugs**. Engine exceptions close the session; callers must not silently send an unprocessed prompt instead.

Build dependencies use Flutter's package build hooks. macOS and Android ARM64 are the current verification targets; other platforms are not claimed as validated. Android/Linux link libm explicitly.
