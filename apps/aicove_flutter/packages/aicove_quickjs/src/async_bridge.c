#include "quickjs.h"
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#if defined(_WIN32)
#include <windows.h>
#define EXPORT __declspec(dllexport)
typedef volatile LONG CancelFlag;
static int cancelled(CancelFlag *p) { return InterlockedCompareExchange(p, 0, 0); }
#else
#include <stdatomic.h>
#define EXPORT __attribute__((visibility("default"))) __attribute__((used))
typedef _Atomic int CancelFlag;
static int cancelled(CancelFlag *p) { return atomic_load(p); }
#endif

typedef struct {
  JSRuntime *runtime;
  JSContext *context;
  JSValue result;
  CancelFlag *cancel;
  double deadline;
  int failed;
} AsyncSandbox;

static double clock_ms(void) {
#if defined(_WIN32)
  return (double)GetTickCount64();
#else
  struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec * 1000.0 + t.tv_nsec / 1000000.0;
#endif
}
static int interrupted(JSRuntime *rt, void *opaque) {
  (void)rt;
  AsyncSandbox *s = opaque;
  return cancelled(s->cancel) || (s->deadline > 0 && clock_ms() >= s->deadline);
}
static char *string_value(AsyncSandbox *s, JSValue value) {
  size_t length = 0;
  const char *text = JS_ToCStringLen(s->context, &length, value);
  char *out = NULL;
  if (text) {
    out = malloc(length + 1);
    if (out) { memcpy(out, text, length); out[length] = 0; }
    JS_FreeCString(s->context, text);
  }
  JS_FreeValue(s->context, value);
  return out;
}
EXPORT void *aqjs_cancel_new(void) { return calloc(1, sizeof(CancelFlag)); }
EXPORT void aqjs_cancel_set(void *flag) {
#if defined(_WIN32)
  InterlockedExchange((CancelFlag *)flag, 1);
#else
  atomic_store((CancelFlag *)flag, 1);
#endif
}
EXPORT void aqjs_cancel_free(void *flag) { free(flag); }
EXPORT void *aqjs_async_create(void *flag, intptr_t heap, int64_t milliseconds) {
  AsyncSandbox *s = calloc(1, sizeof(*s));
  if (!s) return NULL;
  s->cancel = flag;
  s->deadline = milliseconds > 0 ? clock_ms() + milliseconds : 0;
  s->result = JS_UNDEFINED;
  s->runtime = JS_NewRuntime();
  if (!s->runtime) { free(s); return NULL; }
  JS_SetMemoryLimit(s->runtime, (size_t)heap);
  JS_SetMaxStackSize(s->runtime, 512u * 1024u);
  JS_SetInterruptHandler(s->runtime, interrupted, s);
  s->context = JS_NewContext(s->runtime);
  if (!s->context) { JS_FreeRuntime(s->runtime); free(s); return NULL; }
  return s;
}
EXPORT void aqjs_async_begin(void *handle, const char *source, intptr_t length) {
  AsyncSandbox *s = handle;
  JS_UpdateStackTop(s->runtime);
  s->result = JS_Eval(s->context, source, (size_t)length, "workspace.js", JS_EVAL_TYPE_GLOBAL);
  if (JS_IsException(s->result)) {
    s->result = JS_GetException(s->context); s->failed = 1;
  }
}
// Bounded job turns yield to the Dart worker even for endless Promise chains.
EXPORT int aqjs_async_step(void *handle) {
  AsyncSandbox *s = handle;
  JS_UpdateStackTop(s->runtime);
  if (s->failed) return -1;
  if (interrupted(s->runtime, s)) return -2;
  for (int i = 0; i < 64 && JS_IsJobPending(s->runtime); ++i) {
    JSContext *ctx = NULL;
    if (JS_ExecutePendingJob(s->runtime, &ctx) < 0) {
      JS_FreeValue(s->context, s->result);
      s->result = JS_GetException(ctx ? ctx : s->context); s->failed = 1;
      return -1;
    }
    if (interrupted(s->runtime, s)) return -2;
  }
  JSPromiseStateEnum state = JS_PromiseState(s->context, s->result);
  if (state == JS_PROMISE_PENDING) return 0;
  return state == JS_PROMISE_REJECTED ? -1 : 1;
}
EXPORT char *aqjs_async_result(void *handle) {
  AsyncSandbox *s = handle;
  JSValue value = s->result;
  JSPromiseStateEnum state = JS_PromiseState(s->context, value);
  return string_value(s, (state == JS_PROMISE_FULFILLED || state == JS_PROMISE_REJECTED)
      ? JS_PromiseResult(s->context, value) : JS_DupValue(s->context, value));
}
EXPORT char *aqjs_async_take(void *handle) {
  AsyncSandbox *s = handle;
  JS_UpdateStackTop(s->runtime);
  JSValue global = JS_GetGlobalObject(s->context);
  JSValue fn = JS_GetPropertyStr(s->context, global, "__aq_take");
  JSValue value = JS_Call(s->context, fn, JS_UNDEFINED, 0, NULL);
  JS_FreeValue(s->context, fn); JS_FreeValue(s->context, global);
  if (JS_IsException(value)) return NULL;
  return string_value(s, value);
}
EXPORT void aqjs_async_deliver(void *handle, const char *json, intptr_t length) {
  AsyncSandbox *s = handle;
  JS_UpdateStackTop(s->runtime);
  JSValue global = JS_GetGlobalObject(s->context);
  JSValue fn = JS_GetPropertyStr(s->context, global, "__aq_deliver");
  JSValue argument = JS_NewStringLen(s->context, json, (size_t)length);
  JSValue value = JS_Call(s->context, fn, JS_UNDEFINED, 1, &argument);
  if (JS_IsException(value)) {
    JS_FreeValue(s->context, s->result);
    s->result = JS_GetException(s->context); s->failed = 1;
  }
  JS_FreeValue(s->context, value); JS_FreeValue(s->context, argument);
  JS_FreeValue(s->context, fn); JS_FreeValue(s->context, global);
}
EXPORT void aqjs_async_destroy(void *handle) {
  AsyncSandbox *s = handle;
  JS_FreeValue(s->context, s->result);
  JS_FreeContext(s->context); JS_FreeRuntime(s->runtime); free(s);
}
