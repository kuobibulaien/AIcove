/* Minimal pthread shim (mutex + condition variable) backed by SRWLOCK and
   CONDITION_VARIABLE, covering what QuickJS uses for Atomics.wait/notify.
   Kept free of <windows.h> so QuickJS sees no Win32 macros. */
#ifndef AICOVE_WIN_COMPAT_PTHREAD_H
#define AICOVE_WIN_COMPAT_PTHREAD_H

#include <time.h>

typedef struct { void *opaque; } pthread_mutex_t;
typedef struct { void *opaque; } pthread_cond_t;
typedef int pthread_condattr_t;

#define PTHREAD_MUTEX_INITIALIZER {0}

int pthread_mutex_lock(pthread_mutex_t *mutex);
int pthread_mutex_unlock(pthread_mutex_t *mutex);
int pthread_cond_init(pthread_cond_t *cond, const pthread_condattr_t *attr);
int pthread_cond_destroy(pthread_cond_t *cond);
int pthread_cond_signal(pthread_cond_t *cond);
int pthread_cond_wait(pthread_cond_t *cond, pthread_mutex_t *mutex);
int pthread_cond_timedwait(pthread_cond_t *cond, pthread_mutex_t *mutex,
                           const struct timespec *abstime);

#endif
