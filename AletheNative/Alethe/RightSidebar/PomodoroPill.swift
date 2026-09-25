import AletheTodos
import SwiftUI

/// The Pomodoro session driven by `PomodoroTimer`, ticked every second while shown.
struct PomodoroPill: View {
    let store: TodoStore
    @State private var now = Date()

    private var timer: PomodoroTimer { store.pomodoro }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "timer")
            Text(phaseTitle)
            if timer.status == .running || timer.status == .paused {
                Text(Duration.seconds(timer.remaining(now: now).rounded(.up)), format: .time(pattern: .minuteSecond))
                    .monospacedDigit()
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
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.quaternary, in: Capsule())
        .padding(.horizontal, 8)
        .task {
            while !Task.isCancelled {
                now = Date()
                store.updatePomodoro { timer, _, date in timer.tick(now: date) }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var phaseTitle: LocalizedStringKey {
        switch timer.phase {
        case .idle: "pomodoro.idle"
        case .work: "pomodoro.work"
        case .shortBreak: "pomodoro.shortBreak"
        case .longBreak: "pomodoro.longBreak"
        }
    }

    private func button(
        _ title: LocalizedStringKey, _ symbol: String,
        _ change: @escaping (inout PomodoroTimer, PomodoroLengths, Date) -> Void
    ) -> some View {
        Button {
            store.updatePomodoro { timer, lengths, date in change(&timer, lengths, date) }
            now = Date()
        } label: {
            Image(systemName: symbol)
        }
        .buttonStyle(.borderless)
        .help(title)
        .accessibilityLabel(Text(title))
    }
}
