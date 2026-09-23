import CAlethePTY
import Darwin
import Foundation

public struct PTYSize: Hashable, Sendable {
    public var columns: UInt16
    public var rows: UInt16
    public var widthPixels: UInt16
    public var heightPixels: UInt16

    public init(columns: UInt16, rows: UInt16, widthPixels: UInt16 = 0, heightPixels: UInt16 = 0) {
        self.columns = columns
        self.rows = rows
        self.widthPixels = widthPixels
        self.heightPixels = heightPixels
    }
}

public struct PTYLaunch: Sendable {
    public var executable: String
    /// argv, including argv[0].
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: String?
    public var size: PTYSize

    public init(executable: String, arguments: [String], environment: [String: String],
                workingDirectory: String?, size: PTYSize) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.size = size
    }
}

public enum PTYError: Error, Equatable {
    case spawnFailed(errno: Int32)
}

/// A child process on a pseudo-terminal owned by the app (not by the terminal renderer).
///
/// Output is read on a private queue and delivered in chunks of up to 64 KiB — batching before
/// crossing into the renderer is what keeps throughput high. All callbacks run on that queue.
public final class PTYProcess: @unchecked Sendable {
    public let pid: pid_t
    private let masterFD: Int32
    private let queue: DispatchQueue
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private var scrollback: ScrollbackRing
    private var exited = false

    public var onOutput: (@Sendable (Data) -> Void)?
    public var onExit: (@Sendable (Int32) -> Void)?

    public init(_ launch: PTYLaunch, scrollbackCapacity: Int = ScrollbackRing.defaultCapacity) throws {
        queue = DispatchQueue(label: "alethe.pty", qos: .userInteractive)
        scrollback = ScrollbackRing(capacity: scrollbackCapacity)

        var master: Int32 = -1
        let env = launch.environment.map { "\($0.key)=\($0.value)" }
        let spawned: pid_t = withCStringArray(launch.arguments) { argv in
            withCStringArray(env) { envp in
                alethe_pty_spawn(
                    launch.executable, argv, envp, launch.workingDirectory,
                    launch.size.columns, launch.size.rows, &master
                )
            }
        }
        guard spawned > 0 else { throw PTYError.spawnFailed(errno: errno) }
        pid = spawned
        masterFD = master
    }

    /// Starts reading. Call after `onOutput`/`onExit` are set so no early output is lost.
    public func start() {
        let read = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: queue)
        read.setEventHandler { [weak self] in self?.drain() }
        read.resume()
        readSource = read

        let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        exit.setEventHandler { [weak self] in self?.reap() }
        exit.resume()
        exitSource = exit
    }

    public func write(_ data: Data) {
        queue.async { [masterFD] in
            data.withUnsafeBytes { raw in
                guard var pointer = raw.baseAddress else { return }
                var remaining = raw.count
                while remaining > 0 {
                    let written = Darwin.write(masterFD, pointer, remaining)
                    if written > 0 {
                        remaining -= written
                        pointer += written
                    } else if written < 0, errno == EAGAIN || errno == EINTR {
                        continue
                    } else {
                        return
                    }
                }
            }
        }
    }

    public func resize(_ size: PTYSize) {
        queue.async { [masterFD] in
            _ = alethe_pty_resize(masterFD, size.columns, size.rows, size.widthPixels, size.heightPixels)
        }
    }

    /// Sends a signal to the child's whole process group (the shell and what it runs).
    public func signal(_ signal: Int32 = SIGHUP) {
        kill(-pid, signal)
    }

    /// Hangs up the process group, then kills it if it is still alive after `grace` (agents that
    /// trap SIGHUP to save state get that long).
    public func terminate(grace: Duration = .seconds(2)) {
        signal(SIGHUP)
        let seconds = Double(grace.components.seconds) + Double(grace.components.attoseconds) / 1e18
        queue.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, !self.exited else { return }
            self.signal(SIGKILL)
        }
    }

    public var scrollbackContents: Data {
        queue.sync { scrollback.contents }
    }

    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(masterFD, $0.baseAddress, $0.count) }
            if count > 0 {
                let chunk = Data(buffer[0..<count])
                scrollback.append(chunk)
                onOutput?(chunk)
            } else if count < 0, errno == EINTR {
                continue
            } else {
                // EAGAIN: drained for now. 0 / EIO: the slave side closed.
                return
            }
        }
    }

    private func reap() {
        guard !exited else { return }
        exited = true
        drain()
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        readSource?.cancel()
        exitSource?.cancel()
        close(masterFD)
        let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        onExit?(code)
    }

    deinit {
        if !exited {
            kill(-pid, SIGHUP)
            readSource?.cancel()
            exitSource?.cancel()
            close(masterFD)
        }
    }
}

private func withCStringArray<R>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
    let pointers = strings.map { strdup($0) } + [nil]
    defer { pointers.forEach { free($0) } }
    return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
}
