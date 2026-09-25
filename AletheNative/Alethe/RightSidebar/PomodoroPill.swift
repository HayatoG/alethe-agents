import AletheDesign
import AletheTodos
import SwiftUI

/// The Pomodoro session in the Todos panel: phase, remaining time, focus todo and controls. The
/// session is ticked app-wide by `PomodoroController`; this view only redraws every second.
struct PomodoroPill: View {
    let store: TodoStore
    @Environment(\.theme) private var theme

    private var timer: PomodoroTimer { store.pomodoro }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "timer")
                Text(PomodoroText.phase(timer.phase))
                if timer.status == .running || timer.status == .paused {
                    PomodoroCountdown(timer: timer)
                }
                if timer.cyclesCompleted > 0 {
                    Text(verbatim: "×\(timer.cyclesCompleted)")
                        .foregroundStyle(theme[.textSecondary])
                        .help("pomodoro.cycles")
                }
                Spacer(minLength: 0)
                switch timer.status {
                case .running:
                    button("pomodoro.pause", "pause.fill") { $0.pause(now: $2) }
                case .paused:
                    button("pomodoro.resume", "play.fill") { $0.resume(now: $2) }
                case .idle, .finished:
                    button("pomodoro.start", "play.fill") { $0.start(lengths: $1, now: $2) }
                }
                if timer.status != .idle {
                    button("pomodoro.reset", "arrow.counterclockwise") { t, _, _ in t.reset() }
                }
            }
            if let focus = store.focusTodo {
                HStack(spacing: 4) {
                    Image(systemName: "scope")
                    Text(verbatim: focus.title).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                    Button {
                        store.setFocus(nil)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .help("pomodoro.clearFocus")
                    .accessibilityLabel(Text("pomodoro.clearFocus"))
                }
                .font(.caption)
                .foregroundStyle(theme[.textSecondary])
                .accessibilityIdentifier("pomodoro.focus")
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pomodoro.panel")
    }

    private func button(
        _ title: LocalizedStringKey, _ symbol: String,
        _ change: @escaping (inout PomodoroTimer, PomodoroLengths, Date) -> Void
    ) -> some View {
        Button {
            store.updatePomodoro { timer, lengths, date in change(&timer, lengths, date) }
        } label: {
            Image(systemName: symbol)
        }
        .buttonStyle(.borderless)
        .help(title)
        .accessibilityLabel(Text(title))
    }
}

/// Remaining time, redrawn every second while running.
struct PomodoroCountdown: View {
    let timer: PomodoroTimer

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Duration.seconds(timer.remaining(now: context.date).rounded(.up)), format: .time(pattern: .minuteSecond))
                .monospacedDigit()
        }
    }
}

enum PomodoroText {
    static func phase(_ phase: PomodoroTimer.Phase) -> LocalizedStringKey {
        switch phase {
        case .idle: "pomodoro.idle"
        case .work: "pomodoro.work"
        case .shortBreak: "pomodoro.shortBreak"
        case .longBreak: "pomodoro.longBreak"
        }
    }
}

/// The main window's toolbar pill (P4-17): the running or paused phase and its remaining time;
/// hidden when no session is under way. Clicking it opens the Todos tab.
struct PomodoroToolbarPill: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics

    var body: some View {
        if let store = environment.todoStore, store.pomodoro.status == .running || store.pomodoro.status == .paused {
            let timer = store.pomodoro
            Button {
                environment.showTodos()
            } label: {
                HStack(spacing: metrics.space(.xs)) {
                    Image(systemName: timer.status == .paused ? "pause.fill" : "timer")
                    Text(PomodoroText.phase(timer.phase))
                    PomodoroCountdown(timer: timer)
                }
                .font(metrics.font(.caption).monospacedDigit())
                .padding(.horizontal, metrics.space(.s))
                .padding(.vertical, metrics.space(.xxs))
                .background(theme[token(timer)].opacity(0.18), in: Capsule())
                .foregroundStyle(theme[token(timer)])
            }
            .buttonStyle(.plain)
            .help("pomodoro.toolbar.help")
            .accessibilityIdentifier("pomodoro.toolbarPill")
        }
    }

    private func token(_ timer: PomodoroTimer) -> ThemeToken {
        if timer.status == .paused { return .statusWaiting }
        return timer.phase == .work ? .accent : .statusActive
    }
}
