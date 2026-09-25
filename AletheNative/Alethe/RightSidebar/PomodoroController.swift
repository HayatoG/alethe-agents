import AletheTodos
import Foundation

/// Drives the Todos plugin's Pomodoro session for the whole app (P4-17): ticks it every second,
/// whether or not a Pomodoro view is shown, and posts a notification when a phase ends (through the
/// agent notifier of P3-11, so it also reaches macOS while Alethe is in the background). A phase
/// that ended while the app was closed is reported on the first tick after launch.
@MainActor
final class PomodoroController {
    private var loop: Task<Void, Never>?

    func start(environment: AppEnvironment) {
        guard loop == nil else { return }
        loop = Task { [weak environment] in
            while !Task.isCancelled {
                guard let environment else { return }
                if let store = environment.todoStore, store.isLoaded, let ended = store.tickPomodoro() {
                    Self.notify(ended, focus: store.focusTodo, notifier: environment.notifier)
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    private static func notify(_ phase: PomodoroTimer.Phase, focus: Todo?, notifier: AgentNotifier) {
        let title: String
        var body: String
        switch phase {
        case .idle: return
        case .work:
            title = String(localized: "pomodoro.notify.workEnded")
            body = String(localized: "pomodoro.notify.workEnded.body")
        case .shortBreak, .longBreak:
            title = String(localized: "pomodoro.notify.breakEnded")
            body = String(localized: "pomodoro.notify.breakEnded.body")
        }
        if let focus { body = String(format: String(localized: "pomodoro.notify.focus"), focus.title) + " " + body }
        notifier.post(title: title, body: body)
    }
}
