import AletheDesign
import AletheModel
import AppKit
import SwiftUI

/// The workspace pane area (ADR-3): open projects side by side as containers, each laying out its
/// panes. AppKit owns the terminal surfaces, so SwiftUI identity changes never recreate them.
@MainActor
final class PaneHostView: NSView {
    private var containers: [ProjectID: ContainerView] = [:]
    private var order: [ProjectID] = []
    private var dividers: [DividerView] = []
    private var weights: [Double] = []
    private var context: PaneHostContext?
    private lazy var animator = FrameAnimator(host: self)
    private var animateNextLayout = false
    private var liveSizes: [CGFloat]?
    private var resizeBase: [CGFloat] = []
    private var resizeDelta: CGFloat = 0
    private var focusedPane: PaneID?
    private var mouseMonitor: Any?

    override var isFlipped: Bool { true }

    func update(document: WorkspaceDocument, context: PaneHostContext) {
        self.context = context
        let state = document.workspace
        if liveSizes == nil { weights = state.containerWeights }
        layer?.backgroundColor = context.theme.nsColor(.bg).cgColor

        let ids = state.openProjectIDs.filter { document.project($0) != nil }
        if ids != order { animateNextLayout = !order.isEmpty }
        for (id, view) in containers where !ids.contains(id) {
            view.removeFromSuperview()
            containers.removeValue(forKey: id)
        }
        order = ids
        for id in ids {
            guard let project = document.project(id) else { continue }
            let view = containers[id] ?? {
                let view = ContainerView(projectID: id)
                addSubview(view)
                containers[id] = view
                return view
            }()
            view.configure(project: project, isSelected: state.selectedProjectID == id,
                           focusedPane: state.focusedPaneID,
                           weights: state.gridWeights[id.rawValue] ?? GridWeights(), context: context)
        }
        if state.focusedPaneID != focusedPane {
            focusedPane = state.focusedPaneID
            let pane = containers.values.lazy.flatMap(\.paneViews).first { $0.paneID == state.focusedPaneID }
            DispatchQueue.main.async { pane?.focusTerminal() }
        }
        needsLayout = true
    }

    private var gap: CGFloat { context?.metrics.space(.s) ?? 6 }
    private var minimumContainer: CGFloat { context?.metrics.size(260) ?? 260 }
    private var area: CGRect { bounds.insetBy(dx: gap, dy: gap) }

    private func sizes() -> [CGFloat] {
        liveSizes ?? TrackMath.sizes(count: order.count, weights: weights, total: area.width, gap: gap)
    }

    override func layout() {
        super.layout()
        let sizes = sizes()
        let offsets = TrackMath.offsets(sizes, gap: gap, origin: area.minX)
        let animated = animateNextLayout
        animateNextLayout = false
        for (index, id) in order.enumerated() {
            guard let view = containers[id] else { continue }
            let frame = CGRect(x: offsets[index], y: area.minY, width: sizes[index], height: area.height)
            animator.set(view, frame: frame.integral, animated: animated)
        }
        layoutDividers(sizes: sizes, offsets: offsets)
    }

    // MARK: - Container resizing

    private func layoutDividers(sizes: [CGFloat], offsets: [CGFloat]) {
        let needed = max(0, order.count - 1)
        while dividers.count > needed { dividers.removeLast().removeFromSuperview() }
        while dividers.count < needed {
            let index = dividers.count
            let view = DividerView(axis: .vertical)
            view.setAccessibilityIdentifier("container.divider.\(index)")
            view.onDrag = { [weak self] delta in self?.resize(divider: index, delta: delta) }
            view.onEnd = { [weak self] in self?.endResize(divider: index) }
            addSubview(view)
            dividers.append(view)
        }
        let handle = max(gap, context?.metrics.size(8) ?? 8)
        for (index, view) in dividers.enumerated() {
            let center = offsets[index + 1] - gap / 2
            view.frame = CGRect(x: center - handle / 2, y: area.minY, width: handle, height: area.height)
        }
    }

    private func resize(divider: Int, delta: CGFloat) {
        if liveSizes == nil { resizeBase = sizes() }
        liveSizes = TrackMath.drag(resizeBase, divider: divider, delta: delta, minimum: minimumContainer,
                                   rubberBand: { Motion.rubberBand(overshoot: $0, dimension: $1) })
        resizeDelta = delta
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private func endResize(divider: Int) {
        let settled = TrackMath.drag(resizeBase, divider: divider, delta: resizeDelta, minimum: minimumContainer)
        weights = TrackMath.weights(settled)
        liveSizes = nil
        resizeDelta = 0
        animateNextLayout = true
        needsLayout = true
        context?.setContainerWeights(weights)
    }

    // MARK: - Focus

    /// A click anywhere in a pane focuses it; the click itself still reaches the terminal.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        guard window != nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.focusPane(at: event)
            return event
        }
    }

    private func focusPane(at event: NSEvent) {
        guard event.window === window, let context else { return }
        let point = convert(event.locationInWindow, from: nil)
        for (id, container) in containers where container.frame.contains(point) {
            let local = container.convert(point, from: self)
            if let pane = container.paneViews.first(where: { $0.frame.contains(local) }) {
                context.focus(pane.paneID, in: id)
            }
        }
    }
}

/// SwiftUI bridge. Everything the host renders is passed in as values so SwiftUI calls
/// `updateNSView` whenever any of it changes.
struct PaneHost: NSViewRepresentable {
    let document: WorkspaceDocument
    let terminalStates: [TabID: TerminalRegistry.State]
    let terminalGenerations: [TabID: Int]
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics

    func makeNSView(context: Context) -> PaneHostView {
        let view = PaneHostView()
        view.wantsLayer = true
        view.setAccessibilityIdentifier("workspace.panes")
        return view
    }

    func updateNSView(_ view: PaneHostView, context: Context) {
        view.update(document: document, context: PaneHostContext(
            environment: environment, theme: theme, metrics: metrics,
            undoManager: { [weak view] in view?.window?.undoManager }))
    }
}
