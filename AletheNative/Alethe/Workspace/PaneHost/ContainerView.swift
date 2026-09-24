import AletheDesign
import AletheModel
import AppKit
import SwiftUI

/// One open project: its header and its panes in the Auto layout, with live split resizing and
/// drag-to-reorder.
@MainActor
final class ContainerView: NSView {
    let projectID: ProjectID
    private let header = NSHostingView(rootView: AnyView(EmptyView()))
    private var emptyState: NSHostingView<AnyView>?
    private var panes: [PaneID: PaneView] = [:]
    private var order: [PaneID] = []
    private var dividers: [PaneGridGeometry.Divider: DividerView] = [:]
    private var weights = GridWeights()
    private var context: PaneHostContext?
    private lazy var animator = FrameAnimator(host: self)
    private var animateNextLayout = false

    /// Track sizes while a divider is being dragged (not yet committed).
    private var liveColumns: [CGFloat]?
    private var liveRows: [CGFloat]?
    private var resizeBase: [CGFloat] = []
    private var resizeDelta: CGFloat = 0

    private struct Reorder {
        let pane: PaneID
        let base: CGRect
        var target: PaneID?
    }
    private var reorder: Reorder?
    private var lastProject: Project?
    private var lastFocused: PaneID?
    private var lastSelected = false
    private var isCollapsed = false
    private var isFullscreen = false
    /// The one pane laid out (isolated); nil: all of them.
    private var isolatedPane: PaneID?
    private var onHeaderDrag: (CGSize?) -> Void = { _ in }
    /// The narrow strip shown instead of header and panes while collapsed.
    private var strip: NSHostingView<AnyView>?

    init(projectID: ProjectID) {
        self.projectID = projectID
        super.init(frame: .zero)
        addSubview(header)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    var paneViews: [PaneView] { order.compactMap { panes[$0] } }

    func configure(project: Project, isSelected: Bool, focusedPane: PaneID?, weights: GridWeights,
                   isCollapsed: Bool, isFullscreen: Bool, isolatedPane: PaneID?,
                   context: PaneHostContext, onHeaderDrag: @escaping (CGSize?) -> Void) {
        self.context = context
        lastProject = project
        lastFocused = focusedPane
        lastSelected = isSelected
        self.isCollapsed = isCollapsed
        self.isFullscreen = isFullscreen
        self.isolatedPane = project.panes.contains { $0.id == isolatedPane } ? isolatedPane : nil
        self.onHeaderDrag = onHeaderDrag
        if liveColumns == nil, liveRows == nil { self.weights = weights }
        setAccessibilityIdentifier("container.\(project.name)")
        header.rootView = context.hosted(ContainerHeader(
            project: project, isSelected: isSelected, isFullscreen: isFullscreen,
            onCollapse: { context.setCollapsed(project.id, true) },
            onFullscreen: { context.setFullscreen(isFullscreen ? nil : project.id) },
            onClose: { context.closeContainer(project.id) },
            onDrag: onHeaderDrag))
        configureStrip(project: project, context: context)

        let ids = project.panes.map(\.id)
        if ids != order { animateNextLayout = !order.isEmpty }
        for (id, view) in panes where !ids.contains(id) {
            view.removeFromSuperview()
            panes.removeValue(forKey: id)
        }
        order = ids
        for pane in project.panes {
            let view = panes[pane.id] ?? {
                let view = PaneView(paneID: pane.id)
                addSubview(view, positioned: .below, relativeTo: header)
                panes[pane.id] = view
                return view
            }()
            view.configure(pane: pane, project: project, focused: pane.id == focusedPane,
                           dropTarget: reorder?.target == pane.id, context: context) { [weak self] translation in
                self?.reorderDrag(pane.id, translation: translation)
            }
        }

        if project.panes.isEmpty {
            let root = context.hosted(ProjectEmptyState(project: project))
            if let emptyState {
                emptyState.rootView = root
            } else {
                let view = NSHostingView(rootView: root)
                addSubview(view)
                emptyState = view
            }
        } else {
            emptyState?.removeFromSuperview()
            emptyState = nil
        }
        needsLayout = true
    }

    private var headerHeight: CGFloat { context?.metrics.size(30) ?? 30 }
    private var gap: CGFloat { context?.metrics.space(.s) ?? 6 }
    private var minimumPane: CGSize {
        CGSize(width: context?.metrics.size(160) ?? 160, height: context?.metrics.size(100) ?? 100)
    }

    private var paneArea: CGRect {
        CGRect(x: 0, y: headerHeight + gap, width: bounds.width, height: max(0, bounds.height - headerHeight - gap))
    }

    private func geometry() -> PaneGridGeometry {
        var current = weights
        if let liveColumns { current.columns = TrackMath.weights(liveColumns) }
        if let liveRows { current.rows = TrackMath.weights(liveRows) }
        return PaneGridGeometry(count: order.count, in: paneArea, weights: current, gap: gap,
                                handle: max(gap, context?.metrics.size(8) ?? 8))
    }

    override func layout() {
        super.layout()
        strip?.frame = bounds
        header.isHidden = isCollapsed
        emptyState?.isHidden = isCollapsed
        header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: headerHeight)
        emptyState?.frame = paneArea
        let animated = animateNextLayout
        animateNextLayout = false
        if isCollapsed {
            panes.values.forEach { $0.isHidden = true }
            dividers.values.forEach { $0.isHidden = true }
            return
        }
        if let isolatedPane {
            for (id, view) in panes {
                view.isHidden = id != isolatedPane
                if id == isolatedPane { animator.set(view, frame: paneArea.integral, animated: animated) }
            }
            dividers.values.forEach { $0.isHidden = true }
            return
        }
        panes.values.forEach { $0.isHidden = false }
        dividers.values.forEach { $0.isHidden = false }
        let geometry = geometry()
        for (index, id) in order.enumerated() {
            guard let view = panes[id], geometry.paneFrames.indices.contains(index) else { continue }
            if reorder?.pane == id { continue }
            animator.set(view, frame: geometry.paneFrames[index].integral, animated: animated)
        }
        layoutDividers(geometry)
    }

    private func configureStrip(project: Project, context: PaneHostContext) {
        guard isCollapsed else {
            strip?.removeFromSuperview()
            strip = nil
            return
        }
        let root = context.hosted(CollapsedContainerStrip(project: project, isSelected: lastSelected,
                                                          onExpand: { context.setCollapsed(project.id, false) },
                                                          onDrag: onHeaderDrag))
        if let strip {
            strip.rootView = root
        } else {
            let view = NSHostingView(rootView: root)
            addSubview(view, positioned: .above, relativeTo: nil)
            strip = view
        }
    }

    // MARK: - Split resizing

    private func layoutDividers(_ geometry: PaneGridGeometry) {
        for (kind, view) in dividers where geometry.dividers[kind] == nil {
            view.removeFromSuperview()
            dividers.removeValue(forKey: kind)
        }
        for (kind, rect) in geometry.dividers {
            let view = dividers[kind] ?? makeDivider(kind)
            view.frame = rect
        }
    }

    private func makeDivider(_ kind: PaneGridGeometry.Divider) -> DividerView {
        let view: DividerView
        switch kind {
        case .column: view = DividerView(axis: .vertical)
        case .row: view = DividerView(axis: .horizontal)
        }
        switch kind {
        case .column(let row): view.setAccessibilityIdentifier("pane.divider.column.\(row)")
        case .row(let index): view.setAccessibilityIdentifier("pane.divider.row.\(index)")
        }
        view.onDrag = { [weak self] delta in self?.resize(kind, delta: delta) }
        view.onEnd = { [weak self] in self?.endResize(kind) }
        addSubview(view)
        dividers[kind] = view
        return view
    }

    private func resize(_ kind: PaneGridGeometry.Divider, delta: CGFloat) {
        let geometry = geometry()
        switch kind {
        case .column:
            if liveColumns == nil { resizeBase = geometry.columnSizes }
            liveColumns = TrackMath.drag(resizeBase, divider: 0, delta: delta, minimum: minimumPane.width,
                                         rubberBand: { Motion.rubberBand(overshoot: $0, dimension: $1) })
        case .row(let index):
            if liveRows == nil { resizeBase = geometry.rowSizes }
            liveRows = TrackMath.drag(resizeBase, divider: index, delta: delta, minimum: minimumPane.height,
                                      rubberBand: { Motion.rubberBand(overshoot: $0, dimension: $1) })
        }
        resizeDelta = delta
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    /// Settles a rubber-banded drag back to the minimum with a spring, then commits the weights.
    private func endResize(_ kind: PaneGridGeometry.Divider) {
        switch kind {
        case .column:
            let settled = TrackMath.drag(resizeBase, divider: 0, delta: resizeDelta, minimum: minimumPane.width)
            weights.columns = TrackMath.weights(settled)
        case .row(let index):
            let settled = TrackMath.drag(resizeBase, divider: index, delta: resizeDelta, minimum: minimumPane.height)
            weights.rows = TrackMath.weights(settled)
        }
        liveColumns = nil
        liveRows = nil
        resizeDelta = 0
        animateNextLayout = true
        needsLayout = true
        context?.setGridWeights(weights, for: projectID)
    }

    // MARK: - Reorder

    private func reorderDrag(_ pane: PaneID, translation: CGSize?) {
        guard let view = panes[pane] else { return }
        guard let translation else { return endReorder() }
        if reorder == nil {
            reorder = Reorder(pane: pane, base: animator.target(of: view))
            addSubview(view, positioned: .above, relativeTo: nil)
            lift(view, true)
        }
        guard var current = reorder else { return }
        view.frame = current.base.offsetBy(dx: translation.width, dy: translation.height)
        let center = CGPoint(x: view.frame.midX, y: view.frame.midY)
        let target = order.first { $0 != pane && (panes[$0].map { animator.target(of: $0).contains(center) } ?? false) }
        if target != current.target {
            current.target = target
            reorder = current
            refreshPanes()
        }
    }

    private func endReorder() {
        guard let finished = reorder, let view = panes[finished.pane] else { return }
        reorder = nil
        lift(view, false)
        addSubview(view, positioned: .below, relativeTo: header)
        if let target = finished.target {
            animateNextLayout = true
            context?.swapPanes(finished.pane, target)
        } else {
            animator.set(view, frame: finished.base, animated: true)
        }
        refreshPanes()
    }

    private func refreshPanes() {
        guard let project = lastProject, let context else { return }
        configure(project: project, isSelected: lastSelected, focusedPane: lastFocused, weights: weights,
                  isCollapsed: isCollapsed, isFullscreen: isFullscreen, isolatedPane: isolatedPane,
                  context: context, onHeaderDrag: onHeaderDrag)
    }

    /// A lifted pane casts the theme's large shadow (unclipped while it floats).
    private func lift(_ view: NSView, _ lifted: Bool) {
        guard let layer = view.layer else { return }
        let shadow = context?.theme.shadow(.lg)
        layer.masksToBounds = !lifted
        layer.shadowColor = shadow?.color.nsColor.cgColor
        layer.shadowOpacity = lifted ? 1 : 0
        layer.shadowRadius = lifted ? CGFloat(shadow?.blur ?? 0) / 2 : 0
        layer.shadowOffset = CGSize(width: shadow?.x ?? 0, height: -(shadow?.y ?? 0))
        view.alphaValue = lifted ? 0.94 : 1
    }
}

/// The pane area of a project that has no terminals yet.
private struct ProjectEmptyState: View {
    let project: Project
    @Environment(\.theme) private var theme
    @Environment(\.metrics) private var metrics

    var body: some View {
        VStack(spacing: metrics.space(.l)) {
            Text("workspace.project.noTerminals")
                .font(metrics.font(.body))
                .foregroundStyle(theme[.textSecondary])
            NewTerminalButton(project: project)
                .fixedSize()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace.project.empty")
    }
}
