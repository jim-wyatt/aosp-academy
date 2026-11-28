// aospacademy-tunnelnudge: wake the phone every SECONDS, however deeply it sleeps, and run COMMAND.
//
//   aospacademy-tunnelnudge SECONDS COMMAND [ARG...]     (SECONDS 0: do nothing, and stay so)
//
// init.aospacademy.rc runs it with the first-boot script's tunnel-nudge mode as COMMAND, which
// makes WireGuard send the hub a keepalive at once. Why: the home router renumbers or forgets the
// phone's UDP mapping now and then, and the hub can't reach the phone again until the phone sends
// something. WireGuard's own 25 s keepalive is a kernel timer that stands still while the phone is
// suspended, and the phone was out of reach for 51 and 57 minutes on 2026-11-26 and -27.
//
// A CLOCK_BOOTTIME_ALARM timerfd is one of the few timers that wakes a suspended phone. epoll's
// EPOLLWAKEUP keeps the system awake from the alarm until this process waits again, and the named
// kernel wakelock below (with a timeout, so it can't be left held) covers COMMAND and the packet it
// sends. Both need root's CAP_WAKE_ALARM and CAP_BLOCK_SUSPEND.
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/timerfd.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include <android/log.h>

#define TAG "aospacademy-tunnelnudge"
#define WAKELOCK "aospacademy_nudge 5000000000\n"   // name and timeout in ns: 5 s

static void wakelock(void) {
    int fd = open("/sys/power/wake_lock", O_WRONLY | O_CLOEXEC);
    if (fd < 0) return;
    (void)!write(fd, WAKELOCK, strlen(WAKELOCK));
    close(fd);
}

int main(int argc, char **argv) {
    if (argc < 3) {
        __android_log_print(ANDROID_LOG_ERROR, TAG, "usage: %s SECONDS COMMAND [ARG...]", argv[0]);
        return 2;
    }
    char *end;
    long seconds = strtol(argv[1], &end, 10);
    if (*end || seconds < 0) {
        __android_log_print(ANDROID_LOG_ERROR, TAG, "'%s' is not a number of seconds; off", argv[1]);
        seconds = 0;
    }
    if (seconds == 0) {
        // Off. Not an exit: init would restart the service, and this would run again at once.
        __android_log_print(ANDROID_LOG_INFO, TAG, "off");
        for (;;) pause();
    }
    if (seconds < 30) seconds = 30;   // a typo shouldn't keep the phone from ever sleeping

    int tfd = timerfd_create(CLOCK_BOOTTIME_ALARM, TFD_CLOEXEC);
    int ep = epoll_create1(EPOLL_CLOEXEC);
    struct epoll_event ev = {.events = EPOLLIN | EPOLLWAKEUP};
    struct itimerspec its = {.it_interval = {seconds, 0}, .it_value = {seconds, 0}};
    if (tfd < 0 || ep < 0 || epoll_ctl(ep, EPOLL_CTL_ADD, tfd, &ev) < 0 || timerfd_settime(tfd, 0, &its, NULL) < 0) {
        __android_log_print(ANDROID_LOG_ERROR, TAG, "can't set a wake alarm: %s", strerror(errno));
        return 1;
    }
    __android_log_print(ANDROID_LOG_INFO, TAG, "every %ld s: %s", seconds, argv[2]);

    for (;;) {
        struct epoll_event got;
        if (epoll_wait(ep, &got, 1, -1) < 1) continue;   // EINTR
        uint64_t n;
        if (read(tfd, &n, sizeof n) != sizeof n) continue;
        wakelock();
        pid_t pid = fork();
        if (pid == 0) {
            execv(argv[2], argv + 2);
            _exit(127);
        }
        if (pid > 0) waitpid(pid, NULL, 0);
    }
}
