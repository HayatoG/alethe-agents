import Darwin
import Foundation

/// A shell command started as the leader of its own process group, so everything it starts can be
/// killed with it (a dev server's children survive a signal to the shell alone). Same approach as
/// `AletheTerminal.ProcessTree`, which this target cannot import: SIGKILL the descendants found via
/// `sysctl`, children first, then the whole group.
final class GroupProcess: @unchecked Sendable {
    let pid: pid_t
    /// Read end of the combined stdout/stderr pipe.
    let output: FileHandle
    private let lock = NSLock()
    private var status: Int32?

    private init(pid: pid_t, output: FileHandle) {
        self.pid = pid
        self.output = output
    }

    /// `shell -c command` in `directory` with `environment`; stdin is `/dev/null`.
    static func spawn(shell: URL, command: String, directory: URL, environment: [String: String]) throws -> GroupProcess {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw HealthProbeError.spawnFailed("pipe") }
        let (readEnd, writeEnd) = (fds[0], fds[1])
        // Close-on-exec at once: a process spawned elsewhere meanwhile must not inherit the write end,
        // or reading this pipe to its end would wait for that unrelated process.
        _ = fcntl(readEnd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writeEnd, F_SETFD, FD_CLOEXEC)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, 1)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, 2)
        posix_spawn_file_actions_addchdir(&actions, directory.path)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // New group led by the child; no inherited descriptors; default signal state.
        posix_spawnattr_setpgroup(&attributes, 0)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK
                                                    | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv = [shell.path, "-c", command]
        let envp = environment.map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let result = withCStrings(argv) { cArgv in
            withCStrings(envp) { cEnvp in
                posix_spawn(&pid, shell.path, &actions, &attributes, cArgv, cEnvp)
            }
        }
        close(writeEnd)
        guard result == 0 else {
            close(readEnd)
            throw HealthProbeError.spawnFailed(String(cString: strerror(result)))
        }
        return GroupProcess(pid: pid, output: FileHandle(fileDescriptor: readEnd, closeOnDealloc: true))
    }

    /// Whether the group leader is still running (reaps it once it exits).
    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard status == nil else { return false }
        var raw: Int32 = 0
        let reaped = waitpid(pid, &raw, WNOHANG)
        if reaped == pid || (reaped < 0 && errno == ECHILD) { status = raw; return false }
        return true
    }

    /// SIGKILLs the leader's descendants, the leader and its whole group, then reaps the leader.
    func killTree() {
        let running = isRunning
        // Once reaped the leader's pid may be reused: only its group (still owned by any survivor) is signalled.
        let tree = Self.descendants(of: pid, parents: Self.currentParents())
        for member in tree.reversed() where member != pid || running {
            Darwin.kill(member, SIGKILL)
        }
        Darwin.kill(-pid, SIGKILL)
        if running {
            var raw: Int32 = 0
            lock.lock()
            if status == nil, waitpid(pid, &raw, 0) == pid { status = raw }
            lock.unlock()
        }
    }

    // MARK: Process tree (mirrors AletheTerminal.ProcessTree)

    /// `root` and every descendant, parents before children.
    static func descendants(of root: pid_t, parents: [pid_t: pid_t]) -> [pid_t] {
        var children: [pid_t: [pid_t]] = [:]
        for (pid, parent) in parents where pid != parent { children[parent, default: []].append(pid) }
        var result: [pid_t] = []
        var queue = [root]
        var seen: Set<pid_t> = []
        while !queue.isEmpty {
            let pid = queue.removeFirst()
            guard seen.insert(pid).inserted else { continue }
            result.append(pid)
            queue.append(contentsOf: (children[pid] ?? []).sorted())
        }
        return result
    }

    /// Parent of every process of this user, from `sysctl(KERN_PROC_UID)`.
    static func currentParents() -> [pid_t: pid_t] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: getuid())]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [:] }
        size += size / 8
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib, UInt32(mib.count), &procs, &size, nil, 0) == 0 else { return [:] }
        var parents: [pid_t: pid_t] = [:]
        for proc in procs.prefix(size / MemoryLayout<kinfo_proc>.stride) {
            parents[proc.kp_proc.p_pid] = proc.kp_eproc.e_ppid
        }
        return parents
    }
}

/// Calls `body` with a NULL-terminated C array of `strings`, valid for the call's duration.
private func withCStrings<R>(_ strings: [String], _ body: ([UnsafeMutablePointer<CChar>?]) -> R) -> R {
    let pointers = strings.map { strdup($0) } + [nil]
    defer { pointers.forEach { free($0) } }
    return body(pointers)
}
