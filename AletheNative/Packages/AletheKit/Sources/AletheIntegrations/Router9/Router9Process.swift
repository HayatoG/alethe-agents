import Darwin
import Foundation

/// A running 9router, started as the leader of its own process group so the Next.js workers it
/// forks go with it.
final class Router9Process: @unchecked Sendable {
    let pid: pid_t
    private let lock = NSLock()
    private var reaped = false

    private init(pid: pid_t) {
        self.pid = pid
    }

    /// `executable arguments…` in `directory` with exactly `environment`; stdin on `/dev/null`,
    /// stdout and stderr appended to `logFile`, no inherited descriptors, default signals.
    static func spawn(_ executable: String, arguments: [String], directory: String?,
                      environment: [String: String], logFile: String) throws(Router9Error) -> Router9Process {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, logFile, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        if let directory { posix_spawn_file_actions_addchdir(&actions, directory) }

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

        let argv = [executable] + arguments
        let envp = environment.map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let result = withRouter9CStrings(argv) { cArgv in
            withRouter9CStrings(envp) { cEnvp in posix_spawn(&pid, executable, &actions, &attributes, cArgv, cEnvp) }
        }
        guard result == 0 else { throw .spawnFailed(String(cString: strerror(result))) }
        return Router9Process(pid: pid)
    }

    /// Whether the leader still runs (reaps it once it exited).
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

    /// SIGTERM to the group, then after `grace` SIGKILL to every descendant and the group; the
    /// leader is reaped. Blocking: call off the main thread.
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
            if !reaped {
                while waitpid(pid, &status, 0) < 0, errno == EINTR {}
                reaped = true
            }
            lock.unlock()
        }
    }
}

enum Router9PortProbe {
    static let timeout: Duration = .milliseconds(400)

    /// Whether something accepts a TCP connection on `127.0.0.1:port` within `timeout`. Blocking.
    static func isInUse(_ port: Int, timeout: Duration = timeout) -> Bool {
        guard port > 0, port < 65536 else { return false }
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connected == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        let (seconds, attoseconds) = timeout.components
        let milliseconds = Int32(clamping: seconds * 1000 + attoseconds / 1_000_000_000_000_000)
        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard Darwin.poll(&descriptor, 1, milliseconds) == 1 else { return false }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else { return false }
        return error == 0
    }
}

/// Calls `body` with a NULL-terminated C array of `strings`, valid for the call's duration.
private func withRouter9CStrings<R>(_ strings: [String], _ body: ([UnsafeMutablePointer<CChar>?]) -> R) -> R {
    let pointers = strings.map { strdup($0) } + [nil]
    defer { pointers.forEach { free($0) } }
    return body(pointers)
}
