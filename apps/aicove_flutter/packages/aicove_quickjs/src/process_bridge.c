/* Desktop host process primitive. No QuickJS state or calls are shared. */
#include <stdlib.h>
#include <stdint.h>
#include <limits.h>
#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif
#if !defined(_WIN32) && !defined(__ANDROID__) && !(defined(__APPLE__) && TARGET_OS_IPHONE)
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <sys/file.h>
#include <pthread.h>
#if defined(__APPLE__)
#include <libproc.h>
#include <sys/proc_info.h>
#endif
#if defined(__linux__)
#include <sys/syscall.h>
#endif
#include <unistd.h>
extern char **environ;

typedef struct { pid_t pid, guardian; int output, control, status; } APJob;

static void *start_job(const char *cwd, const char *command, int *error) {
    int out[2], control[2], gate[2];
    *error = 0;
    if (pipe(out) < 0) { *error = errno; return NULL; }
    if (pipe(control) < 0) { *error = errno; close(out[0]); close(out[1]); return NULL; }
    if (pipe(gate) < 0) { *error = errno; close(out[0]); close(out[1]); close(control[0]); close(control[1]); return NULL; }
    for (int i = 0; i < 2; ++i) {
        fcntl(out[i], F_SETFD, FD_CLOEXEC);
        fcntl(control[i], F_SETFD, FD_CLOEXEC);
        fcntl(gate[i], F_SETFD, FD_CLOEXEC);
    }
    APJob *job = calloc(1, sizeof(*job));
    if (!job) { *error = ENOMEM; goto fail; }
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attr;
    posix_spawn_file_actions_init(&actions);
    posix_spawnattr_init(&attr);
    int rc = posix_spawn_file_actions_addchdir_np(&actions, cwd);
    if (!rc) rc = posix_spawn_file_actions_adddup2(&actions, out[1], STDOUT_FILENO);
    if (!rc) rc = posix_spawn_file_actions_adddup2(&actions, out[1], STDERR_FILENO);
    if (!rc) rc = posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    if (!rc) rc = posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);
    if (!rc) rc = posix_spawnattr_setpgroup(&attr, 0);
    if (!rc) rc = posix_spawn_file_actions_adddup2(&actions, gate[0], 3);
    /* The user body cannot run until its parent-death guardian exists.
       If the app dies in the spawn/fork interval, EOF exits this shell. */
    char *argv[] = { "/bin/sh", "-c", "read -r _ <&3 || exit 125; exec 3<&-; exec /bin/sh -c \"$1\"", "aicove", (char *)command, NULL };
    if (!rc) rc = posix_spawn(&job->pid, "/bin/sh", &actions, &attr, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attr);
    if (rc) { *error = rc; free(job); goto fail; }
    close(out[1]); close(gate[0]);
    /* A pipe guardian owns only async-signal-safe operations after fork.
       App death closes control: the exact process group is killed immediately,
       without a later startup killing a possibly-reused PID. */
    long maxfd = sysconf(_SC_OPEN_MAX);
    if (maxfd < 0) maxfd = 65536;
#if defined(__APPLE__)
    int fdsize = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, NULL, 0);
    if (fdsize > 0) {
        struct proc_fdinfo *fds = malloc(fdsize * 2);
        if (fds) {
            int count = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, fds, fdsize * 2) / sizeof(*fds);
            if (count > 0) {
                maxfd = 5;
                for (int i = 0; i < count; ++i) if ((long)fds[i].proc_fd + 1 > maxfd) maxfd = (long)fds[i].proc_fd + 1;
            }
            free(fds);
        }
    }
#endif
    job->guardian = fork();
    if (job->guardian == 0) {
        if (control[0] != 3 && dup2(control[0], 3) < 0) { kill(-job->pid, SIGKILL); _exit(1); }
        if (gate[1] != 4 && dup2(gate[1], 4) < 0) { kill(-job->pid, SIGKILL); _exit(1); }
        close(0); close(1); close(2);
#if defined(SYS_close_range)
        if (syscall(SYS_close_range, 5, ~0U, 0) < 0)
            for (int fd = 5; fd < maxfd; ++fd) close(fd);
#else
        for (int fd = 5; fd < maxfd; ++fd) close(fd);
#endif
        write(4, "\n", 1); close(4);
        char byte;
        while (read(3, &byte, 1) < 0 && errno == EINTR) {}
        kill(-job->pid, SIGKILL);
        _exit(0);
    }
    if (job->guardian < 0) {
        *error = errno; kill(-job->pid, SIGKILL); waitpid(job->pid, NULL, 0);
        close(out[0]); close(control[0]); close(control[1]); close(gate[1]); free(job); return NULL;
    }
    close(control[0]); close(gate[1]);
    fcntl(out[0], F_SETFL, fcntl(out[0], F_GETFL) | O_NONBLOCK);
    job->output = out[0]; job->control = control[1]; job->status = INT_MIN;
    return job;
fail:
    close(out[0]); close(out[1]); close(control[0]); close(control[1]); close(gate[0]); close(gate[1]); return NULL;
}

static pthread_mutex_t spawn_mutex = PTHREAD_MUTEX_INITIALIZER;
__attribute__((visibility("default")))
void *ap_start(const char *cwd, const char *command, int *error) {
    pthread_mutex_lock(&spawn_mutex);
    void *result = start_job(cwd, command, error);
    pthread_mutex_unlock(&spawn_mutex);
    return result;
}

__attribute__((visibility("default")))
int ap_pid(void *ptr) { return ((APJob *)ptr)->pid; }
__attribute__((visibility("default")))
int ap_read(void *ptr, uint8_t *buffer, int size) {
    ssize_t count = read(((APJob *)ptr)->output, buffer, size);
    if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) return -2;
    return (int)count;
}
__attribute__((visibility("default")))
int64_t ap_status(void *ptr) {
    APJob *job = ptr;
    if (job->status == INT_MIN) {
        int status;
        pid_t result = waitpid(job->pid, &status, WNOHANG);
        if (result == job->pid) job->status = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
    }
    return job->status == INT_MIN ? INT64_MIN : job->status;
}
__attribute__((visibility("default")))
void ap_kill(void *ptr) { kill(-((APJob *)ptr)->pid, SIGKILL); }
__attribute__((visibility("default")))
void ap_free(void *ptr) {
    APJob *job = ptr;
    kill(-job->pid, SIGKILL);
    close(job->control); close(job->output);
    while (waitpid(job->guardian, NULL, 0) < 0 && errno == EINTR) {}
    if (job->status == INT_MIN) waitpid(job->pid, NULL, WNOHANG);
    free(job);
}
__attribute__((visibility("default")))
void *ap_lock(const char *path) {
    int fd = open(path, O_CREAT | O_RDWR, 0600);
    if (fd < 0) return NULL;
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    if (flock(fd, LOCK_EX | LOCK_NB) < 0) { close(fd); return NULL; }
    return (void *)(intptr_t)(fd + 1);
}
__attribute__((visibility("default")))
void ap_unlock(void *lock) { close((int)(intptr_t)lock - 1); }
#elif defined(_WIN32)
#include <windows.h>
typedef struct { HANDLE process, group, output; DWORD pid; } APJob;
static wchar_t *wide(const char *text) {
    int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, NULL, 0);
    if (!n) return NULL;
    wchar_t *result = calloc(n, sizeof(wchar_t));
    if (result) MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, result, n);
    return result;
}
__declspec(dllexport) void *ap_start(const char *cwd, const char *command, int *error) {
    HANDLE readPipe = NULL, writePipe = NULL;
    SECURITY_ATTRIBUTES sa = { sizeof(sa), NULL, TRUE };
    APJob *job = calloc(1, sizeof(*job));
    wchar_t *dir = wide(cwd), *cmd = wide(command);
    *error = 0;
    if (!job || !dir || !cmd) { *error = ERROR_NOT_ENOUGH_MEMORY; goto fail; }
    if (!CreatePipe(&readPipe, &writePipe, &sa, 0)) goto fail;
    SetHandleInformation(readPipe, HANDLE_FLAG_INHERIT, 0);
    job->group = CreateJobObjectW(NULL, NULL);
    if (!job->group) goto fail;
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {0};
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (!SetInformationJobObject(job->group, JobObjectExtendedLimitInformation, &limits, sizeof(limits))) goto fail;
    STARTUPINFOEXW si = {0}; PROCESS_INFORMATION pi = {0};
    si.StartupInfo.cb = sizeof(si); si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    si.StartupInfo.hStdOutput = writePipe; si.StartupInfo.hStdError = writePipe;
    si.StartupInfo.hStdInput = CreateFileW(L"NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, &sa, OPEN_EXISTING, 0, NULL);
    if (si.StartupInfo.hStdInput == INVALID_HANDLE_VALUE) goto fail;
    SIZE_T attrSize = 0;
    InitializeProcThreadAttributeList(NULL, 2, 0, &attrSize);
    si.lpAttributeList = malloc(attrSize);
    BOOL initialized = si.lpAttributeList && InitializeProcThreadAttributeList(si.lpAttributeList, 2, 0, &attrSize);
    HANDLE inherited[] = {writePipe, si.StartupInfo.hStdInput};
    BOOL configured = initialized &&
        UpdateProcThreadAttribute(si.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_JOB_LIST, &job->group, sizeof(HANDLE), NULL, NULL) &&
        UpdateProcThreadAttribute(si.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, inherited, sizeof(inherited), NULL, NULL);
    BOOL created = configured && CreateProcessW(NULL, cmd, NULL, NULL, TRUE,
        EXTENDED_STARTUPINFO_PRESENT | CREATE_NO_WINDOW, NULL, dir, &si.StartupInfo, &pi);
    if (!created) *error = GetLastError();
    if (initialized) DeleteProcThreadAttributeList(si.lpAttributeList);
    free(si.lpAttributeList); CloseHandle(si.StartupInfo.hStdInput);
    if (!created) goto fail;
    // Job membership is atomic with creation, before any command can run.
    job->process = pi.hProcess; job->pid = pi.dwProcessId;
    CloseHandle(pi.hThread); CloseHandle(writePipe);
    job->output = readPipe; free(dir); free(cmd); return job;
fail:
    if (!*error) *error = GetLastError();
    if (readPipe) CloseHandle(readPipe); if (writePipe) CloseHandle(writePipe);
    if (job) { if (job->group) CloseHandle(job->group); if (job->process) CloseHandle(job->process); free(job); }
    free(dir); free(cmd); return NULL;
}
__declspec(dllexport) int ap_pid(void *ptr) { return ((APJob *)ptr)->pid; }
__declspec(dllexport) int ap_read(void *ptr, uint8_t *buffer, int size) {
    DWORD count = 0, readCount = 0;
    HANDLE out = ((APJob *)ptr)->output;
    if (!PeekNamedPipe(out, NULL, 0, NULL, &count, NULL)) return GetLastError() == ERROR_BROKEN_PIPE ? 0 : -1;
    if (!count) return -2;
    if (!ReadFile(out, buffer, count < (DWORD)size ? count : (DWORD)size, &readCount, NULL)) return -1;
    return (int)readCount;
}
__declspec(dllexport) int64_t ap_status(void *ptr) {
    APJob *job = ptr; DWORD code;
    if (WaitForSingleObject(job->process, 0) != WAIT_OBJECT_0) return INT64_MIN;
    if (!GetExitCodeProcess(job->process, &code)) return INT64_MIN;
    return (int64_t)code;
}
__declspec(dllexport) void ap_kill(void *ptr) { TerminateJobObject(((APJob *)ptr)->group, 137); }
__declspec(dllexport) void ap_free(void *ptr) {
    APJob *job = ptr; CloseHandle(job->group); CloseHandle(job->process); CloseHandle(job->output); free(job);
}
__declspec(dllexport) void *ap_lock(const char *path) {
    wchar_t *name = wide(path);
    if (!name) return NULL;
    HANDLE file = CreateFileW(name, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
        NULL, OPEN_ALWAYS, 0, NULL);
    free(name);
    if (file == INVALID_HANDLE_VALUE) return NULL;
    OVERLAPPED overlapped = {0};
    if (!LockFileEx(file, LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, &overlapped)) { CloseHandle(file); return NULL; }
    return file;
}
__declspec(dllexport) void ap_unlock(void *lock) { CloseHandle(lock); }
#else
/* Mobile never registers shell. Keep native asset symbols linkable. */
#define AP_EXPORT __declspec(dllexport)
#if !defined(_WIN32)
#undef AP_EXPORT
#define AP_EXPORT __attribute__((visibility("default")))
#endif
AP_EXPORT void *ap_start(const char *cwd, const char *command, int *error) { *error = 38; return NULL; }
AP_EXPORT int ap_pid(void *p) { return -1; }
AP_EXPORT int ap_read(void *p, uint8_t *b, int n) { return -1; }
AP_EXPORT int64_t ap_status(void *p) { return -1; }
AP_EXPORT void ap_kill(void *p) {}
AP_EXPORT void ap_free(void *p) {}
AP_EXPORT void *ap_lock(const char *p) { return NULL; }
AP_EXPORT void ap_unlock(void *p) {}
#endif
