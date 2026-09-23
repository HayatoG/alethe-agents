import AletheDesign
import AppKit
import Foundation
import GhosttyTerminal

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

    public var onExit: ((Int32) -> Void)?

    public init(launch: PTYLaunch, theme: Theme, fontSize: Float = TerminalAppearance.defaultFontSize) throws {
        let process = try PTYProcess(launch)
        self.process = process
        let tap = TerminalIOTap()
        self.tap = tap
        session = InMemoryTerminalSession(
            write: { data in
                tap.input(data)
                process.write(data)
            },
            resize: { viewport in
                process.resize(PTYSize(
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
        process.onOutput = { data in
            tap.output(data)
            session.receive(data)
        }
        // The session is deliberately not `finish`ed: Ghostty would print its own "Process exited.
        // Press any key to close" line, and the app shows the ended state (with Restart) itself.
        process.onExit = { [weak self] code in
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
