import AletheDesign
import AletheModel
import AletheTerminal
import AppKit
import SwiftUI

/// One pane: a header and the active tab's terminal (owned by `TerminalRegistry`, only re-parented
/// here), plus the ended/not-found overlay when the process is not running.
@MainActor
final class PaneView: NSView {
    let paneID: PaneID
    private(set) var tabID: TabID?
    private let header = NSHostingView(rootView: AnyView(EmptyView()))
    private let content = NSView()
    private var overlay: NSHostingView<AnyView>?

    init(paneID: PaneID) {
        self.paneID = paneID
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(content)
        addSubview(header)
        content.setAccessibilityElement(true)
        content.setAccessibilityRole(.group)
        content.setAccessibilityLabel(String(localized: "terminal.accessibilityLabel"))
        content.setAccessibilityIdentifier("terminal.pane")
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    private var headerHeight: CGFloat = 28

    func configure(pane: Pane, project: Project, focused: Bool, dropTarget: Bool, context: PaneHostContext,
                   onDrag: @escaping (CGSize?) -> Void) {
        guard let tab = pane.activeTab else { return }
        let environment = context.environment
        headerHeight = context.metrics.size(28)
        header.rootView = context.hosted(PaneHeader(tab: tab, isFocused: focused, onClose: {
            context.closePane(pane.id)
        }, onDrag: onDrag))

        layer?.cornerRadius = context.metrics.radius(.md)
        layer?.borderWidth = dropTarget ? 2 : 1
        layer?.borderColor = context.theme.nsColor(dropTarget || focused ? .accent : .border).cgColor
        layer?.backgroundColor = context.theme.nsColor(.bg).cgColor

        tabID = tab.id
        setAccessibilityIdentifier("pane.\(tab.title ?? tab.agent)")
        environment.terminals.ensureStarted(tab, in: project, environment: environment)
        attachTerminal(environment.terminals.view(for: tab.id))

        if TerminalOverlay.isNeeded(for: environment.terminals.states[tab.id]) {
            let root = context.hosted(TerminalOverlay(tab: tab, project: project))
            if let overlay {
                overlay.rootView = root
            } else {
                let overlay = NSHostingView(rootView: root)
                addSubview(overlay, positioned: .above, relativeTo: content)
                self.overlay = overlay
            }
        } else {
            overlay?.removeFromSuperview()
            overlay = nil
        }
        needsLayout = true
    }

    func focusTerminal() {
        (content.subviews.first as? TerminalPaneView)?.focus()
    }

    private func attachTerminal(_ terminal: TerminalPaneView?) {
        guard content.subviews.first !== terminal else { return }
        content.subviews.forEach { $0.removeFromSuperview() }
        guard let terminal else { return }
        terminal.removeFromSuperview()
        terminal.frame = content.bounds
        terminal.autoresizingMask = [.width, .height]
        content.addSubview(terminal)
    }

    override func layout() {
        super.layout()
        header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: headerHeight)
        content.frame = CGRect(x: 0, y: headerHeight, width: bounds.width, height: max(0, bounds.height - headerHeight))
        overlay?.frame = content.frame
    }
}
