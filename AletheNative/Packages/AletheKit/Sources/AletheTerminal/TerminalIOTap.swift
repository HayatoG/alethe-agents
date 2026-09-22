import Foundation

/// Observes a terminal's traffic without owning it: bytes the user sent to the PTY and bytes the
/// PTY produced. Callbacks run on the thread that moved the bytes (main for input, the PTY queue
/// for output) and must return quickly.
public final class TerminalIOTap: @unchecked Sendable {
    private let lock = NSLock()
    private var inputObservers: [UUID: @Sendable (Data) -> Void] = [:]
    private var outputObservers: [UUID: @Sendable (Data) -> Void] = [:]

    public init() {}

    @discardableResult
    public func observeInput(_ observer: @escaping @Sendable (Data) -> Void) -> UUID {
        let id = UUID()
        lock.withLock { inputObservers[id] = observer }
        return id
    }

    @discardableResult
    public func observeOutput(_ observer: @escaping @Sendable (Data) -> Void) -> UUID {
        let id = UUID()
        lock.withLock { outputObservers[id] = observer }
        return id
    }

    public func remove(_ id: UUID) {
        lock.withLock {
            inputObservers.removeValue(forKey: id)
            outputObservers.removeValue(forKey: id)
        }
    }

    func input(_ data: Data) {
        for observer in lock.withLock({ Array(inputObservers.values) }) { observer(data) }
    }

    func output(_ data: Data) {
        for observer in lock.withLock({ Array(outputObservers.values) }) { observer(data) }
    }
}
