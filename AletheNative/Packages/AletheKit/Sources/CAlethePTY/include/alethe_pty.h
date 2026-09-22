#ifndef ALETHE_PTY_H
#define ALETHE_PTY_H

#include <sys/types.h>

/// Spawns `path` with `argv`/`envp` on a new pseudo-terminal of `cols` x `rows`, as a session
/// leader with the PTY as its controlling terminal, working directory `cwd` (NULL = inherit).
///
/// Everything the child does between fork and exec is async-signal-safe, which is why this lives
/// in C: after fork only such calls are allowed, and the Swift runtime gives no such guarantee.
///
/// On success returns the child pid and stores the non-blocking, close-on-exec master fd in
/// `*master_fd`. On failure returns -1 and sets errno.
pid_t alethe_pty_spawn(const char *path,
                       char *const argv[],
                       char *const envp[],
                       const char *cwd,
                       unsigned short cols,
                       unsigned short rows,
                       int *master_fd);

/// Applies a new window size (TIOCSWINSZ); the kernel sends SIGWINCH to the foreground group.
int alethe_pty_resize(int master_fd,
                      unsigned short cols,
                      unsigned short rows,
                      unsigned short width_px,
                      unsigned short height_px);

/// Foreground process group of the terminal (for "is something running?" and cwd lookups).
pid_t alethe_pty_foreground_pgid(int master_fd);

#endif
