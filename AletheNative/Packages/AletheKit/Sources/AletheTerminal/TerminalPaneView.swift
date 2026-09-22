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
    private let startedAt = Date()
    public let tap: TerminalIOTap

    public var onExit: ((Int32) -> Void)?

    public init(launch: PTYLaunch, theme: Theme) throws {
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
        controller = TerminalController(theme: TerminalAppearance.terminalTheme(for: theme))
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
        let startedAt = startedAt
        process.onOutput = { data in
            tap.output(data)
            session.receive(data)
        }
        process.onExit = { [weak self] code in
            session.finish(
                exitCode: UInt32(bitPattern: code),
                runtimeMilliseconds: UInt64(Date().timeIntervalSince(startedAt) * 1000)
            )
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

    public func applyTheme(_ theme: Theme) {
        _ = controller.setTheme(TerminalAppearance.terminalTheme(for: theme))
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

    public func terminate() {
        process.signal(SIGHUP)
    }
}
