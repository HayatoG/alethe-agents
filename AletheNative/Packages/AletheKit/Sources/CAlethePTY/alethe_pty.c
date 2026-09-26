#include "alethe_pty.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
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

    // posix_spawn, not forkpty: fork() in a process with many threads can deadlock in the atfork
    // handlers (malloc and the ObjC runtime), which froze the app when several terminals started
    // at once.
    int master = -1, slave = -1;
    char name[128];
    if (openpty(&master, &slave, name, NULL, &size) < 0) {
        return -1;
    }

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    // The child becomes a session leader (SETSID) before these run, so opening the slave by name
    // makes it the controlling terminal.
    posix_spawn_file_actions_addopen(&actions, 0, name, O_RDWR, 0);
    posix_spawn_file_actions_adddup2(&actions, 0, 1);
    posix_spawn_file_actions_adddup2(&actions, 0, 2);
    if (cwd != NULL && cwd[0] != '\0') {
        posix_spawn_file_actions_addchdir(&actions, cwd);
    }

    posix_spawnattr_t attributes;
    posix_spawnattr_init(&attributes);
    sigset_t none, all;
    sigemptyset(&none);
    sigfillset(&all);
    posix_spawnattr_setsigmask(&attributes, &none);
    posix_spawnattr_setsigdefault(&attributes, &all);
    posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGMASK
                                          | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT);

    pid_t pid = 0;
    int result = posix_spawn(&pid, path, &actions, &attributes, argv, envp);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attributes);
    close(slave);
    if (result != 0) {
        close(master);
        errno = result;
        return -1;
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
