import Foundation

/// Dictation's key handling and phases (upstream `DictationButton` toggle/hold): a short press of the
/// shortcut starts and a second press stops (toggle); holding it past `holdThreshold` stops on release
/// (hold). Esc cancels. Times are seconds on any clock.
public struct DictationMachine: Equatable, Sendable {
    public enum Failure: String, Equatable, Sendable {
        case microphoneDenied, languageUnsupported, unavailable
    }

    public enum Phase: Equatable, Sendable {
        case idle
        /// Permission, speech model, audio engine.
        case starting
        case listening
        /// Stopped; the last words are being transcribed.
        case finishing
        case failed(Failure)
    }

    public enum Effect: Equatable, Sendable {
        case none, start, stop, cancel
    }

    public static let holdThreshold: TimeInterval = 0.4

    public private(set) var phase = Phase.idle
    private var pressedAt: TimeInterval?

    public init() {}

    public var isActive: Bool { phase == .starting || phase == .listening || phase == .finishing }

    public mutating func keyDown(at now: TimeInterval) -> Effect {
        switch phase {
        case .idle, .failed:
            phase = .starting
            pressedAt = now
            return .start
        case .starting, .listening:
            pressedAt = nil
            phase = .finishing
            return .stop
        case .finishing:
            return .none
        }
    }

    public mutating func keyUp(at now: TimeInterval) -> Effect {
        guard let pressed = pressedAt else { return .none }
        pressedAt = nil
        guard now - pressed >= Self.holdThreshold, phase == .starting || phase == .listening else { return .none }
        phase = .finishing
        return .stop
    }

    /// A click on the menu item or a button.
    public mutating func toggle() -> Effect {
        pressedAt = nil
        switch phase {
        case .idle, .failed:
            phase = .starting
            return .start
        case .starting, .listening:
            phase = .finishing
            return .stop
        case .finishing:
            return .none
        }
    }

    public mutating func escape() -> Effect {
        pressedAt = nil
        switch phase {
        case .starting, .listening, .finishing:
            phase = .idle
            return .cancel
        case .failed:
            phase = .idle
            return .none
        case .idle:
            return .none
        }
    }

    public mutating func started() {
        if phase == .starting { phase = .listening }
    }

    public mutating func failed(_ failure: Failure) {
        pressedAt = nil
        phase = .failed(failure)
    }

    public mutating func finished() {
        if phase == .finishing || phase == .listening || phase == .starting { phase = .idle }
    }
}
