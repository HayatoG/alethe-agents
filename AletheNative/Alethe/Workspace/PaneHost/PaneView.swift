import AletheDesign
import AletheModel
import AletheTerminal
import AppKit
import Observation
import SwiftUI

/// One pane: a header, the sub-tabs lane when shown, and the active tab's terminal (owned by
/// `TerminalRegistry`, only re-parented here), plus the ended/not-found overlay when the process is
/// not running.
@MainActor
final class PaneView: NSView {
    let paneID: PaneID
    private(set) var tabID: TabID?
    private let header = NSHostingView(rootView: AnyView(EmptyView()))
    private var lane: NSHostingView<AnyView>?
    private let content = NSView()
    private var overlay: NSHostingView<AnyView>?
    private var findBar: NSHostingView<AnyView>?
    /// The terminal whose find bar this pane follows (the active tab's).
    private weak var searchedTerminal: TerminalPaneView?
    private var context: PaneHostContext?

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
    private var laneWidth: CGFloat = 36

    func configure(pane: Pane, project: Project, focused: Bool, dropTarget: Bool, context: PaneHostContext,
                   onDrag: @escaping (CGSize?) -> Void) {
        guard let tab = pane.activeTab else { return }
        self.context = context
        let environment = context.environment
        headerHeight = context.metrics.size(28)
        laneWidth = context.metrics.size(36)
        header.rootView = context.hosted(PaneHeader(
            tab: tab, isFocused: focused, isLaneVisible: pane.isLaneVisible, canHideLane: pane.tabs.count == 1,
            onClose: { context.closePane(pane.id) },
            onNewSubTab: { context.newSubTab(in: pane.id) },
            onToggleLane: { context.setLaneVisible(!pane.isLaneVisible, for: pane.id) },
            onDrag: onDrag))
        configureLane(pane: pane, project: project, focused: focused, context: context)

        layer?.cornerRadius = context.metrics.radius(.md)
        layer?.borderWidth = dropTarget ? 2 : 1
        layer?.borderColor = context.theme.nsColor(dropTarget || focused ? .accent : .border).cgColor
        layer?.backgroundColor = context.theme.nsColor(.bg).cgColor

        let switched = tabID != nil && tabID != tab.id
        tabID = tab.id
        setAccessibilityIdentifier("pane.\(tab.title ?? tab.agent)")
        environment.terminals.ensureStarted(tab, in: project, environment: environment)
        attachTerminal(environment.terminals.view(for: tab.id))
        followSearch(of: environment.terminals.view(for: tab.id))

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
        // A sub-tab switch in the focused pane hands the keyboard to the newly shown terminal.
        if switched && focused { DispatchQueue.main.async { [weak self] in self?.focusTerminal() } }
        needsLayout = true
    }

    private func configureLane(pane: Pane, project: Project, focused: Bool, context: PaneHostContext) {
        guard pane.isLaneVisible else {
            lane?.removeFromSuperview()
            lane = nil
            return
        }
        let root = context.hosted(SubTabsLane(
            pane: pane, isFocused: focused,
            onActivate: { context.activateTab($0) },
            onClose: { context.closeTab($0) },
            onRestart: { context.restart($0, in: project) },
            onAdd: { context.newSubTab(in: pane.id) }))
        if let lane {
            lane.rootView = root
        } else {
            let lane = NSHostingView(rootView: root)
            addSubview(lane)
            self.lane = lane
        }
    }

    // MARK: - Find bar

    private func followSearch(of terminal: TerminalPaneView?) {
        guard terminal !== searchedTerminal else {
            updateFindBar()
            return
        }
        searchedTerminal = terminal
        if let terminal { observeSearch(terminal) }
        updateFindBar()
    }

    /// Shows or hides the find bar whenever the terminal's search opens or closes (⌘F from the menu,
    /// or Ghostty's own `start_search` / `end_search`).
    private func observeSearch(_ terminal: TerminalPaneView) {
        withObservationTracking {
            _ = terminal.search.isPresented
        } onChange: { [weak self, weak terminal] in
            Task { @MainActor in
                guard let self, let terminal, terminal === self.searchedTerminal else { return }
                self.updateFindBar()
                self.observeSearch(terminal)
            }
        }
    }

    private func updateFindBar() {
        guard let terminal = searchedTerminal, terminal.search.isPresented, let context else {
            findBar?.removeFromSuperview()
            findBar = nil
            return
        }
        let root = context.hosted(TerminalFindBar(terminal: terminal))
        if let findBar {
            findBar.rootView = root
        } else {
            let bar = NSHostingView(rootView: root)
            addSubview(bar, positioned: .above, relativeTo: content)
            findBar = bar
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
        let body = CGRect(x: 0, y: headerHeight, width: bounds.width, height: max(0, bounds.height - headerHeight))
        let leading = lane == nil ? 0 : min(laneWidth, body.width)
        lane?.frame = CGRect(x: 0, y: body.minY, width: leading, height: body.height)
        content.frame = CGRect(x: leading, y: body.minY, width: body.width - leading, height: body.height)
        overlay?.frame = content.frame
        if let findBar {
            let inset = context?.metrics.space(.m) ?? 8
            let size = findBar.fittingSize
            let width = min(size.width, max(0, content.frame.width - inset * 2))
            findBar.frame = CGRect(x: content.frame.maxX - width - inset, y: content.frame.minY + inset,
                                   width: width, height: size.height)
        }
    }
}
