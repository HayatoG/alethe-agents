#include "alethe_pty.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <string.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

pid_t alethe_pty_spawn(const char *path,
                       char *const argv[],
                       char *const envp[],
                       const char *cwd,
                       unsigned short cols,
                       unsigned short rows,
                       int *master_fd) {
    struct winsize size;
    memset(&size, 0, sizeof(size));
    size.ws_col = cols;
    size.ws_row = rows;

    int master = -1;
    pid_t pid = forkpty(&master, NULL, NULL, &size);
    if (pid < 0) {
        return -1;
    }
    if (pid == 0) {
        // Child: only async-signal-safe calls from here to exec.
        sigset_t all;
        sigemptyset(&all);
        sigprocmask(SIG_SETMASK, &all, NULL);
        signal(SIGPIPE, SIG_DFL);
        signal(SIGINT, SIG_DFL);
        signal(SIGQUIT, SIG_DFL);
        signal(SIGTERM, SIG_DFL);
        signal(SIGCHLD, SIG_DFL);
        if (cwd != NULL && cwd[0] != '\0') {
            (void)chdir(cwd);
        }
        execve(path, argv, envp);
        _exit(127);
    }

    int flags = fcntl(master, F_GETFL);
    if (flags >= 0) {
        (void)fcntl(master, F_SETFL, flags | O_NONBLOCK);
    }
    (void)fcntl(master, F_SETFD, FD_CLOEXEC);
    *master_fd = master;
    return pid;
}

int alethe_pty_resize(int master_fd,
                      unsigned short cols,
                      unsigned short rows,
                      unsigned short width_px,
                      unsigned short height_px) {
    struct winsize size;
    size.ws_col = cols;
    size.ws_row = rows;
    size.ws_xpixel = width_px;
    size.ws_ypixel = height_px;
    return ioctl(master_fd, TIOCSWINSZ, &size);
}

pid_t alethe_pty_foreground_pgid(int master_fd) {
    return tcgetpgrp(master_fd);
}
