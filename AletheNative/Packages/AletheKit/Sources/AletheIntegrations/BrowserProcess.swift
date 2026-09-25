import Darwin
import Foundation

/// The browser, started as the leader of its own process group so its helpers go with it.
final class BrowserProcess: @unchecked Sendable {
    let pid: pid_t
    private let lock = NSLock()
    private var reaped = false

    private init(pid: pid_t) {
        self.pid = pid
    }

    /// `executable arguments…` with stdio on `/dev/null`, no inherited descriptors, default signals.
    static func spawn(_ executable: URL, arguments: [String]) throws(BrowserSessionError) -> BrowserProcess {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setpgroup(&attributes, 0)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK
                                                    | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv = [executable.path] + arguments
        let envp = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let result = withCStrings(argv) { cArgv in
            withCStrings(envp) { cEnvp in posix_spawn(&pid, executable.path, &actions, &attributes, cArgv, cEnvp) }
        }
        guard result == 0 else { throw .spawnFailed(String(cString: strerror(result))) }
        return BrowserProcess(pid: pid)
    }

    /// Whether the browser still runs (reaps it once it exited).
    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !reaped else { return false }
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid || (result < 0 && errno == ECHILD) {
            reaped = true
            return false
        }
        return true
    }

    /// SIGTERM to the group first so the profile is written cleanly, then after `grace` SIGKILL to
    /// every descendant (children first) and the group; the leader is reaped.
    func terminate(grace: TimeInterval = 1.5) {
        if isRunning {
            Darwin.kill(-pid, SIGTERM)
            let deadline = Date().addingTimeInterval(grace)
            while isRunning, Date() < deadline { usleep(50_000) }
        }
        let running = isRunning
        // Once reaped the leader's pid may be reused: only its group (kept by any survivor) is signalled.
        let tree = ProcessTable.descendants(of: pid, parents: ProcessTable.parents())
        for member in tree.reversed() where member != pid || running {
            Darwin.kill(member, SIGKILL)
        }
        Darwin.kill(-pid, SIGKILL)
        if running {
            lock.lock()
            var status: Int32 = 0
            if !reaped, waitpid(pid, &status, 0) == pid { reaped = true }
            lock.unlock()
        }
    }
}

/// This user's processes, from `sysctl` (no private API, no `ps`).
enum ProcessTable {
    /// Parent of every process of this user.
    static func parents() -> [pid_t: pid_t] {
        Dictionary(processes().map { ($0.kp_proc.p_pid, $0.kp_eproc.e_ppid) }, uniquingKeysWith: { first, _ in first })
    }

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

    static func pids() -> [pid_t] {
        processes().map(\.kp_proc.p_pid)
    }

    private static func processes() -> [kinfo_proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: getuid())]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        size += size / 8
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib, UInt32(mib.count), &procs, &size, nil, 0) == 0 else { return [] }
        return Array(procs.prefix(size / MemoryLayout<kinfo_proc>.stride))
    }

    /// Executable path and argv of `pid` (`KERN_PROCARGS2`); nil when it is gone or not readable.
    static func commandLine(of pid: pid_t) -> (executable: String, arguments: [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parseProcArgs(Array(buffer.prefix(size)))
    }

    /// `KERN_PROCARGS2` layout: `argc` (Int32), the executable path, NUL padding, then `argc`
    /// NUL-terminated arguments (the environment follows and is ignored).
    static func parseProcArgs(_ bytes: [UInt8]) -> (executable: String, arguments: [String])? {
        let countSize = MemoryLayout<Int32>.size
        guard bytes.count > countSize else { return nil }
        let argc = bytes.prefix(countSize).withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        var index = countSize
        func nextString() -> String? {
            guard index < bytes.count else { return nil }
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            let value = String(decoding: bytes[start..<index], as: UTF8.self)
            return value
        }
        guard let executable = nextString(), !executable.isEmpty else { return nil }
        while index < bytes.count, bytes[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < argc, let argument = nextString() {
            arguments.append(argument)
            index += 1
        }
        return (executable, arguments)
    }
}

/// Calls `body` with a NULL-terminated C array of `strings`, valid for the call's duration.
private func withCStrings<R>(_ strings: [String], _ body: ([UnsafeMutablePointer<CChar>?]) -> R) -> R {
    let pointers = strings.map { strdup($0) } + [nil]
    defer { pointers.forEach { free($0) } }
    return body(pointers)
}
