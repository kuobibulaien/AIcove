#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <errno.h>

#include "pthread.h"
#include "sys/time.h"

_Static_assert(sizeof(pthread_mutex_t) == sizeof(SRWLOCK), "mutex size");
_Static_assert(sizeof(pthread_cond_t) == sizeof(CONDITION_VARIABLE), "cond size");

/* 100 ns ticks between 1601-01-01 and 1970-01-01. */
#define EPOCH_OFFSET 116444736000000000ULL

static unsigned long long now_100ns(void) {
  FILETIME ft;
  ULARGE_INTEGER t;
  GetSystemTimePreciseAsFileTime(&ft);
  t.LowPart = ft.dwLowDateTime;
  t.HighPart = ft.dwHighDateTime;
  return t.QuadPart - EPOCH_OFFSET;
}

int gettimeofday(struct timeval *tv, void *tz) {
  unsigned long long us = now_100ns() / 10;
  (void)tz;
  tv->tv_sec = (long)(us / 1000000);
  tv->tv_usec = (long)(us % 1000000);
  return 0;
}

int clock_gettime(int clock_id, struct timespec *ts) {
  unsigned long long ticks = now_100ns();
  (void)clock_id;
  ts->tv_sec = (time_t)(ticks / 10000000);
  ts->tv_nsec = (long)(ticks % 10000000) * 100;
  return 0;
}

int pthread_mutex_lock(pthread_mutex_t *mutex) {
  AcquireSRWLockExclusive((PSRWLOCK)mutex);
  return 0;
}

int pthread_mutex_unlock(pthread_mutex_t *mutex) {
  ReleaseSRWLockExclusive((PSRWLOCK)mutex);
  return 0;
}

int pthread_cond_init(pthread_cond_t *cond, const pthread_condattr_t *attr) {
  (void)attr;
  InitializeConditionVariable((PCONDITION_VARIABLE)cond);
  return 0;
}

int pthread_cond_destroy(pthread_cond_t *cond) {
  (void)cond;
  return 0;
}

int pthread_cond_signal(pthread_cond_t *cond) {
  WakeConditionVariable((PCONDITION_VARIABLE)cond);
  return 0;
}

int pthread_cond_wait(pthread_cond_t *cond, pthread_mutex_t *mutex) {
  SleepConditionVariableSRW((PCONDITION_VARIABLE)cond, (PSRWLOCK)mutex, INFINITE, 0);
  return 0;
}

int pthread_cond_timedwait(pthread_cond_t *cond, pthread_mutex_t *mutex,
                           const struct timespec *abstime) {
  struct timespec now;
  long long ms;
  clock_gettime(CLOCK_REALTIME, &now);
  ms = (long long)(abstime->tv_sec - now.tv_sec) * 1000 +
       (abstime->tv_nsec - now.tv_nsec) / 1000000;
  if (ms < 0) ms = 0;
  if (ms >= INFINITE) ms = INFINITE - 1;
  if (!SleepConditionVariableSRW((PCONDITION_VARIABLE)cond, (PSRWLOCK)mutex, (DWORD)ms, 0))
    return GetLastError() == ERROR_TIMEOUT ? ETIMEDOUT : EINVAL;
  return 0;
}
