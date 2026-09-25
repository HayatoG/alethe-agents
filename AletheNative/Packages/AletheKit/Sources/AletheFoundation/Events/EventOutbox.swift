import Foundation

/// A publisher's way onto the bus: events go out in order and the caller never waits. Events
/// raised before a bus is attached (a plugin failing at launch, before the app wires the host) are
/// held — the newest `limit` — and delivered when one is.
@MainActor
public final class EventOutbox {
    public static let defaultLimit = 64

    public let limit: Int
    public private(set) var bus: EventBus?
    /// Held until a bus is attached.
    public private(set) var pending: [BusEvent] = []
    /// The last delivery; each new one waits for it, so events arrive in publishing order.
    private var tail: Task<Void, Never>?

    public init(bus: EventBus? = nil, limit: Int = defaultLimit) {
        self.bus = bus
        self.limit = max(1, limit)
    }

    /// Points the outbox at `bus` and delivers what was held. Attaching the same bus again does nothing.
    public func attach(_ bus: EventBus) {
        guard self.bus !== bus else { return }
        self.bus = bus
        let held = pending
        pending.removeAll()
        held.forEach(deliver)
    }

    public func publish(_ event: BusEvent) {
        guard bus != nil else {
            pending.append(event)
            if pending.count > limit { pending.removeFirst(pending.count - limit) }
            return
        }
        deliver(event)
    }

    public func publish(_ events: [BusEvent]) {
        events.forEach(publish)
    }

    /// Resolves once everything published so far reached the bus (tests).
    public func drained() async {
        await tail?.value
    }

    private func deliver(_ event: BusEvent) {
        guard let bus else { return }
        let previous = tail
        tail = Task {
            await previous?.value
            await bus.publish(event)
        }
    }
}
