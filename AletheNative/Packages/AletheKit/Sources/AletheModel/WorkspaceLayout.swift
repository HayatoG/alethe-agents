import CoreGraphics

/// Upstream's "Auto" layout (`PaneArea.tsx` `AutoLayout`): one pane fills the area, two sit side by
/// side, three or more go in rows of two with an odd last pane spanning its row.
public enum AutoLayout {
    public static func rows(for count: Int) -> [Int] {
        guard count > 0 else { return [] }
        if count <= 2 { return [count] }
        return stride(from: 0, to: count, by: 2).map { min(2, count - $0) }
    }

    public static let columns = 2
}

/// Weighted tracks (columns, rows or containers) separated by fixed gaps.
public enum TrackMath {
    /// Track sizes for `count` tracks sharing `total` minus the gaps. Missing or mismatched weights
    /// mean equal tracks.
    public static func sizes(count: Int, weights: [Double], total: CGFloat, gap: CGFloat) -> [CGFloat] {
        guard count > 0 else { return [] }
        let available = max(0, total - gap * CGFloat(count - 1))
        let usable = weights.count == count && weights.allSatisfy { $0 > 0 && $0.isFinite }
        let effective = usable ? weights : Array(repeating: 1, count: count)
        let sum = effective.reduce(0, +)
        return effective.map { CGFloat($0 / sum) * available }
    }

    /// Where each track starts.
    public static func offsets(_ sizes: [CGFloat], gap: CGFloat, origin: CGFloat = 0) -> [CGFloat] {
        var offsets: [CGFloat] = []
        var position = origin
        for size in sizes {
            offsets.append(position)
            position += size + gap
        }
        return offsets
    }

    /// Moves the boundary after track `divider` by `delta`. Tracks never go below `minimum`; with a
    /// `rubberBand` function (`Motion.rubberBand`), a drag past it gives with progressive resistance
    /// instead of stopping dead, and the caller settles back by calling again without it on release.
    public static func drag(_ sizes: [CGFloat], divider: Int, delta: CGFloat, minimum: CGFloat,
                            rubberBand: ((_ overshoot: CGFloat, _ dimension: CGFloat) -> CGFloat)? = nil) -> [CGFloat] {
        guard sizes.indices.contains(divider), sizes.indices.contains(divider + 1) else { return sizes }
        let pair = sizes[divider] + sizes[divider + 1]
        let floor = min(minimum, pair / 2)
        func resisted(_ size: CGFloat) -> CGFloat {
            guard size < floor else { return size }
            return rubberBand.map { floor - $0(floor - size, floor) } ?? floor
        }
        var leading = sizes[divider] + delta
        if leading < floor {
            leading = resisted(leading)
        } else if pair - leading < floor {
            leading = pair - resisted(pair - leading)
        }
        var result = sizes
        result[divider] = leading
        result[divider + 1] = pair - leading
        return result
    }

    /// Sizes as persisted weights (fractions that sum to 1).
    public static func weights(_ sizes: [CGFloat]) -> [Double] {
        let sum = sizes.reduce(0, +)
        guard sum > 0 else { return [] }
        return sizes.map { Double($0 / sum) }
    }
}

/// Pane frames and resize handles of one project's pane area (Auto layout).
public struct PaneGridGeometry: Equatable, Sendable {
    public enum Divider: Hashable, Sendable {
        /// Between the two columns of `row` (all two-pane rows share the column weights).
        case column(row: Int)
        /// Between row `index` and the next one.
        case row(Int)
    }

    public var paneFrames: [CGRect]
    public var dividers: [Divider: CGRect]
    public var columnSizes: [CGFloat]
    public var rowSizes: [CGFloat]

    /// - Parameter handle: thickness of a divider's hit area, centered on its gap.
    public init(count: Int, in rect: CGRect, weights: GridWeights, gap: CGFloat, handle: CGFloat) {
        let rows = AutoLayout.rows(for: count)
        let twoColumns = rows.contains(2)
        columnSizes = TrackMath.sizes(count: twoColumns ? AutoLayout.columns : 1, weights: weights.columns,
                                      total: rect.width, gap: gap)
        rowSizes = TrackMath.sizes(count: rows.count, weights: weights.rows, total: rect.height, gap: gap)
        let columnX = TrackMath.offsets(columnSizes, gap: gap, origin: rect.minX)
        let rowY = TrackMath.offsets(rowSizes, gap: gap, origin: rect.minY)

        paneFrames = []
        dividers = [:]
        for (row, panes) in rows.enumerated() {
            let y = rowY[row], height = rowSizes[row]
            if panes == 2 {
                paneFrames.append(CGRect(x: columnX[0], y: y, width: columnSizes[0], height: height))
                paneFrames.append(CGRect(x: columnX[1], y: y, width: columnSizes[1], height: height))
                let center = columnX[1] - gap / 2
                dividers[.column(row: row)] = CGRect(x: center - handle / 2, y: y, width: handle, height: height)
            } else {
                paneFrames.append(CGRect(x: rect.minX, y: y, width: rect.width, height: height))
            }
            if row < rows.count - 1 {
                let center = rowY[row + 1] - gap / 2
                dividers[.row(row)] = CGRect(x: rect.minX, y: center - handle / 2, width: rect.width, height: handle)
            }
        }
    }
}
