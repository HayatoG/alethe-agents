import AletheDesign
import AppKit
import Foundation
import GhosttyTerminal
import Synchronization

/// A terminal pane: an app-owned PTY rendered by Ghostty in host-managed mode.
///
/// The PTY belongs to `PTYProcess`, not to the renderer, so its output can be kept (scrollback),
/// tapped (remote control, orchestrator) and replayed into a new view.
@MainActor
public final class TerminalPaneView: NSView {
    public let terminalView: TerminalView
    private let controller: TerminalController
    private let session: InMemoryTerminalSession
    private let process: PTYProcess
    public let tap: TerminalIOTap
    private let activity = TerminalActivity()
    private let forceKill = ForceKillState()

    public var onExit: ((Int32) -> Void)?

    /// Whether the process ended through a double ⌃C, not by itself.
    public var wasForceKilled: Bool { forceKill.triggered }

    /// - Parameter forceKillNotice: line printed in the terminal when a double ⌃C kills the process.
    public init(launch: PTYLaunch, theme: Theme, fontSize: Float = TerminalAppearance.defaultFontSize,
                forceKillNotice: String = "Force kill: process terminated") throws {
        let process = try PTYProcess(launch)
        self.process = process
        let tap = TerminalIOTap()
        self.tap = tap
        let forceKill = forceKill
        let notice = Data("\r\n\u{1b}[33m[\(forceKillNotice)]\u{1b}[0m\r\n".utf8)
        session = InMemoryTerminalSession(
            write: { data in
                tap.input(data)
                if forceKill.register(data) {
                    forceKill.session?.receive(notice)
                    ProcessTree.kill(process.pid)
                    return
                }
                process.write(data)
            },
            resize: { viewport in
                process.resizeCoalesced(PTYSize(
                    columns: viewport.columns,
                    rows: viewport.rows,
                    widthPixels: UInt16(clamping: viewport.widthPixels),
                    heightPixels: UInt16(clamping: viewport.heightPixels)
                ))
            }
        )
        controller = TerminalController(theme: TerminalAppearance.terminalTheme(for: theme, fontSize: fontSize))
        terminalView = TerminalView(frame: .zero)
        super.init(frame: .zero)

        forceKill.session = session
        terminalView.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        terminalView.controller = controller
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminalView)
        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: topAnchor),
            terminalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let session = session
        let activity = activity
        process.onOutput = { data in
            activity.touch()
            tap.output(data)
            session.receive(data)
        }
        // The session is deliberately not `finish`ed: Ghostty would print its own "Process exited.
        // Press any key to close" line, and the app shows the ended state (with Restart) itself.
        process.onExit = { [weak self] code in
            activity.finish()
            Task { @MainActor in self?.onExit?(code) }
        }
        process.start()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func layout() {
        super.layout()
        terminalView.fitToSize()
    }

    public func focus() {
        window?.makeFirstResponder(terminalView)
    }

    public func applyTheme(_ theme: Theme, fontSize: Float = TerminalAppearance.defaultFontSize) {
        _ = controller.setTheme(TerminalAppearance.terminalTheme(for: theme, fontSize: fontSize))
    }

    /// Types `prompt` into the agent once it is ready (see `PromptDelivery`). True once sent.
    public func deliverPrompt(_ prompt: String, style: PromptDelivery.Style) async -> Bool {
        let clock = ContinuousClock()
        let origin = clock.now
        let activity = activity
        let process = process
        let tap = tap
        let io = PromptDelivery.IO(
            now: { origin.duration(to: clock.now) },
            sleep: { try? await Task.sleep(for: $0) },
            quietFor: { activity.quietFor },
            isRunning: { activity.isRunning },
            readScreen: { [weak self] in await MainActor.run { self?.viewportText() ?? "" } },
            write: { text in
                let data = Data(text.utf8)
                tap.input(data)
                process.write(data)
            })
        return await PromptDelivery.deliver(prompt, style: style, io: io)
    }

    /// Viewport text (visible rows), for tests and diagnostics.
    public func viewportText() -> String? {
        session.readViewportText()
    }

    // MARK: - Search (Ghostty binding actions)

    @discardableResult
    public func search(_ text: String) -> Bool {
        terminalView.performBindingAction("search:\(text)")
    }

    @discardableResult
    public func searchNext() -> Bool {
        terminalView.performBindingAction("navigate_search:next")
    }

    @discardableResult
    public func searchPrevious() -> Bool {
        terminalView.performBindingAction("navigate_search:previous")
    }

    @discardableResult
    public func endSearch() -> Bool {
        terminalView.performBindingAction("end_search")
    }

    /// Ends the process group: SIGHUP, then SIGKILL if it outlives the grace period.
    public func terminate() {
        process.terminate()
    }
}

/// Double ⌃C state, shared with the session's write callback (any thread).
private final class ForceKillState: @unchecked Sendable {
    private let state = Mutex<(detector: DoubleInterrupt, triggered: Bool)>((DoubleInterrupt(), false))
    /// Set once, right after the session exists; read by the write callback.
    weak var session: InMemoryTerminalSession?

    func register(_ input: Data) -> Bool {
        state.withLock { state in
            let fire = !state.triggered && state.detector.register(input, at: .now)
            if fire { state.triggered = true }
            return fire
        }
    }

    var triggered: Bool { state.withLock { $0.triggered } }
}

/// When the process last wrote output, and whether it is still running (read from any thread).
private final class TerminalActivity: Sendable {
    private let state = Mutex<(last: ContinuousClock.Instant, running: Bool)>((ContinuousClock.now, true))

    func touch() { state.withLock { $0.last = .now } }
    func finish() { state.withLock { $0.running = false } }
    var quietFor: Duration { state.withLock { $0.last.duration(to: .now) } }
    var isRunning: Bool { state.withLock { $0.running } }
}
