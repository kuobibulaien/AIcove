#include "quickjs.h"
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#if defined(_WIN32)
#include <windows.h>
#define EXPORT __declspec(dllexport)
#else
#define EXPORT __attribute__((visibility("default"))) __attribute__((used))
#endif
#define MAX_BYTES (8u * 1024u * 1024u)
typedef struct { JSRuntime *runtime; JSContext *context; double deadline; int failed; } Sandbox;
static double clock_ms(void) {
#if defined(_WIN32)
  return (double)GetTickCount64();
#else
  struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec * 1000.0 + t.tv_nsec / 1000000.0;
#endif
}
static int interrupt(JSRuntime *runtime, void *opaque) {
  (void)runtime; return clock_ms() >= ((Sandbox *)opaque)->deadline;
}
static char *copy_text(const char *text, size_t length) {
  char *result = malloc(length + 1);
  if (result) { memcpy(result, text, length); result[length] = 0; }
  return result;
}
EXPORT void *aqjs_create(void) {
  Sandbox *s = calloc(1, sizeof(*s)); if (!s) return NULL;
  s->runtime = JS_NewRuntime(); if (!s->runtime) { free(s); return NULL; }
  JS_SetMemoryLimit(s->runtime, 64u * 1024u * 1024u);
  JS_SetMaxStackSize(s->runtime, 512u * 1024u);
  s->deadline = clock_ms() + 1000;
  JS_SetInterruptHandler(s->runtime, interrupt, s);
  s->context = JS_NewContext(s->runtime);
  if (!s->context) { JS_FreeRuntime(s->runtime); free(s); return NULL; }
  // No libc, native modules, filesystem, network or Dart object bindings.
  return s;
}
EXPORT char *aqjs_eval(void *handle, const char *source, intptr_t length) {
  Sandbox *s = handle;
  if (!s || length < 0 || (size_t)length > MAX_BYTES) return NULL;
  s->failed = 0; s->deadline = clock_ms() + 1000;
  // A Dart isolate can resume on a different worker thread between calls.
  JS_UpdateStackTop(s->runtime);
  JSValue value = JS_Eval(s->context, source, (size_t)length, "preset.js", JS_EVAL_TYPE_GLOBAL);
  int jobs = 0;
  if (JS_IsException(value)) { JS_FreeValue(s->context, value); value = JS_GetException(s->context); s->failed = 1; }
  while (!s->failed && JS_IsJobPending(s->runtime)) {
    if (++jobs > 10000 || clock_ms() >= s->deadline) {
      JS_FreeValue(s->context, value); value = JS_NewString(s->context, "JavaScript job budget exceeded"); s->failed = 1; break;
    }
    JSContext *job_context = NULL;
    if (JS_ExecutePendingJob(s->runtime, &job_context) < 0) {
      JS_FreeValue(s->context, value); value = JS_GetException(job_context ? job_context : s->context); s->failed = 1;
    }
  }
  if (!s->failed) {
    JSPromiseStateEnum state = JS_PromiseState(s->context, value);
    if (state == JS_PROMISE_PENDING) {
      JS_FreeValue(s->context, value); value = JS_NewString(s->context, "Unresolved async operation: host I/O is unavailable"); s->failed = 1;
    } else if (state == JS_PROMISE_FULFILLED || state == JS_PROMISE_REJECTED) {
      JSValue result = JS_PromiseResult(s->context, value); JS_FreeValue(s->context, value); value = result;
      if (state == JS_PROMISE_REJECTED) s->failed = 1;
    }
  }
  size_t size = 0;
  const char *text = JS_ToCStringLen(s->context, &size, value);
  char *result = NULL;
  if (text && size <= MAX_BYTES) result = copy_text(text, size);
  else { s->failed = 1; const char *error = "JavaScript output limit or conversion failure"; result = copy_text(error, strlen(error)); }
  JS_FreeCString(s->context, text); JS_FreeValue(s->context, value);
  return result;
}
EXPORT int aqjs_failed(void *handle) { return ((Sandbox *)handle)->failed; }
EXPORT void aqjs_free_text(char *text) { free(text); }
EXPORT void aqjs_destroy(void *handle) {
  Sandbox *s = handle; if (!s) return;
  JS_FreeContext(s->context); JS_FreeRuntime(s->runtime); free(s);
}
