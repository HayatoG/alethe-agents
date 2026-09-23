import AppKit

/// An invisible resize handle over the gap between two tracks. Reports the pointer's travel since
/// mouse-down; the owner turns it into track sizes.
final class DividerView: NSView {
    enum Axis { case vertical, horizontal }

    let axis: Axis
    var onDrag: ((CGFloat) -> Void)?
    var onEnd: (() -> Void)?
    private var start: CGPoint?

    init(axis: Axis) {
        self.axis = axis
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: axis == .vertical ? .resizeLeftRight : .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        start = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let point = event.locationInWindow
        // Window coordinates grow upward; the host is flipped.
        onDrag?(axis == .vertical ? point.x - start.x : start.y - point.y)
    }

    override func mouseUp(with event: NSEvent) {
        guard start != nil else { return }
        start = nil
        onEnd?()
    }
}
