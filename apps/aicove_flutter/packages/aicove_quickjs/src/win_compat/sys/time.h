/* Minimal POSIX time shim so the unmodified QuickJS sources build with
   clang-cl on Windows. Implemented in win_compat.c. */
#ifndef AICOVE_WIN_COMPAT_SYS_TIME_H
#define AICOVE_WIN_COMPAT_SYS_TIME_H

#include <time.h>

#ifndef _TIMEVAL_DEFINED
#define _TIMEVAL_DEFINED
struct timeval {
  long tv_sec;
  long tv_usec;
};
#endif

#ifndef CLOCK_REALTIME
#define CLOCK_REALTIME 0
#endif

int gettimeofday(struct timeval *tv, void *tz);
int clock_gettime(int clock_id, struct timespec *ts);

#endif
