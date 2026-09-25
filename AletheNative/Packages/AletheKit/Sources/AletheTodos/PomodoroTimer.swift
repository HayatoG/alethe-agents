import Foundation

/// Phase lengths in seconds. A long break follows every `cyclesPerLongBreak` work phases.
public struct PomodoroLengths: Hashable, Sendable, Codable {
    public var work: TimeInterval
    public var shortBreak: TimeInterval
    public var longBreak: TimeInterval
    public var cyclesPerLongBreak: Int

    public init(work: TimeInterval = 25 * 60, shortBreak: TimeInterval = 5 * 60, longBreak: TimeInterval = 15 * 60, cyclesPerLongBreak: Int = 4) {
        self.work = work
        self.shortBreak = shortBreak
        self.longBreak = longBreak
        self.cyclesPerLongBreak = cyclesPerLongBreak
    }

    public func duration(of phase: PomodoroTimer.Phase) -> TimeInterval {
        switch phase {
        case .idle: 0
        case .work: work
        case .shortBreak: shortBreak
        case .longBreak: longBreak
        }
    }
}

/// Pure Pomodoro state (upstream `stores/pomodoroStore.ts`). Every transition takes `now`, so the
/// model holds no timer; the app ticks it and persists it (Codable) so a session survives relaunch.
public struct PomodoroTimer: Hashable, Sendable, Codable {
    public enum Phase: String, Hashable, Sendable, Codable {
        case idle, work, shortBreak, longBreak
    }

    public enum Status: String, Hashable, Sendable, Codable {
        case idle, running, paused, finished
    }

    public private(set) var phase: Phase = .idle
    public private(set) var status: Status = .idle
    /// When the running phase ends; nil unless running.
    public private(set) var endsAt: Date?
    /// Frozen remaining time; nil unless paused.
    public private(set) var remainingAtPause: TimeInterval?
    public private(set) var cyclesCompleted = 0
    public var focusTodoId: String?

    public init(focusTodoId: String? = nil) {
        self.focusTodoId = focusTodoId
    }

    /// The phase `start()` picks without an explicit one: a break after work (long every
    /// `cyclesPerLongBreak` cycles), otherwise work.
    public func nextPhase(lengths: PomodoroLengths) -> Phase {
        guard phase == .work else { return .work }
        let every = max(1, lengths.cyclesPerLongBreak)
        return cyclesCompleted > 0 && cyclesCompleted % every == 0 ? .longBreak : .shortBreak
    }

    public mutating func start(_ explicit: Phase? = nil, lengths: PomodoroLengths, now: Date) {
        let next = explicit.flatMap { $0 == .idle ? nil : $0 } ?? nextPhase(lengths: lengths)
        phase = next
        status = .running
        endsAt = now.addingTimeInterval(lengths.duration(of: next))
        remainingAtPause = nil
    }

    public mutating func pause(now: Date) {
        guard status == .running, let endsAt else { return }
        remainingAtPause = max(0, endsAt.timeIntervalSince(now))
        self.endsAt = nil
        status = .paused
    }

    public mutating func resume(now: Date) {
        guard status == .paused, let remainingAtPause else { return }
        endsAt = now.addingTimeInterval(remainingAtPause)
        self.remainingAtPause = nil
        status = .running
    }

    /// Back to idle; keeps the focus todo, clears the cycle count.
    public mutating func reset() {
        phase = .idle
        status = .idle
        endsAt = nil
        remainingAtPause = nil
        cyclesCompleted = 0
    }

    public func remaining(now: Date) -> TimeInterval {
        switch status {
        case .running: max(0, endsAt.map { $0.timeIntervalSince(now) } ?? 0)
        case .paused: remainingAtPause ?? 0
        case .idle, .finished: 0
        }
    }

    /// Finishes the running phase once `now` reaches its end (a finished work phase counts a
    /// cycle). Returns the phase that just finished, for the end-of-phase notification.
    @discardableResult
    public mutating func tick(now: Date) -> Phase? {
        guard status == .running, let endsAt, now >= endsAt else { return nil }
        if phase == .work { cyclesCompleted += 1 }
        status = .finished
        self.endsAt = nil
        return phase
    }

    /// Clears the focus when that todo is gone or completed.
    public mutating func validateFocus(against todos: [Todo]) {
        guard let focusTodoId else { return }
        if !todos.contains(where: { $0.id == focusTodoId && !$0.done }) { self.focusTodoId = nil }
    }
}
